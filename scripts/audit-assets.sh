#!/usr/bin/env bash
# ============================================================
# audit-assets.sh — 产物契约体检（只读，不发任何写请求）
#
# 为什么需要它：压缩/缓存问题会反复出现，根因不是「某次配置漏了」，而是
#   ① 验收只探一个资源（抽样偏差）
#   ② 只打公网域名 → Caddy 的 encode 会盖住「容器自己没开压缩」
#   ③ 缓存头缺失只 warn 不阻断 → 永远修不完
# 本脚本把判据写死，逐条判红绿，可直接当验收用。
#
# 用法：
#   audit-assets.sh <域名>                    # 只打公网
#   audit-assets.sh <域名> --container <ip:port>   # 同时直连容器做归属比对
#
# 退出码：0 契约满足 · 1 有硬伤
# ============================================================
set -uo pipefail

DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || { sed -n '2,16p' "$0"; exit 2; }
shift
CONTAINER_EP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER_EP="$2"; shift 2 ;;
    *) echo "未知参数 $1" >&2; exit 2 ;;
  esac
done

BASE="https://${DOMAIN}"
FAIL=0
red()  { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAIL=1; }
grn()  { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
hdr()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# 取响应头（用 GET，避免 HEAD 不支持；只读）。跟随重定向，取最终页
headers() {
  local url="$1"
  curl -sL -m 10 -o /dev/null -D - -H 'Accept-Encoding: gzip, br' "$url" 2>/dev/null \
    | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^[A-Za-z-]+:/'
}
code_of() {
  local url="$1"
  curl -sL -m 10 -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: gzip, br' "$url" 2>/dev/null || echo 000
}
get_h() { headers "$1" | grep -iE "^$2:" | tail -1 | cut -d: -f2- | sed 's/^ *//'; }

# ---------- 1. 入口 HTML ----------
hdr "入口 HTML（$BASE/）"
C="$(code_of "$BASE/")"
[[ "$C" =~ ^2 ]] && grn "HTTP $C" || red "HTTP $C"

ENTRY_HDRS="$(headers "$BASE/")"
CC="$(get_h "$BASE/" cache-control)"
CE="$(get_h "$BASE/" content-encoding)"
if [[ -z "$CC" ]]; then
  red "入口页无 cache-control —— 浏览器会启发式缓存，发新版用户可能拿不到"
elif grep -qiE 'no-store|no-cache' <<<"$CC"; then
  grn "入口页 cache-control: ${CC}"
else
  # 浏览器只看 max-age；s-maxage 只对共享缓存（CDN）生效，别混为一谈
  maxage="$(grep -oiE '(^|[ ,])max-age=[0-9]+' <<<"$CC" | head -1 | grep -oE '[0-9]+')"
  if [[ -n "$maxage" && "$maxage" -gt 300 ]]; then
    red "入口页浏览器长缓存（${CC}）—— 发版后老用户会一直拿到旧 HTML"
  elif [[ -z "$maxage" ]]; then
    ylw "入口页只有 s-maxage、没有 max-age/no-cache（${CC}）—— 浏览器侧会走启发式缓存"
  else
    grn "入口页 cache-control: ${CC}"
  fi
fi
[[ -n "$CE" ]] && grn "入口页已压缩（${CE}）" || red "入口页未压缩"

# ---------- 2. 资源抽样：js / css / 图片或字体 ----------
ASSETS=()
while IFS= read -r a; do ASSETS+=("$a"); done < <(curl -s -m 10 "$BASE/" | grep -oE '(/[^"'"'"' <>]+\.(js|css|woff2|png|svg|webp))' | awk '!s[$0]++' | head -12)
if [[ ${#ASSETS[@]} -eq 0 ]]; then
  ylw "首页没抓到静态资源引用，跳过资源抽样"
else
  hdr "资源抽样（从首页抓到的 ${#ASSETS[@]} 个里各类型取 1 个）"
  for ext in js css woff2 png svg webp; do
    pick=""
    for a in "${ASSETS[@]}"; do [[ "$a" == *".$ext" ]] && { pick="$a"; break; }; done
    [[ -z "$pick" ]] && continue
    ACC="$(get_h "$BASE$pick" cache-control)"
    ACE="$(get_h "$BASE$pick" content-encoding)"
    AC="$(code_of "$BASE$pick")"
    LEN="$(curl -s -m 10 -o /dev/null -w '%{size_download}' "$BASE$pick" 2>/dev/null || echo 0)"
    if [[ ! "$AC" =~ ^2 ]]; then red "$pick → HTTP $AC"; continue; fi

    # 压缩：文本类必须有；小于 1KB 的不要求（压缩反而更大）
    if [[ "$ext" =~ ^(js|css|svg)$ && "${LEN:-0}" -gt 1024 ]]; then
      [[ -n "$ACE" ]] && grn "$pick 已压缩（${ACE}）" || red "$pick 未压缩（${LEN}B 文本类必须压缩）"
    fi

    # 缓存：判据取决于「文件名带不带内容 hash」——带 hash 才能长缓存
    # 兼容三种命名：app.7cb6236f.css / webpack-f024ad16872d09b1.js / index-CMsygpJg.js（Vite 用 base64url）
    BASE_NAME="${pick##*/}"
    if [[ "$BASE_NAME" =~ [.-][A-Za-z0-9_-]{8,}\.(js|css|woff2|png|webp|svg)$ || "$BASE_NAME" =~ ^[0-9a-f]{8,}\.(js|css|woff2|png|webp|svg)$ ]]; then
      HASHED=1
    else
      HASHED=0
    fi
    if [[ -z "$ACC" ]]; then
      red "$pick 无 cache-control（每次访问都要重新下载）"
    elif [[ "$HASHED" == "1" ]]; then
      if grep -qiE 'immutable' <<<"$ACC" || { m="$(grep -oiE 'max-age=[0-9]+' <<<"$ACC" | head -1 | cut -d= -f2)"; [[ -n "$m" && "$m" -ge 2592000 ]]; }; then
        grn "$pick 长缓存（${ACC}）"
      else
        red "$pick 带 hash 却缓存过短（${ACC}）—— 应该 immutable"
      fi
    else
      # 文件名无 hash：长缓存会让发版后拿不到新文件，必须短缓存 + 重验证
      m="$(grep -oiE 'max-age=[0-9]+' <<<"$ACC" | head -1 | cut -d= -f2)"
      if grep -qiE 'no-store|no-cache' <<<"$ACC" || [[ -n "$m" && "$m" -le 3600 ]]; then
        grn "$pick 短缓存（${ACC}，文件名无 hash，正确）"
      else
        red "$pick 文件名无 hash 却长缓存（${ACC}）—— 发版后用户会拿到旧文件"
      fi
    fi
  done
fi

# ---------- 3. SPA fallback ----------
hdr "路由回退"
NF="$(code_of "$BASE/__audit_nonexistent_$RANDOM")"
if [[ "$NF" == "200" ]]; then
  ylw "未知路径返回 200（SPA 回退）—— 若是 MPA 则应为 404，确认不是吞错误"
else
  grn "未知路径返回 $NF"
fi

# ---------- 4. 容器 vs 公网：谁在兜底 ----------
if [[ -n "$CONTAINER_EP" ]]; then
  hdr "归属比对（容器 $CONTAINER_EP vs 公网）"
  CB="http://${CONTAINER_EP}"
  CB_CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: gzip, br' "$CB/" 2>/dev/null || echo 000)"
  if [[ "$CB_CODE" != "200" ]]; then
    # 容器 IP 通常只在服务器上可达；在笔记本上跑会打到本地代理拿到 502
    ylw "直连容器返回 ${CB_CODE} —— 多半是没在服务器上跑，跳过归属比对（别据此判定未压缩）"
  else
    CC_CE="$(curl -s -m 5 -o /dev/null -D - -H 'Accept-Encoding: gzip, br' "$CB/" 2>/dev/null | tr -d '\r' | grep -i '^content-encoding:' | cut -d: -f2- | xargs)"
    if [[ -z "$CC_CE" && -n "$CE" ]]; then
      ylw "容器未压缩、公网已压缩 → 压缩是 Caddy 兜的。Caddy 配置一改就裸传，容器自己没兜底"
    elif [[ -n "$CC_CE" ]]; then
      grn "容器自身已压缩（${CC_CE}）"
    else
      red "容器与公网都没压缩"
    fi
  fi
fi

echo
[[ "$FAIL" == "0" ]] && printf '\033[32m契约满足\033[0m\n' || printf '\033[31m有硬伤（见上）\033[0m\n'
exit "$FAIL"
