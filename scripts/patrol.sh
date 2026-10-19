#!/usr/bin/env bash
# ============================================================
# patrol.sh — 部署闭环巡检（只读，不发任何写请求）
#
# 为什么需要它：部署器自己写的 `LAST_RESULT=success` 是**自述**，不是证据。
# 2026-10-19 一天里出现三种静默失败，全靠人工去 `gh run view` / ssh 看日志才发现：
#   ① workflow 文件本身非法 → startup_failure，2 秒结束、**连一个 job 都没有**，
#      GitHub 的 workflow 失败通知发不出来；
#   ② 部署器在 rollback-point 阶段 exit 1，线上没变，但没人知道；
#   ③ 验收失败自动回滚 → 线上还是旧版本，日志里只有一行「已回滚」。
# 更隐蔽的是第四种：**代码推了但没部署** —— 线上跑的提交 ≠ 仓库 HEAD，
# 没有任何机制会提示，只有人手动比对才发现（当天 nuantie/home 都落后一个提交）。
#
# 本脚本把四件事逐条判红绿：
#   ① 仓库 HEAD 是否已经在线上跑（比对镜像上的 sha-<7> 标签，不信 state 自述）
#   ② LAST_RESULT 是否 success
#   ③ 是否还留有回滚点（PREV_TAG 非空）—— 没有回滚点的部署是裸奔
#   ④ 最近几次 workflow run 有没有失败（含 startup_failure）
#
# 用法：
#   patrol.sh                 # 巡检 conf 里所有已接入项目
#   patrol.sh nuantie         # 只查一个
#   HOST=hxym patrol.sh       # 指定 ssh 别名（CI 里用部署密钥的 config）
#
# 退出码：0 全绿 · 1 有红
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-hxym}"
OWNER="${OWNER:-everythingIsZero}"
CONF_DIR="projects"
ONLY="${1:-}"
FAIL=0

red() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAIL=1; }
grn() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
ylw() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
hdr() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# 一次性把服务器侧状态拉下来（每条 ssh 往返都很贵，别在循环里逐条问）
remote_state() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'sudo -n bash -s' <<'REMOTE' 2>/dev/null
set -u
for f in /opt/deploy/state/*.state; do
  [[ -e "$f" ]] || continue
  p="$(basename "$f" .state)"
  echo "### ${p}"
  sed 's/^/  /' "$f"
  # 线上镜像的 sha 标签（从 CURRENT_IMAGE 反查，而不是信 LAST_SHA）
  img="$(sed -n 's/^CURRENT_IMAGE=//p' "$f")"
  if [[ -n "$img" ]]; then
    tags="$(docker inspect -f '{{join .RepoTags " "}}' "$img" 2>/dev/null || echo '')"
    echo "  IMAGE_TAGS=$tags"
  fi
done
REMOTE
}

hdr "巡检 $(date '+%Y-%m-%d %H:%M') · 主机 $HOST"

STATE_RAW="$(remote_state)"
if [[ -z "$STATE_RAW" ]]; then
  red "取不到服务器状态（ssh $HOST 失败，或 /opt/deploy/state 为空）"
  exit 1
fi

for f in "$CONF_DIR"/*.conf; do
  [[ -e "$f" ]] || continue
  p="$(basename "$f" .conf)"
  [[ -n "$ONLY" && "$p" != "$ONLY" ]] && continue
  # REPO 默认与项目名一致；不一致的 conf 里显式写 REPO=
  repo="$(sed -n 's/^REPO=//p' "$f" | head -1 | tr -d "\"'")"
  repo="${repo:-$p}"

  echo
  printf '\033[1m%s\033[0m （%s）\n' "$p" "$repo"

  block="$(awk -v k="### $p" '$0==k{f=1;next} /^### /{f=0} f' <<<"$STATE_RAW")"
  if [[ -z "$block" ]]; then
    red "服务器上没有该项目的 state（从未部署过？）"
    continue
  fi
  g() { sed -n "s/^ *$1=//p" <<<"$block" | head -1; }

  last_sha="$(g LAST_SHA)"
  last_res="$(g LAST_RESULT)"
  last_at="$(g LAST_AT)"
  prev_tag="$(g PREV_TAG)"
  tags="$(g IMAGE_TAGS)"

  # ① 线上是否真的是 HEAD 这一版
  head_sha="$(gh api "repos/$OWNER/$repo/commits/HEAD" --jq .sha 2>/dev/null | cut -c1-7)"
  if [[ -z "$head_sha" ]]; then
    red "取不到 $OWNER/$repo 的 HEAD（仓库名对不对？私有仓授权？）"
  elif [[ "$tags" == *":sha-$head_sha"* ]]; then
    grn "线上就是 HEAD（sha-${head_sha}）"
  else
    red "线上落后：HEAD=${head_sha}，线上标签=$(grep -oE 'sha-[0-9a-f]{7}' <<<"$tags" | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  fi

  # ② 部署器自述的结果
  if [[ "$last_res" == "success" ]]; then
    grn "LAST_RESULT=success（${last_at:-无时间}）"
  else
    red "LAST_RESULT=${last_res:-空}（${last_at:-无时间}）"
  fi

  # ③ 有没有回滚点（没有 = 出事只能重建，不能回退）
  if [[ -n "$prev_tag" ]]; then
    grn "回滚点 ${prev_tag}"
  else
    ylw "没有回滚点（PREV_TAG 空）—— 本次部署出事无法回退"
  fi

  # ④ 最近 5 次 run 里的失败（含 startup_failure：那种连 job 都没有，通知发不出来）
  runs="$(gh run list -R "$OWNER/$repo" --limit 5 \
    --json conclusion,event,headSha,createdAt,displayTitle \
    --jq '.[] | "\(.conclusion // "running")\t\(.event)\t\(.headSha[0:7])\t\(.createdAt)"' 2>/dev/null)"
  bad="$(grep -E '^(failure|startup_failure|cancelled)\b' <<<"$runs" || true)"
  if [[ -z "$bad" ]]; then
    grn "最近 5 次 run 无失败"
  else
    while IFS=$'\t' read -r c e s t; do
      [[ -z "$c" ]] && continue
      # cancelled 多半是 concurrency 主动取消，不算事故
      if [[ "$c" == "cancelled" ]]; then ylw "run 被取消（$e $s ${t:0:16}）—— 多为 concurrency 主动取消"
      else red "run ${c}（$e $s ${t:0:16}）"; fi
    done <<<"$bad"
  fi
done

echo
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32m全部通过\033[0m\n'
else
  printf '\033[31m有红项 —— 线上状态与仓库不一致或部署失败，需处理\033[0m\n'
fi
exit "$FAIL"
