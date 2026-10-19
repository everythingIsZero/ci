#!/usr/bin/env bash
# ============================================================
# deploy.sh — 统一部署器（服务器侧唯一入口）
#
# 设计原则：构建与替换彻底分离。本脚本从不 build，只做
#   备份 → 旁路自检 → 原子切换 → 三层验收 → 失败自动回滚
#
# 用法：
#   deploy.sh deploy   <project> [--sha <sha>] [--skip-selfcheck]
#   deploy.sh rollback <project>
#   deploy.sh status   <project>
#   deploy.sh verify   <project>
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
  state_set "$p" "PREV_TAG=$tag" "PREV_IMAGE=$cur"
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

# ---------- 验收：三层 ----------
verify() {
  local p="$1" base="https://${DOMAIN}" code fail=0
  step "验收 L1：基础可用"

  for path in $(printf '%s\n' "/" "$HEALTH_PATH" $SMOKE_PATHS | awk '!seen[$0]++'); do
    [[ -z "$path" ]] && continue
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${base}${path}" || echo 000)"
    if [[ "$code" =~ ^2|^3 ]]; then ok "${path} → ${code}"; else c_red "  ${path} → ${code}"; fail=1; fi
  done

  if [[ "${CHECK_COMPRESS:-0}" == "1" ]]; then
    step "验收 L2：产物层（压缩 / 缓存头）"
    local probe="${COMPRESS_PROBE:-}"
    if [[ "$probe" == "auto" ]]; then
      probe="$(curl -s -m 10 "${base}/" | grep -oE '/[^"'"'"' <>]+\.(js|css)' | head -1 || true)"
      [[ -n "$probe" ]] && echo "  自动选取探测资源：$probe"
    fi
    if [[ -n "$probe" ]]; then
      local hdr; hdr="$(curl -sI -m 10 -H 'Accept-Encoding: gzip, br' "${base}${probe}" || true)"
      if grep -qi '^content-encoding:' <<<"$hdr"; then
        ok "${probe} 已压缩（$(grep -i '^content-encoding:' <<<"$hdr" | tr -d '\r')）"
      else
        c_red "  ${probe} 未压缩 —— 检查 nginx gzip / Caddy encode"; fail=1
      fi
      if grep -qi '^cache-control:' <<<"$hdr"; then
        ok "cache-control: $(grep -i '^cache-control:' <<<"$hdr" | tr -d '\r' | cut -d: -f2- | xargs)"
      else
        warn "缺少 cache-control 头"
      fi
    else
      warn "未配置 COMPRESS_PROBE，跳过压缩检查"
    fi
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
  local sha="" skip_selfcheck=0 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha) sha="$2"; shift 2 ;;
      --image) IMAGE_OVERRIDE="$2"; shift 2 ;;
      --skip-selfcheck) skip_selfcheck=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) die "未知参数 $1" 2 ;;
    esac
  done

  load_conf "$p"
  local target="${IMAGE_OVERRIDE:-${PROJECT}:${sha:-latest}}"
  local logf="$LOG_DIR/${p}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$logf") 2>&1

  step "部署 ${PROJECT} → ${target}"
  echo "  形态 ${MODE} · 域名 ${DOMAIN} · 日志 ${logf}"

  $DOCKER image inspect "$target" >/dev/null 2>&1 || {
    if [[ "$target" == *"/"* ]]; then
      step "拉取镜像 $target（增量）"
      $DOCKER pull "$target" || die "镜像 ${target} 拉取失败" 2
    else
      die "镜像 ${target} 不在本机，先传输" 2
    fi
  }
  ok "镜像已就位：$($DOCKER image inspect -f '{{.Id}}' "$target" | cut -c1-19)"

  backup_current "$p" "$dry_run"

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
  if ! compose_up; then
    c_red "切换失败，立即回滚"
    cmd_rollback "$p" --auto
    exit 1
  fi
  ok "容器已切换"

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
  retag "$prev" "$IMAGE_LOCAL"
  compose_up || die "回滚切换失败，需人工介入" 1
  ok "已回滚到 ${prev}"

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
  step "状态 ${PROJECT}"
  echo "  形态      $MODE"
  echo "  域名      https://${DOMAIN}${HEALTH_PATH}"
  echo "  当前镜像  $($DOCKER image inspect -f '{{.Id}}' "$IMAGE_LOCAL" 2>/dev/null | cut -c1-19 || echo 未知)"
  echo "  上次提交  $(state_get "$p" LAST_SHA)"
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

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    deploy)   [[ $# -ge 1 ]] || die "用法：deploy.sh deploy <project>" 2; cmd_deploy "$@" ;;
    rollback) [[ $# -ge 1 ]] || die "用法：deploy.sh rollback <project>" 2; cmd_rollback "$@" ;;
    status)   [[ $# -ge 1 ]] || die "用法：deploy.sh status <project>" 2; cmd_status "$@" ;;
    verify)   [[ $# -ge 1 ]] || die "用法：deploy.sh verify <project>" 2; cmd_verify "$@" ;;
    selfcheck) [[ $# -ge 1 ]] || die "用法：deploy.sh selfcheck <project> [image]" 2; cmd_selfcheck "$@" ;;
    list)     cmd_list ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
}

main "$@"
