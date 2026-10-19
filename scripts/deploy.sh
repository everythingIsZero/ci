#!/usr/bin/env bash
# ============================================================
# deploy.sh — 统一部署器（服务器侧唯一入口）
#
# 设计原则：构建与替换彻底分离。本脚本从不 build，只做
#   备份 → 旁路自检 → 原子切换 → 三层验收 → 失败自动回滚
#
# 用法：
#   deploy.sh deploy   <project> [--sha <sha>] [--image <ref>] [--build] [--tar -] [--skip-selfcheck] [--dry-run]
#   deploy.sh rollback <project>
#   deploy.sh status   <project>
#   deploy.sh verify   <project>
#   deploy.sh cleanup
#   deploy.sh list
#
# 退出码：0 成功 · 1 部署/验收失败（已尝试回滚）· 2 前置条件不满足
# ============================================================
set -Eeuo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/deploy}"
CONF_DIR="$DEPLOY_ROOT/projects"
STATE_DIR="$DEPLOY_ROOT/state"
LOG_DIR="$DEPLOY_ROOT/logs"
TMP_DIR="$DEPLOY_ROOT/tmp"
KEEP_ROLLBACK="${KEEP_ROLLBACK:-5}"
DOCKER="${DOCKER:-sudo -n docker}"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"

# ---------- 输出 ----------
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()     { c_grn "  ✓ $*"; }
warn()   { c_ylw "  ! $*"; }
die()    { c_red "  ✗ $*"; exit "${2:-1}"; }

# ---------- 配置 ----------
load_conf() {
  local p="$1"
  local f="$CONF_DIR/$p.conf"
  [[ -f "$f" ]] || die "找不到项目配置 $f" 2
  # shellcheck disable=SC1090
  source "$f"
  : "${PROJECT:?conf 缺 PROJECT}"
  : "${MODE:?conf 缺 MODE}"
  : "${DOMAIN:?conf 缺 DOMAIN}"
  HEALTH_PATH="${HEALTH_PATH:-/}"
  PORT="${PORT:-3000}"
  SMOKE_PATHS="${SMOKE_PATHS:-}"
  SELFCHECK_WAIT="${SELFCHECK_WAIT:-20}"
}

state_file() { echo "$STATE_DIR/$1.state"; }

state_get() {
  local f; f="$(state_file "$1")"
  [[ -f "$f" ]] || { echo ""; return; }
  grep -E "^$2=" "$f" | tail -1 | cut -d= -f2- || true
}

state_set() {
  local p="$1" f; f="$(state_file "$p")"
  shift
  touch "$f"
  for kv in "$@"; do
    local k="${kv%%=*}"
    grep -vE "^${k}=" "$f" > "$f.tmp" 2>/dev/null || true
    echo "$kv" >> "$f.tmp"
    mv "$f.tmp" "$f"
  done
}

# ---------- 源码同步：必须在锁内做 ----------
# 放在 CI 里做的话，两个部署可以交叉写同一个 SOURCE_DIR（A 同步 → B 同步 → A 构建，
# 构建的是 B 的源码）。移到锁内后「同步 + 构建 + 切换」是一个整体。
#
# 分两步：先 recv（收包 + 校验），再 extract（清空 + 解包）。
# 中间夹着 backup_current —— 半截的流不该把回滚点转掉（转了就等于丢掉上一个可回滚版本）。
STAGED_TAR=""

recv_source() {
  local src="$1"
  [[ "$src" == "-" ]] || die "--tar 只支持 -（从 stdin 读 tar）" 2
  [[ -t 0 ]] && die "--tar - 需要管道输入，当前 stdin 是终端" 2
  STAGED_TAR="$TMP_DIR/${PROJECT}-src-$$.tar"
  cat > "$STAGED_TAR"
  if [[ ! -s "$STAGED_TAR" ]]; then
    rm -f "$STAGED_TAR"; STAGED_TAR=""
    die "收到的源码包为空，已中止（线上源码与回滚点均未动）" 2
  fi
  if ! tar tf "$STAGED_TAR" >/dev/null 2>&1; then
    rm -f "$STAGED_TAR"; STAGED_TAR=""
    die "源码包损坏，已中止（线上源码与回滚点均未动）" 2
  fi
  echo "  源码包 $(du -h "$STAGED_TAR" | cut -f1) 已收到并校验"
}

extract_source() {
  local sd
  sd="$(cmd_where "$PROJECT")"
  step "同步源码 → $sd"
  # 保留 node_modules：服务器侧依赖复用，否则每次全量重装
  find "$sd" -mindepth 1 -maxdepth 1 ! -name node_modules -exec rm -rf {} + 2>/dev/null || true
  tar xf "$STAGED_TAR" -C "$sd" --no-same-owner
  rm -f "$STAGED_TAR"; STAGED_TAR=""
  ok "源码已同步（$(du -sh "$sd" | cut -f1)）"
}

# ---------- 构建期变量：缺了就构建不出对的镜像 ----------
# compose.yml 里的 build.args 从「项目目录/.env」取值，这个文件是手工放的、不在仓库里。
# 缺了不会报错，只会静默构建出缺配置的镜像（如统计 id 为空）。
check_build_env() {
  [[ -n "${BUILD_ENV_REQUIRED:-}" ]] || return 0
  local f="${BUILD_ENV_FILE:-${COMPOSE_PROJECT_DIR:-}/.env}"
  [[ -f "$f" ]] || die "构建需要 ${BUILD_ENV_REQUIRED}，但找不到 $f" 2
  local k v
  for k in $BUILD_ENV_REQUIRED; do
    v="$(grep -E "^${k}=" "$f" | tail -1 | cut -d= -f2-)"
    v="${v%$'\r'}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [[ -n "$v" ]] || die "构建变量 ${k} 在 $f 里为空 —— 会静默构建出缺该配置的镜像" 2
  done
  ok "构建期变量齐备：${BUILD_ENV_REQUIRED}"
}

# ---------- 形态适配：把「切换」抽象成两条路径 ----------
current_image_id() {
  case "$MODE" in
    self-compose)
      $DOCKER inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || echo ""
      ;;
    central-stack)
      $DOCKER inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || echo ""
      ;;
    *) echo "" ;;
  esac
}

compose_up() {
  case "$MODE" in
    self-compose)
      $DOCKER compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_PROJECT_DIR" \
        up -d --no-build --force-recreate "$SERVICE"
      ;;
    central-stack)
      $DOCKER compose -f "$STACK_FILE" up -d --no-build --force-recreate "$SERVICE"
      ;;
    *) die "未知 MODE=$MODE" 2 ;;
  esac
}

compose_build() {
  case "$MODE" in
    self-compose)
      $DOCKER compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_PROJECT_DIR" build "$SERVICE"
      ;;
    central-stack)
      $DOCKER compose -f "$STACK_FILE" build "$SERVICE"
      ;;
    *) die "未知 MODE=$MODE" 2 ;;
  esac
}

# 把镜像打成 compose 认识的名字（零侵入：不改任何 compose 文件）
retag() {
  local src="$1" dst="$2"
  $DOCKER tag "$src" "$dst"
}

# ---------- 备份：切换前先留退路 ----------
backup_current() {
  local p="$1" dry="${2:-0}" ts cur tag prefix
  ts="$(date +%Y%m%d-%H%M%S)"
  prefix="${IMAGE_LOCAL%%:*}"
  cur="$(current_image_id)"
  if [[ -z "$cur" ]]; then
    warn "当前容器不存在或未运行，跳过回滚点（首次部署）"
    state_set "$p" "PREV_TAG="
    return 0
  fi
  tag="${prefix}:rollback-${ts}"
  if [[ "$dry" == "1" ]]; then
    echo "  (dry-run) 将保存回滚点 ${tag} → ${cur:0:19}"
    return 0
  fi
  retag "$cur" "$tag"

  # 镜像之外还要备份「配置与数据」：compose 文件在 SOURCE_DIR 内会被同步覆盖，
  # 只还原镜像不还原 compose，等于用坏配置再启一次。
  local bak="$DEPLOY_ROOT/backups/$p/$ts"
  mkdir -p "$bak" 2>/dev/null || true
  if [[ -f "${COMPOSE_FILE:-}" ]]; then
    cp "$COMPOSE_FILE" "$bak/compose.yml" 2>/dev/null && ok "compose 已备份"
  elif [[ -f "${STACK_FILE:-}" ]]; then
    cp "$STACK_FILE" "$bak/stack.yml" 2>/dev/null && warn "集中栈 compose 已备份（回滚不自动还原，避免波及同栈其他服务）"
  fi
  if [[ -n "${DB_PATH:-}" && -f "${DB_PATH:-}" ]]; then
    cp "$DB_PATH" "$bak/" 2>/dev/null && ok "数据库已备份（cp 快照，WAL 模式下不保证一致）" \
      || warn "数据库备份失败：$DB_PATH"
  fi

  state_set "$p" "PREV_TAG=$tag" "PREV_IMAGE=$cur" "PREV_DIR=$bak"
  ok "回滚点已保存：$tag"
}

# ---------- 旁路自检：不碰线上容器、不碰生产端口 ----------
selfcheck() {
  local p="$1" img="$2" name vol cid ip code i
  name="${PROJECT}-selfcheck-$$"
  vol="$(mktemp -d "$TMP_DIR/${PROJECT}-selfcheck-XXXXXX")"
  chmod 777 "$vol" 2>/dev/null || true

  local run_args=(--rm -d --name "$name" -e NODE_ENV=production)
  [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE:-}" ]] && run_args+=(--env-file "$ENV_FILE")
  [[ -n "${SELFCHECK_VOLUME:-}" ]] && run_args+=(-v "${vol}:${SELFCHECK_VOLUME}")
  [[ -n "${SELFCHECK_NETWORK:-}" ]] && run_args+=(--network "$SELFCHECK_NETWORK")
  [[ -n "${SELFCHECK_CMD:-}" ]] && run_args+=(--entrypoint "${SELFCHECK_CMD%% *}")

  step "旁路自检：$img"
  if ! $DOCKER run "${run_args[@]}" "$img" ${SELFCHECK_CMD:+${SELFCHECK_CMD#* }} >/dev/null 2>"$TMP_DIR/${name}.err"; then
    c_red "  容器无法启动"
    sed -n '1,20p' "$TMP_DIR/${name}.err" >&2 || true
    rm -rf "$vol"
    return 1
  fi

  local passed=0
  for ((i = 0; i < SELFCHECK_WAIT; i++)); do
    if [[ "$($DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
      c_red "  容器启动后立即退出（多为生产必填 env 缺失）"
      $DOCKER logs --tail 40 "$name" 2>&1 | sed 's/^/    /' || true
      $DOCKER rm -f "$name" >/dev/null 2>&1 || true
      rm -rf "$vol"
      return 1
    fi
    ip="$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null)"
    if [[ -n "$ip" ]]; then
      code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${ip}:${PORT}${HEALTH_PATH}" || echo 000)"
      if [[ "$code" == "200" ]]; then passed=1; break; fi
    fi
    sleep 1
  done

  if [[ "$passed" != "1" ]]; then
    c_red "  自检探活失败（${HEALTH_PATH} 未返回 200，最后状态 ${code:-无响应}）"
    $DOCKER logs --tail 40 "$name" 2>&1 | sed 's/^/    /' || true
    $DOCKER rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$vol"
    return 1
  fi

  ok "旁路自检通过（${HEALTH_PATH} = 200）"
  $DOCKER rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$vol"
  return 0
}

wait_ready() {
  local i st code
  for ((i = 0; i < 45; i++)); do
    st="$($DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo unknown)"
    case "$st" in
      healthy)
        ok "容器就绪（healthy，等待 ${i}s）"
        return 0
        ;;
      starting)
        sleep 1
        continue
        ;;
      unhealthy)
        c_red "容器健康检查失败（unhealthy）"
        $DOCKER logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
        return 1
        ;;
      none)
        # 没有 HEALTHCHECK 的容器：running ≠ 应用就绪，必须实打实探活
        code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "https://${DOMAIN}${HEALTH_PATH}" 2>/dev/null || echo 000)"
        if [[ "$code" == "200" ]]; then
          ok "容器就绪（无 healthcheck，${HEALTH_PATH} 返回 200，等待 ${i}s）"
          return 0
        fi
        ;;
      exited|dead)
        c_red "容器已退出（${st}）"
        $DOCKER logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
        return 1
        ;;
    esac
    sleep 1
  done
  c_red "容器 45 秒内未就绪（最后状态 ${st}，HTTP ${code:-无}）"
  $DOCKER logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
  return 1
}

# ---------- 产物契约：压缩 / 缓存 ----------
# 判据写死在这里，不靠人记。压缩与缓存问题反复出现的根因是「只探一个资源 + 只打公网
# + 缺头只 warn」——Caddy 的 encode 会盖住容器没开压缩，抽样一个又可能正好挑到正常的那个。
asset_headers() { curl -s -m 10 -o /dev/null -D - -H 'Accept-Encoding: gzip, br' "$1" 2>/dev/null | tr -d '\r'; }
asset_h() { asset_headers "$1" | grep -iE "^$2:" | tail -1 | cut -d: -f2- | sed 's/^ *//'; }

# ASSET_CONTRACT=warn（默认，只报告）| enforce（计入失败 → 会触发回滚）
# 存量项目先 warn，修干净后再改 enforce —— 否则一次部署会因为历史遗留的头直接回滚。
verify_assets() {
  local base="$1" ip="$2" mode="${ASSET_CONTRACT:-warn}" bad=0
  local cc ce a url ext name m len hashed picked cce

  step "验收 L2：产物契约（压缩 / 缓存）"
  if [[ "$mode" == "enforce" ]]; then echo "  模式 enforce（不满足即失败）"; else echo "  模式 warn（只报告，不阻断本次部署）"; fi

  # 入口页：必须有策略；浏览器只看 max-age，s-maxage 只对 CDN 生效
  cc="$(asset_h "$base/" cache-control)"
  ce="$(asset_h "$base/" content-encoding)"
  if [[ -z "$cc" ]]; then
    c_red "  入口页无 cache-control —— 浏览器会启发式缓存"; bad=1
  elif grep -qiE 'no-store|no-cache' <<<"$cc"; then
    ok "入口页 ${cc}"
  else
    m="$(grep -oiE '(^|[ ,])max-age=[0-9]+' <<<"$cc" | head -1 | grep -oE '[0-9]+')"
    if [[ -n "$m" && "$m" -gt 300 ]]; then
      c_red "  入口页浏览器长缓存（${cc}）—— 发版后老用户会一直拿到旧 HTML"; bad=1
    elif [[ -z "$m" ]]; then
      warn "入口页只有 s-maxage、无 max-age/no-cache（${cc}）—— 浏览器侧走启发式缓存"
    else
      ok "入口页 ${cc}"
    fi
  fi
  [[ -n "$ce" ]] && ok "入口页已压缩（${ce}）" || { c_red "  入口页未压缩"; bad=1; }

  # 资源抽样：js / css / 图片 各取 1 个（不再只探一个）
  for ext in js css png svg; do
    picked=""
    while IFS= read -r a; do [[ "$a" == *".$ext" ]] && { picked="$a"; break; }; done \
      < <(curl -s -m 10 "$base/" | grep -oE "/[^\"' <>]+\.${ext}" | awk '!s[$0]++')
    [[ -z "$picked" ]] && continue
    url="${base}${picked}"
    cc="$(asset_h "$url" cache-control)"
    ce="$(asset_h "$url" content-encoding)"
    len="$(curl -s -m 10 -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"
    name="${picked##*/}"
    hashed=0
    if [[ "$name" =~ [.-][A-Za-z0-9_-]{8,}\.(js|css|png|svg|woff2|webp)$ || "$name" =~ ^[0-9a-f]{8,}\.(js|css|png|svg|woff2|webp)$ ]]; then hashed=1; fi

    # 压缩：文本类必须；小于 1KB 不要求（压了反而更大）
    if [[ "$ext" =~ ^(js|css|svg)$ && "${len:-0}" -gt 1024 ]]; then
      if [[ -n "$ce" ]]; then ok "${picked} 已压缩（${ce}）"; else c_red "  ${picked} 未压缩（${len}B）"; bad=1; fi
    fi

    # 缓存：带 hash 才能长缓存；不带 hash 必须短缓存 + 重验证
    if [[ -z "$cc" ]]; then
      c_red "  ${picked} 无 cache-control —— 每次访问都要重新下载"; bad=1
    elif [[ "$hashed" == "1" ]]; then
      if grep -qi immutable <<<"$cc" || { m="$(grep -oiE 'max-age=[0-9]+' <<<"$cc" | head -1 | cut -d= -f2)"; [[ -n "$m" && "$m" -ge 2592000 ]]; }; then
        ok "${picked} 长缓存（${cc}）"
      else
        c_red "  ${picked} 带 hash 却缓存过短（${cc}）"; bad=1
      fi
    else
      m="$(grep -oiE 'max-age=[0-9]+' <<<"$cc" | head -1 | cut -d= -f2)"
      if grep -qiE 'no-store|no-cache' <<<"$cc" || [[ -n "$m" && "$m" -le 3600 ]]; then
        ok "${picked} 短缓存（${cc}，文件名无 hash，正确）"
      else
        c_red "  ${picked} 文件名无 hash 却长缓存（${cc}）—— 发版后用户会拿到旧文件"; bad=1
      fi
    fi
  done

  # 压缩归属：容器自己开没开（公网压缩可能只是 Caddy 兜的）
  if [[ -n "$ip" ]]; then
    cce="$(asset_h "http://${ip}:${PORT}/" content-encoding)"
    if [[ -n "$cce" ]]; then
      ok "容器自身已压缩（${cce}）"
    elif [[ -n "$ce" ]]; then
      warn "容器自身未压缩、公网压缩由 Caddy 兜底 —— Caddy 配置一改就裸传"
    else
      c_red "  容器与公网都未压缩"; bad=1
    fi
  fi

  if [[ "$bad" == "1" && "$mode" != "enforce" ]]; then
    warn "产物契约有未满足项（warn 模式，不影响本次部署）"
    return 0
  fi
  return "$bad"
}

# ---------- 验收：三层 ----------
verify() {
  local p="$1" base="https://${DOMAIN}" code fail=0
  step "验收 L1：基础可用"

  # 先直连容器，确认「新容器自己在服务」——只打公网域名的话，
  # Caddy 还指向旧容器时会验出假绿。
  local ip
  ip="$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null)"
  if [[ -n "$ip" ]]; then
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${PORT}${HEALTH_PATH}" || echo 000)"
    if [[ "$code" == "200" ]]; then ok "容器直连 ${HEALTH_PATH} → 200"; else c_red "容器直连 ${HEALTH_PATH} → ${code}"; fail=1; fi
  else
    warn "拿不到容器 IP，跳过直连检查"
  fi

  # 运行中的容器必须就是 IMAGE_LOCAL 指向的那个镜像 —— 否则「验收通过」验的是别的东西
  local run_img tag_img
  run_img="$($DOCKER inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"
  tag_img="$($DOCKER image inspect -f '{{.Id}}' "$IMAGE_LOCAL" 2>/dev/null || true)"
  if [[ -n "$run_img" && -n "$tag_img" ]]; then
    if [[ "$run_img" == "$tag_img" ]]; then
      ok "运行镜像 = ${IMAGE_LOCAL}（${run_img:7:12}）"
    else
      c_red "运行镜像 ≠ ${IMAGE_LOCAL}（容器 ${run_img:7:12} / 标签 ${tag_img:7:12}）—— 容器没切过来"; fail=1
    fi
  else
    warn "镜像身份比对跳过（容器或标签缺失）"
  fi

  for path in $(printf '%s\n' "/" "$HEALTH_PATH" $SMOKE_PATHS | awk '!seen[$0]++'); do
    [[ -z "$path" ]] && continue
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${base}${path}" || echo 000)"
    if [[ "$code" =~ ^2|^3 ]]; then ok "${path} → ${code}"; else c_red "  ${path} → ${code}"; fail=1; fi
  done

  if [[ "${CHECK_COMPRESS:-0}" == "1" ]]; then
    verify_assets "$base" "$ip" || fail=1
  fi

  if [[ -n "${VERSION_PATH:-}" ]]; then
    step "验收 L2：产物指纹"
    local ver; ver="$(curl -s -m 10 "${base}${VERSION_PATH}" || true)"
    if [[ -n "$ver" ]]; then
      ok "${VERSION_PATH} → ${ver:0:120}"
      if grep -qiE 'NOT_FOUND|接口不存在|Cannot (GET|POST)|404' <<<"$ver"; then
        c_red "  ${VERSION_PATH} 返回的是错误体，不是版本信息"; fail=1
      elif [[ -n "${EXPECT_SHA:-}" ]] && grep -q "${EXPECT_SHA:0:7}" <<<"$ver"; then
        ok "指纹与本次提交一致（${EXPECT_SHA:0:7}）"
      elif [[ -n "${EXPECT_SHA:-}" ]]; then
        warn "指纹未包含本次 sha（若项目未注入版本号可忽略）"
      fi
    else
      c_red "  ${VERSION_PATH} 无响应"; fail=1
    fi
  fi

  return $fail
}

# ---------- 主流程 ----------
cmd_deploy() {
  local p="$1"; shift
  local sha="" skip_selfcheck=0 dry_run=0 build=0 tar_src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha) sha="$2"; shift 2 ;;
      --image) IMAGE_OVERRIDE="$2"; shift 2 ;;
      --skip-selfcheck) skip_selfcheck=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --build) build=1; shift ;;
      --tar) tar_src="${2:--}"; shift 2 ;;
      *) die "未知参数 $1" 2 ;;
    esac
  done

  load_conf "$p"
  # 本次提交的 sha 同时作为指纹验收的期望值（conf 里可覆盖）
  EXPECT_SHA="${EXPECT_SHA:-$sha}"
  local target="${IMAGE_OVERRIDE:-${PROJECT}:${sha:-latest}}"
  local logf="$LOG_DIR/${p}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$logf") 2>&1

  step "部署 ${PROJECT} → ${target}"
  echo "  形态 ${MODE} · 域名 ${DOMAIN} · 日志 ${logf}"

  # 先把源码收下来并验完：包是坏的就不该动备份（转了回滚点 = 丢掉上一个可回滚版本）
  [[ -n "$tar_src" ]] && recv_source "$tar_src"

  # 非构建模式：先确认镜像在位（拉不到就不必动源码与备份）
  if [[ "$build" != "1" ]]; then
    $DOCKER image inspect "$target" >/dev/null 2>&1 || {
      if [[ "$target" == *"/"* ]]; then
        step "拉取镜像 $target（增量）"
        $DOCKER pull "$target" || die "镜像 ${target} 拉取失败" 2
      else
        die "镜像 ${target} 不在本机，先传输" 2
      fi
    }
    ok "镜像已就位：$($DOCKER image inspect -f '{{.Id}}' "$target" | cut -c1-19)"
  fi

  # 备份必须早于源码同步：compose.yml 就在 SOURCE_DIR 里，同步之后再备份到的是新配置，
  # 回滚还原它等于用新配置再启一次。
  backup_current "$p" "$dry_run"

  # 同步紧跟备份、且都在锁内：不会出现「A 同步完、B 又同步、A 构建的是 B 的源码」
  [[ -n "$STAGED_TAR" ]] && extract_source

  if [[ "$build" == "1" ]]; then
    check_build_env
    step "服务器构建 $SERVICE（构建期间线上容器不受影响）"
    if [[ "$dry_run" == "1" ]]; then
      warn "dry-run：将执行 compose build（不切换）"
    else
      compose_build || { c_red "构建失败，线上未做任何改动"; exit 1; }
      ok "构建完成"
    fi
    target="$IMAGE_LOCAL"
  fi

  if [[ "$skip_selfcheck" == "0" ]]; then
    if ! selfcheck "$p" "$target"; then
      c_red "\n部署中止：新镜像未通过旁路自检，线上未做任何改动"
      state_set "$p" "LAST_RESULT=selfcheck-failed" "LAST_AT=$(date -Is)"
      exit 1
    fi
  else
    warn "已跳过旁路自检（--skip-selfcheck）"
  fi

  step "原子切换"
  if [[ "$dry_run" == "1" ]]; then
    warn "dry-run：将执行 tag ${target} → ${IMAGE_LOCAL} 并重建容器，实际未改动"
    case "$MODE" in
      self-compose) echo "    docker compose -f $COMPOSE_FILE --project-directory $COMPOSE_PROJECT_DIR up -d --no-build --force-recreate $SERVICE" ;;
      central-stack) echo "    docker compose -f $STACK_FILE up -d --no-build --force-recreate $SERVICE" ;;
    esac
    echo "    回滚点保留在 $(state_get "$p" PREV_TAG)"
    state_set "$p" "LAST_RESULT=dry-run" "LAST_AT=$(date -Is)"
    return 0
  fi
  retag "$target" "$IMAGE_LOCAL"
  ok "已标记 ${target} → ${IMAGE_LOCAL}"
  # 把提交号钉在镜像上：state 里记的 sha 是自述，镜像标签才是可核对的证据
  if [[ -n "$sha" ]]; then
    retag "$IMAGE_LOCAL" "${IMAGE_LOCAL%%:*}:sha-${sha:0:7}"
    ok "提交标签 ${IMAGE_LOCAL%%:*}:sha-${sha:0:7}"
  fi
  if ! compose_up; then
    c_red "切换失败，立即回滚"
    cmd_rollback "$p" --auto
    exit 1
  fi
  ok "容器已切换"

  if ! wait_ready; then
    c_red "新容器未就绪，自动回滚"
    cmd_rollback "$p" --auto
    state_set "$p" "LAST_RESULT=not-ready" "LAST_AT=$(date -Is)"
    exit 1
  fi

  if verify "$p"; then
    state_set "$p" "CURRENT_TAG=$IMAGE_LOCAL" "CURRENT_IMAGE=$($DOCKER image inspect -f '{{.Id}}' "$IMAGE_LOCAL")" \
      "LAST_SHA=$sha" "LAST_RESULT=success" "LAST_AT=$(date -Is)"
    ok "部署成功"
    cleanup_old "$p"
    return 0
  else
    c_red "\n验收失败，自动回滚"
    cmd_rollback "$p" --auto
    state_set "$p" "LAST_RESULT=verify-failed" "LAST_AT=$(date -Is)"
    exit 1
  fi
}

cmd_rollback() {
  local p="$1"; shift || true
  load_conf "$p"
  local auto=0
  [[ "${1:-}" == "--auto" ]] && auto=1

  local prev; prev="$(state_get "$p" PREV_TAG)"
  [[ -n "$prev" ]] || die "没有可用的回滚点（state 里 PREV_TAG 为空）" 2
  $DOCKER image inspect "$prev" >/dev/null 2>&1 || die "回滚镜像 $prev 已被清理" 2

  step "回滚 ${PROJECT} → ${prev}"
  local bak; bak="$(state_get "$p" PREV_DIR)"
  if [[ "$MODE" == "self-compose" && -n "$bak" && -f "$bak/compose.yml" ]]; then
    cp "$bak/compose.yml" "$COMPOSE_FILE" 2>/dev/null && ok "已还原部署前的 compose"
  fi
  retag "$prev" "$IMAGE_LOCAL"
  compose_up || die "回滚切换失败，需人工介入" 1
  ok "已回滚到 ${prev}"
  wait_ready || warn "回滚后容器未在 45 秒内就绪"

  if verify "$p"; then
    state_set "$p" "LAST_RESULT=rolled-back" "LAST_AT=$(date -Is)"
    ok "回滚后验收通过"
  else
    c_red "回滚后验收仍失败 —— 可能不是代码问题（查 Caddy / 证书 / 上游）"
    [[ "$auto" == "1" ]] && exit 1
  fi
}

cmd_status() {
  local p="$1"
  load_conf "$p"
  # 线上到底跑的哪个提交：从运行容器的镜像标签里读，而不是信 state 的自述
  local run_img tags_on sha_tag
  run_img="$($DOCKER inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"
  tags_on="$($DOCKER image inspect -f '{{join .RepoTags " "}}' "$run_img" 2>/dev/null || true)"
  sha_tag="$(grep -oE 'sha-[0-9a-f]{7,40}' <<<"$tags_on" | head -1 | sed 's/^sha-//' || true)"

  step "状态 ${PROJECT}"
  echo "  形态      $MODE"
  echo "  域名      https://${DOMAIN}${HEALTH_PATH}"
  echo "  当前镜像  $($DOCKER image inspect -f '{{.Id}}' "$IMAGE_LOCAL" 2>/dev/null | cut -c1-19 || echo 未知)"
  echo "  线上提交  ${sha_tag:-未知（镜像无 sha 标签）}"
  echo "  上次提交  $(state_get "$p" LAST_SHA)"
  if [[ -n "$sha_tag" && -n "$(state_get "$p" LAST_SHA)" && "$sha_tag" != "$(state_get "$p" LAST_SHA | cut -c1-7)" ]]; then
    c_ylw "  ! 镜像标签与 state 记录不一致 —— 有人手工换过容器，或 state 被改过"
  fi
  echo "  上次结果  $(state_get "$p" LAST_RESULT)  @ $(state_get "$p" LAST_AT)"
  echo "  回滚点    $(state_get "$p" PREV_TAG)"
  echo "  容器      $($DOCKER ps --filter "name=^${CONTAINER}$" --format '{{.Status}}' || echo 未运行)"
}

cmd_verify() { load_conf "$1"; verify "$1" && ok "验收通过"; }

cmd_selfcheck() {
  local p="$1" img="${2:-}"
  load_conf "$p"
  [[ -z "$img" ]] && img="$IMAGE_LOCAL"
  selfcheck "$p" "$img" && ok "自检通过"
}

cmd_where() {
  load_conf "$1"
  local sd="${SOURCE_DIR:-}"
  # 护栏：SOURCE_DIR 会被 CI 清空重解压，写错一层就是删库
  [[ -n "$sd" ]] || die "conf 缺 SOURCE_DIR" 2
  [[ "$sd" =~ ^/opt/[A-Za-z0-9._-]+/.+ ]] || die "SOURCE_DIR 必须是 /opt/<项目>/<子目录>，当前为 $sd" 2
  if [[ -n "${ENV_FILE:-}" && "$ENV_FILE" == "$sd"/* ]]; then
    die "ENV_FILE 位于 SOURCE_DIR 内，同步会删掉密钥：$ENV_FILE" 2
  fi
  if [[ -n "${DB_PATH:-}" && "$DB_PATH" == "$sd"/* ]]; then
    die "DB_PATH 位于 SOURCE_DIR 内，同步会删掉数据：$DB_PATH" 2
  fi
  echo "$sd"
}

cmd_excludes() { load_conf "$1"; echo "${EXCLUDE_PATHS:-}"; }

cmd_list() {
  step "已接入项目"
  for f in "$CONF_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    local p; p="$(basename "$f" .conf)"
    printf '  %-14s %s\n' "$p" "$(grep -E '^DOMAIN=' "$f" | cut -d= -f2)"
  done
}

cleanup_old() {
  local p="$1" keep="$KEEP_ROLLBACK" prefix tags
  prefix="${IMAGE_LOCAL%%:*}"
  tags="$($DOCKER image ls "$prefix" --format '{{.Tag}}' | grep '^rollback-' | sort -r | tail -n +$((keep + 1)) || true)"
  [[ -z "$tags" ]] && return 0
  while read -r t; do
    [[ -z "$t" ]] && continue
    $DOCKER rmi "${prefix}:${t}" >/dev/null 2>&1 && echo "  清理旧回滚点 ${prefix}:${t}" || true
  done <<<"$tags"
}

cmd_cleanup() {
  step "清理悬空镜像"
  $DOCKER image prune -f 2>&1 | tail -2
  # 构建缓存只增不减：不清的话 /var/lib/docker 会一直涨
  if $DOCKER builder prune -f --filter until=168h >/dev/null 2>&1; then
    ok "构建缓存已清理（保留 7 天内，避免下次全量重建）"
  else
    warn "构建缓存清理跳过（当前 builder 不支持 --filter until）"
  fi
  local f p
  for f in "$CONF_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    p="$(basename "$f" .conf)"
    load_conf "$p"
    cleanup_old "$p"
  done
  echo
  df -h / | tail -1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    deploy)
      [[ $# -ge 1 ]] || die "用法：deploy.sh deploy <project>" 2
      exec 9>"$DEPLOY_ROOT/.deploy.lock"
      flock -w "${LOCK_WAIT:-10}" 9 || die "另一个部署正在进行（锁 $DEPLOY_ROOT/.deploy.lock），稍后重试" 2
      cmd_deploy "$@"
      ;;
    rollback)
      [[ $# -ge 1 ]] || die "用法：deploy.sh rollback <project>" 2
      exec 9>"$DEPLOY_ROOT/.deploy.lock"
      flock -w "${LOCK_WAIT:-10}" 9 || die "另一个部署正在进行，稍后重试" 2
      cmd_rollback "$@"
      ;;
    cleanup)  cmd_cleanup ;;
    status)   [[ $# -ge 1 ]] || die "用法：deploy.sh status <project>" 2; cmd_status "$@" ;;
    verify)   [[ $# -ge 1 ]] || die "用法：deploy.sh verify <project>" 2; cmd_verify "$@" ;;
    selfcheck) [[ $# -ge 1 ]] || die "用法：deploy.sh selfcheck <project> [image]" 2; cmd_selfcheck "$@" ;;
    where)    [[ $# -ge 1 ]] || die "用法：deploy.sh where <project>" 2; cmd_where "$@" ;;
    excludes) [[ $# -ge 1 ]] || die "用法：deploy.sh excludes <project>" 2; cmd_excludes "$@" ;;
    list)     cmd_list ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
}

main "$@"
