# 新项目接入体检表（按缺陷类别穷举）

> **为什么按类别而不是按项目**：按项目查只能覆盖「上次踩过的坑」，新项目的问题一定在别处。
> 这张表按**缺陷类别**穷举，每类给出判据与验证方式；接入时逐类过一遍，不依赖记忆。
>
> 用法：新项目接入前跑一遍，红项必须先修或明确接受（写进 conf 注释）。
> 能自动化的已在 `scripts/audit-assets.sh` 与 `deploy.sh verify` 里，其余是人工命令。

## 1. 可达性与入口

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| DNS / 证书 | `curl -sI https://<域名>/` | 200，证书未过期 |
| 重定向链 | `curl -sIL https://<域名>/ \| grep -i location` | 不超过 1 跳；302 到登录页要确认是设计而非错误 |
| SPA 回退 | `curl -s -o /dev/null -w '%{http_code}' https://<域名>/__nonexist` | SPA=200，MPA=404；返回 200 但内容是错误页 = 吞错误 |
| 健康路径 | 容器直连 `http://<ip>:<port><HEALTH_PATH>` | 200；**不能只验公网**（Caddy 可能指向旧容器） |
| 健康检查定义 | `docker inspect -f '{{json .Config.Healthcheck}}' <容器>` | 有 HEALTHCHECK 才能用 `wait_ready` 的 healthy 分支；没有则靠 curl 探活 |

## 2. 产物层（压缩 / 缓存 / 指纹）

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| 压缩 | `bash scripts/audit-assets.sh <域名>` | 文本资源 >1KB 必须有 `content-encoding` |
| **压缩归属** | 同上 `--container ip:port`（**在服务器上跑**） | 容器压缩、公网不压缩 = 边缘层问题；反之 = 容器没开 |
| 缓存策略 | 同上 | 带 hash → `immutable`；不带 hash → `no-cache`/≤1h；入口页 → `no-cache` 或 `max-age≤300` |
| 指纹 | 看构建产物文件名 | 无 hash 的产物无法长缓存，等于每次重下（性能债，记进 backlog） |
| MIME | `curl -sI <资源> \| grep -i content-type` | `.js` 不能是 `text/plain`（会触发 nosniff 拦截） |
| Source Map | `curl -s -o /dev/null -w '%{http_code}' https://<域名>/<产物>.map` | 生产不应 200（泄露源码） |

## 3. 运行时依赖

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| 运行期 env | 容器内 `env \| grep -c .`；对照项目 README | 缺了不会崩但要确认默认值可用 |
| **构建期 env** | 看 `compose.yml` 的 `build.args` 里 `${XXX}` 的项 | 全部写进 conf 的 `BUILD_ENV_REQUIRED`（缺了会静默构建坏镜像） |
| 数据卷 | `docker inspect -f '{{json .Mounts}}' <容器>` | 卷路径不在 `SOURCE_DIR` 内（同步会删） |
| 时区 | `docker exec <c> date` | 业务依赖日期时必须 `TZ=Asia/Shanghai` |
| 静态目录 | 容器内 `ls` 确认实际路径 | 与 `HEALTH_PATH` / `PORT` 一致 |

## 4. 网络与代理

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| 反代指向 | Caddyfile 里该 vhost 的 `reverse_proxy` | 指向**服务名**而非 IP（IP 会随容器重建变化） |
| `encode` | 该 vhost 有没有 `encode zstd gzip` | **必须有**：缺了会把上游压缩吃掉（2026-10-19 card 实测） |
| 网络归属 | `docker inspect -f '{{json .NetworkSettings.Networks}}' <c>` | 与 Caddy 同网；不该与无关生产库同网（横向移动） |
| 端口冲突 | `ss -ltnp \| grep <port>` | 宿主端口不冲突；容器内端口与 conf `PORT` 一致 |
| WebSocket/SSE | 有长连接的项目 | Caddy 默认支持，但要确认没被缓冲（`flush_interval -1`） |

## 5. 数据

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| DB 路径 | conf 的 `DB_PATH` | 必须在 `SOURCE_DIR` 外；有值才做快照 |
| 备份可用性 | 恢复演练：拿快照起一个临时容器查数据 | **没演练过的备份等于没有**（当前所有项目都未演练） |
| 迁移 | 项目是否有启动时自动迁移 | 有迁移就要确认回滚时迁移是否可逆 |
| 写权限 | 容器内 `touch` 数据目录 | 非 root 运行时要能写 |

## 6. 权限

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| 容器用户 | `docker inspect -f '{{.Config.User}}' <c>` | 空 = root 运行；能降则降 |
| 文件属主 | `ls -l /opt/<项目>` | 密钥 `.env` 600；代码目录不归持钥用户所有 |
| sudo 面 | `sudo -n -l` | CI 用的账号不该 `NOPASSWD: ALL`（当前是，属已知风险） |

## 7. 资源

| 查什么 | 怎么验 | 判据 |
|---|---|---|
| 内存限制 | `docker inspect -f '{{json .HostConfig.Memory}}'` | 0 = 无限制，构建峰值可能打爆宿主（nuantie 峰值 1.5G/3.7G） |
| 磁盘 | `df -h /` | <15% 剩余就该清理 |
| 日志轮转 | 容器 `--log-opt max-size` | 未设 = 日志无限增长（当前多数未设） |

## 8. 部署契约（conf 字段）

| 查什么 | 判据 |
|---|---|
| `SOURCE_DIR` | 必须 `/opt/<项目>/<子目录>`；**不能等于项目根**（会删掉 .env/compose） |
| `CONTAINER` | 必须与 `docker ps` 里的名字**完全一致**（`central-stack` 是 `deploy-<svc>-1`） |
| `IMAGE_LOCAL` | `self-compose` = compose 里的 `image:`；`central-stack` = `deploy-<svc>:latest` |
| `EXCLUDE_PATHS` | 设计稿/报告/参考图必须排除（跨境上行 ~30KB/s） |
| `COMPOSE_FILE` | `self-compose` 才有；`central-stack` 用 `STACK_FILE` |

## 9. 可观测

| 查什么 | 判据 |
|---|---|
| 部署结果可查 | `deploy.sh status` 显示线上提交（镜像标签，不是 state 自述） |
| 失败留痕 | 任何退出路径都写 `LAST_RESULT`（已加 EXIT trap） |
| 日志 | `/opt/deploy/logs/` 按项目分文件；**无轮转**，靠每日 cleanup |
| 告警 | 目前只有 Actions 红叉，无推送（已知缺口） |

## 10. 安全

| 查什么 | 判据 |
|---|---|
| 安全头 | Caddy `import security_headers`（HSTS/nosniff/frame/referrer，去 Server 头） |
| 版本泄露 | 响应头无 `Server: nginx/x.y` |
| 默认口令 | 管理面板/数据库不得用默认密码 |
| 对外端口 | 除 80/443 外不对公网暴露（`ss -ltnp` 核对） |

---

## 接入时的顺序

1. 先跑 `audit-assets.sh` 到「契约满足」，conf 设 `ASSET_CONTRACT=enforce`
2. 过一遍第 1/3/4/8 类（入口、依赖、网络、conf 字段）——这四类错了会直接部署失败或删数据
3. 第 5/6/7 类（数据、权限、资源）有问题的先记进 conf 注释，不阻断接入
4. 第 9/10 类作为长期项
