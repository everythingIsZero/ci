# 项目接入矩阵

接入 CI/CD 的逐项目清单。**接入前先看本项目的「特别注意」**，那里是最容易踩的坑。

图例：✅ 已验证跑通 · 🔄 接入中 · ⬜ 待接入 · ⛔ 不建议自动部署

## A 类：有生产容器（需要 CD）

| 项目 | 形态 | SOURCE_DIR | SERVICE | 域名 | 状态 |
|---|---|---|---|---|---|
| nuantie | self-compose | `/opt/nuantie/app` | `nuantie` | nt.hxym18.com | ✅ |
| home | central-stack | `/opt/home/releases/20261005` | `home` | www.hxym18.com | ✅ |
| schulte-v2 | self-compose | `/opt/schulte/app` | `schulte-v2` | schulte.hxym18.com | ✅ |
| card | self-compose | `/opt/card/app` | `card` | ka.hxym18.com | ⬜ |
| share-bridge | self-compose | `/opt/share-bridge/app` | `share-bridge` | share.hxym18.com | ⬜ |
| zbh | central-stack | `/opt/trae-projects/apps/zbh` | `zbh` | gldcd.hxym18.com | ⬜ |
| fang | central-stack | `/opt/fang/releases/umami-gate-20261008` | `fang` | fang.hxym18.com | ⬜ |
| zitie | central-stack | `/opt/zitie/releases/20261008` | `copybook` | wj.hxym18.com | ⬜ |
| wordinput | central-stack | `/opt/wordinput/releases/20260930` | `wordinput` | yq.hxym18.com | ⬜ |
| sso-bridge | 特殊（compose 在根） | `/opt/sso-bridge` | `sso-unified-next` | auth / bridge / id | ⛔ |

## B 类：共享包（只要 CI，不部署）

`env` · `auth` · `analytics` · `share-kit` · `pwa-kit` · `cli`

这些的「上线」= 打 tag 被别的项目 `github:owner/repo#vX.Y.Z` 引用。接入只需 CI 门禁：

```yaml
jobs:
  ci:
    uses: everythingIsZero/ci/.github/workflows/ci.yml@main
    with:
      project: env
      push_image: false
    secrets: inherit
```

不需要 `deploy` job，也不需要 conf。

## C 类：非部署对象

- `hmd2`：小程序端 + server，未上线。上线后再按 A 类接。
- `docs`：文档仓，无部署。

---

## 逐项目特别注意

### card
- 生产容器名 `card`，镜像 `card:local`，compose 在 `/opt/card/app/compose.yml`
- 容器内 nginx 监听 80，Caddy 反代 `card:80`
- ⚠️ 现状「生产容器仍由旧栈构建」（INDEX 记录），接入前先确认 `/opt/card/app` 是当前生产代码

### share-bridge
- 镜像 `share-bridge:local`，端口 8200，有数据卷 `/opt/share-bridge/data`
- ⚠️ 源码仓刚建 GitHub 私有仓（`everythingIsZero/share-bridge`），**代码尚未推送**

### zbh
- 集中栈服务名 `zbh`，容器 `deploy-zbh-1`，镜像自动名 `deploy-zbh:latest`
- ⚠️ `pnpm-lock.yaml` 里曾出现 `git+ssh://` 形式的 GitHub 依赖导致构建失败（已修）；接入后每次构建都会复现该检查
- 有 `lint` 脚本，`gate_cmd` 建议 `pnpm lint && pnpm test`

### fang
- 集中栈服务名 `fang`，容器 `deploy-fang-1`
- SQLite + 照片资产卷在 `/opt/trae-projects/deploy/data/fang`，**不在 SOURCE_DIR**，rsync 不会碰
- env 来自 `deploy/.env` 的变量插值（不是 env_file），自检时 `ENV_FILE=/opt/trae-projects/deploy/.env`

### zitie
- 集中栈服务名是 **`copybook`**（不是 zitie），容器 `deploy-copybook-1`
- ⚠️ `poetry.db` 2.2G，只读挂载自 `deploy/data/copybook/`，**绝不能进 SOURCE_DIR**（rsync --delete 会删）
- 源码仓 6.3G 工作目录，同步时靠 `--exclude` 排除大数据文件

### wordinput
- 集中栈服务名 `wordinput`，容器 `deploy-wordinput-1`
- ⚠️ 源码仓 1.2G 工作目录，同上

### sso-bridge
- compose 在 `/opt/sso-bridge/compose.yml`（不在 `app/` 子目录），形态与其他项目不同
- ⚠️ 同栈含 Casdoor（登录服务），部署会影响全站登录。**必须人工审查 + 单独窗口**，不要接自动部署
- 若将来接入，`MODE` 需要新增一种适配（compose 在根目录），当前部署器不支持

### schulte-v2
- 分支是 `feat/v2-production`（不是 main），workflow 两个分支都监听
- 依赖装在 `apps/client`，`install_cmd` 必须指定 `pnpm -C apps/client install --frozen-lockfile`
- 旧容器 `schulte`（`schulte:local`）仍在跑，退役前不要动
- 构建含「缓存安全门」：产物不带内容 hash 会直接构建失败
- 源码 16MB，其中设计稿/参考图/报告占 12MB —— `EXCLUDE_PATHS` 排除后只剩 3.3MB

---

## 产物契约基线（2026-10-19 实测）

压缩与缓存问题反复出现的根因不是「谁忘了配」，而是**验收只探一个资源、只打公网域名、缺头只 warn**。
现在判据写死在 `scripts/audit-assets.sh` 与 `deploy.sh verify` 里，逐条判红绿。

| 域名 | 项目 | 入口压缩 | 资源压缩 | 入口缓存 | 资源缓存 | 结论 |
|---|---|---|---|---|---|---|
| www.hxym18.com | home | ✓ | ✓ | `no-cache` | `immutable` | 绿（enforce） |
| schulte.hxym18.com | schulte-v2 | ✓ | ✓ | `no-store` | `immutable` | 绿（enforce） |
| ka.hxym18.com | card | ✓（10-19 修） | ✓（10-19 修） | `no-cache` | `immutable` | 绿 |
| nt.hxym18.com | nuantie | ✓ | ✓ | **无** | **无** | 红 ×4（warn） |
| gldcd.hxym18.com | zbh | ✓ | ✓ | `no-store` | 短缓存 | 红 ×1（og 图长缓存） |
| wj.hxym18.com | zitie | ✓ | ✓ | 只有 s-maxage | `immutable` | 黄 |
| yq.hxym18.com | wordinput | ✓ | ✓ | 只有 s-maxage | `immutable` | 黄 |
| fang.hxym18.com | fang | ✓ | — | 只有 s-maxage | — | 黄 ×3 |
| share.hxym18.com | share-bridge | — | — | **无** | — | 302，需人工确认 |

**判据（写死在脚本里，不靠人记）**

1. 入口页必须有 `cache-control`；`max-age > 300` 判红（发版后老用户拿旧 HTML）
2. 文本类资源 > 1KB 必须压缩
3. 带内容 hash 的产物 → 必须 `immutable` 或 `max-age ≥ 30 天`
4. **不带 hash** 的产物 → 必须 `no-cache` 或 `max-age ≤ 1h`（长缓存会让用户拿到旧文件）
5. 容器直连 vs 公网做**归属比对**：容器压缩、公网不压缩 = 边缘层把它吃了

**接入前置条件**：新项目接入前先跑 `bash scripts/audit-assets.sh <域名>` 到「契约满足」，再在 conf 里设 `ASSET_CONTRACT=enforce`。
存量项目先设 `warn`（只报告），修干净再改 `enforce` —— 否则一次部署会因为历史遗留的头直接回滚。

## 接入步骤（照抄）

1. 在 `Projects/ci/projects/<项目>.conf` 新建配置，字段含义：

```sh
PROJECT=xxx                    # 与 conf 文件名一致
MODE=self-compose|central-stack
COMPOSE_FILE=...               # self-compose 才有
COMPOSE_PROJECT_DIR=...        # self-compose 才有
STACK_FILE=...                 # central-stack 才有
SERVICE=...                    # compose 里的服务名
CONTAINER=...                  # docker ps 里的容器名
IMAGE_LOCAL=...                # compose 里 image 字段（central-stack 为 deploy-<svc>:latest）
ENV_FILE=...                   # 服务器 .env 绝对路径；无则留空
SOURCE_DIR=...                 # 源码同步目标，清空重解压的作用范围
EXCLUDE_PATHS="docs deliverables reference"   # 非运行时目录，打包时就排除
PORT=...                       # 容器内端口（旁路自检用）
HEALTH_PATH=/healthz 或 /
DOMAIN=...
CHECK_COMPRESS=1               # 静态资源站点必开
ASSET_CONTRACT=warn|enforce    # 产物契约：warn 只报告 · enforce 不满足即失败（会回滚）
BUILD_ENV_REQUIRED="..."       # compose.yml 的 build.args 依赖的变量名（空格分隔）
                               # 缺了不会报错，只会静默构建出缺配置的镜像 → 这里变硬失败
DB_PATH=...                    # 有本地数据库时填，部署前会 cp 快照
VERSION_PATH=/api/version      # 可选：项目能报版本时填，验收会比对提交号
```

**`BUILD_ENV_REQUIRED` 怎么定**：打开项目 `compose.yml` 的 `build.args`，凡是写成 `"${XXX}"` 的（不是字面量），把 `XXX` 填进来。值从 `COMPOSE_PROJECT_DIR/.env` 读（`BUILD_ENV_FILE` 可覆盖）。确实不需要就删掉这一行。

2. 项目仓加 `.github/workflows/deploy.yml`（照 nuantie 抄）
3. 项目仓配 3 个 secrets：`DEPLOY_SSH_KEY` / `DEPLOY_SSH_HOST` / `DEPLOY_SSH_USER`
4. 本地 `bash scripts/install.sh`
5. `deploy.sh deploy <项目> --dry-run` 演练
6. 手动触发一次真实部署，看 `deploy.sh status <项目>`

## 接入顺序建议

先接**静态站/无状态**的（card、share-bridge），再接受**有数据卷**的（fang、zitie），最后才是 sso-bridge。
每接一个跑一次「空发布」（代码不变，验证流程），确认无异常再接下一个。
