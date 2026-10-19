#!/usr/bin/env bash
# 把部署器与项目配置安装到服务器 /opt/deploy（幂等，可反复执行）
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-hxym}"

echo "==> 安装"
# 不再经 /tmp 中转：/tmp 是世界可写目录（这台机器上还有第二个用户），
# 从 /tmp 以 root 安装等于给本地提权留后门。内容直接从 stdin 交给 root 侧的 tee。
ssh "$HOST" 'sudo -n tee /opt/deploy/bin/deploy.sh.new >/dev/null' < scripts/deploy.sh
ssh "$HOST" 'sudo -n mkdir -p /opt/deploy/bin /opt/deploy/projects /opt/deploy/state /opt/deploy/logs /opt/deploy/tmp /opt/deploy/backups \
  && sudo -n install -m 755 -o root -g root /opt/deploy/bin/deploy.sh.new /opt/deploy/bin/deploy.sh \
  && sudo -n rm -f /opt/deploy/bin/deploy.sh.new'

# 配置同样走 stdin，逐个写入（不落 /tmp）
for f in projects/*.conf; do
  ssh "$HOST" "sudo -n tee /opt/deploy/projects/$(basename "$f") >/dev/null" < "$f"
done

# 代码与配置归 root（部署器以 sudo 运行，若归 ubuntu 则持钥用户改 conf 即得 root）；
# 只有运行时状态与日志给 ubuntu
ssh "$HOST" 'sudo -n chown -R root:root /opt/deploy/bin /opt/deploy/projects \
  && sudo -n chmod 755 /opt/deploy/projects \
  && sudo -n chown -R ubuntu:ubuntu /opt/deploy/state /opt/deploy/logs /opt/deploy/tmp /opt/deploy/backups \
  && echo 已安装 $(ls /opt/deploy/projects/*.conf | wc -l) 个项目配置'

# 版本戳：服务器上没有 git，改了 deploy.sh 忘记 install.sh 会静默跑旧版
# （2026-10-19 就发生过）。部署时打印它，日志里能对上是哪版部署器。
VER="$(git rev-parse --short HEAD 2>/dev/null || echo unknown) @ $(date '+%Y-%m-%d %H:%M')"
printf '%s\n' "$VER" | ssh "$HOST" 'sudo -n tee /opt/deploy/bin/deploy.version >/dev/null && sudo -n chmod 644 /opt/deploy/bin/deploy.version'
echo "  部署器版本 $VER"

# 磁盘只增不减：回滚点只在成功路径清理，构建缓存从不清理 → 每天兜一次底
echo "==> 定时清理"
ssh "$HOST" 'sudo -n bash -s' <<'REMOTE'
set -e
crontab -l 2>/dev/null | grep -vF '/opt/deploy/bin/deploy.sh cleanup' > /tmp/cron.new || true
echo '0 4 * * * /opt/deploy/bin/deploy.sh cleanup >> /opt/deploy/logs/cleanup.log 2>&1' >> /tmp/cron.new
crontab /tmp/cron.new
rm -f /tmp/cron.new
echo "  已配置每日 04:00 清理"
REMOTE

echo "==> 自检"
ssh "$HOST" 'sudo -n /opt/deploy/bin/deploy.sh list'
