#!/usr/bin/env bash
# 把部署器与项目配置安装到服务器 /opt/deploy（幂等，可反复执行）
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-hxym}"

echo "==> 传输"
rsync -az scripts/deploy.sh "$HOST":/tmp/deploy.sh
rsync -az projects/ "$HOST":/tmp/deploy-projects/

echo "==> 安装"
ssh "$HOST" 'sudo -n mkdir -p /opt/deploy/bin /opt/deploy/projects /opt/deploy/state /opt/deploy/logs /opt/deploy/tmp \
  && sudo -n install -m 755 /tmp/deploy.sh /opt/deploy/bin/deploy.sh \
  && sudo -n cp /tmp/deploy-projects/*.conf /opt/deploy/projects/ \
  && sudo -n chown -R ubuntu:ubuntu /opt/deploy \
  && echo 已安装 $(ls /opt/deploy/projects/*.conf | wc -l) 个项目配置'

echo "==> 自检"
ssh "$HOST" 'sudo -n /opt/deploy/bin/deploy.sh list'
