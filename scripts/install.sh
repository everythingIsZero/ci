#!/usr/bin/env bash
# 把部署器与项目配置安装到服务器 /opt/deploy（幂等，可反复执行）
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-hxym}"

echo "==> 传输"
rsync -az scripts/deploy.sh "$HOST":/tmp/deploy.sh
rsync -az projects/ "$HOST":/tmp/deploy-projects/

echo "==> 安装"
# 代码与配置归 root（部署器以 sudo 运行，若归 ubuntu 则持钥用户改 conf 即得 root）；
# 只有运行时状态与日志给 ubuntu
ssh "$HOST" 'sudo -n mkdir -p /opt/deploy/bin /opt/deploy/projects /opt/deploy/state /opt/deploy/logs /opt/deploy/tmp /opt/deploy/backups \
  && sudo -n install -m 755 -o root -g root /tmp/deploy.sh /opt/deploy/bin/deploy.sh \
  && sudo -n cp /tmp/deploy-projects/*.conf /opt/deploy/projects/ \
  && sudo -n chown -R root:root /opt/deploy/bin /opt/deploy/projects \
  && sudo -n chmod 755 /opt/deploy/projects \
  && sudo -n chown -R ubuntu:ubuntu /opt/deploy/state /opt/deploy/logs /opt/deploy/tmp /opt/deploy/backups \
  && echo 已安装 $(ls /opt/deploy/projects/*.conf | wc -l) 个项目配置'

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
