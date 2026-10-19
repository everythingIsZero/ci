# ci — 共享 CI/CD 流水线

跨项目的部署自动化：**门禁在云端，构建与切换在服务器，每一步都留退路**。

## 为什么是「源码同步 + 服务器构建」，而不是传镜像

最初设计是「GitHub Actions 构建镜像 → 传到服务器 → 切换」。实测直接否掉了这条路：

| 链路 | 实测速度 | 442MB 镜像耗时 |
|---|---|---|
| GitHub → 服务器（push） | ~100 KB/s | ~70 分钟 |
| 服务器 → GitHub（pull） | ~21 KB/s | 更慢 |

跨境传输是硬瓶颈，registry 增量也救不了首次全量。

改为只传源码（`git archive` 等价物，只含 git 跟踪文件）：

| 项目 | 源码体积 | 同步耗时 |
|---|---|---|
| home | 0.3 MB | 4 秒 |
| nuantie | 24 MB | 十几秒 |

构建留在服务器，靠 Docker 层缓存复用：**源码没变时构建 0.7 秒**。

真正的风险不是「在哪构建」，而是「构建成功就替换」——本仓用**先构建、再旁路自检、最后原子切换**解决，构建失败线上不受任何影响。

## 结构

```
.github/workflows/ci.yml      可复用：安装 → 门禁 → 构建镜像（验证 Dockerfile）
.github/workflows/deploy.yml  可复用：打包源码 → 交给服务器部署器（stdin）
scripts/deploy.sh             服务器侧唯一入口
scripts/install.sh            把部署器与配置装到 /opt/deploy，并装每日清理任务
projects/<项目>.conf          每个项目的部署参数（不进公开仓）
```

## 部署器做的事

```
备份（镜像 tag + compose + DB）→ 同步源码 → 构建（失败即停，线上不动）
→ 旁路自检（临时容器，真 env）→ 原子切换（重打 tag，不改 compose）
→ 等待就绪 → 三层验收 → 失败自动回滚
```

**顺序是刻意的**：

- **备份早于同步**：`compose.yml` 就在 `SOURCE_DIR` 里，同步之后再备份拿到的是新配置，回滚还原它等于用新配置再启一次。
- **同步在锁内**：源码从 CI 经 stdin 进部署器，和构建、切换共用一把 `flock`。拆成两条 ssh 的话，两个部署能交叉写同一个 `SOURCE_DIR`（A 同步 → B 同步 → A 构建的是 B 的源码）。
- **同步先落盘再校验**：tar 先写临时文件、`tar tf` 验证通过才清空目标目录，半截的流不会把线上源码清空。

- **旁路自检**：用生产 env 起一个临时容器（不映射端口、不挂生产卷），验 `/healthz`。新容器起不来会在这里被拦下，而不是等切换后 502。
- **等待就绪**：切换后轮询容器健康状态，最多 45 秒。少了这一步，验收会在容器还没起来时误判失败。
- **原子切换**：只把新镜像打成 compose 认识的名字，**不改任何 compose 文件**，因此不会影响同栈其他服务。
- **三层验收**：L1 基础可用（容器直连 + 公网 + 运行镜像身份）· L2 产物层（压缩 / 缓存头 / 可选指纹）· L3 行为层（未自动化，见边界）。
  - L1 先直连容器 IP：只打公网域名的话，Caddy 还指着旧容器时会验出假绿。
  - 再比对「运行中的容器镜像 = `IMAGE_LOCAL`」：容器没切过来，验收必须红。
- **提交号钉在镜像上**：部署成功时打 `IMAGE_LOCAL:sha-<7位>` 标签，`status` 从**运行容器的镜像标签**读线上提交，而不是信 state 里的自述。

## 接入一个新项目

**逐项目清单见 [`docs/projects.md`](docs/projects.md)**（形态、SOURCE_DIR、服务名、每个项目的特别注意）。通用步骤：

1. 本仓 `projects/` 加 `<项目>.conf`（照 nuantie.conf 或 home.conf 抄）
2. 项目仓加 `.github/workflows/deploy.yml`（约 25 行）
3. 项目仓配 secrets：`DEPLOY_SSH_KEY` / `DEPLOY_SSH_HOST` / `DEPLOY_SSH_USER`
4. 本地 `bash scripts/install.sh` 同步部署器
5. `deploy.sh deploy <项目> --dry-run` 验证，再手动触发一次真实部署

```yaml
name: deploy
on:
  push: { branches: [main] }
  workflow_dispatch:
jobs:
  ci:
    uses: everythingIsZero/ci/.github/workflows/ci.yml@main
    with:
      project: <项目>
      gate_cmd: pnpm typecheck && pnpm test
    secrets: inherit
  deploy:
    needs: ci
    if: github.event_name == 'workflow_dispatch'
    uses: everythingIsZero/ci/.github/workflows/deploy.yml@main
    with:
      project: <项目>
      sha: ${{ needs.ci.outputs.sha }}
    secrets: inherit
```

## 两种部署形态（部署器自动适配）

| 形态 | 目录结构 | 构建 / 切换 |
|---|---|---|
| `self-compose` | `/opt/<项目>/app` + `compose.yml` | `compose -f app/compose.yml --project-directory . build/up` |
| `central-stack` | `/opt/<项目>/releases/<目录>` + 集中 `docker-compose.yml` | `compose -f 集中栈 build/up <service>` |

## 部署器命令

```sh
deploy.sh list                          # 已接入项目
deploy.sh status <项目>                 # 当前镜像 / 线上提交 / 上次结果 / 回滚点
deploy.sh verify <项目>                 # 只跑验收，不动容器
deploy.sh selfcheck <项目> [镜像]       # 只跑旁路自检
deploy.sh where <项目>                  # 源码同步目标目录（带护栏）
deploy.sh deploy <项目> --build         # 构建 + 完整部署
deploy.sh deploy <项目> --build --tar -  # 源码从 stdin 进（CI 用这条，同步在锁内）
deploy.sh deploy <项目> --dry-run       # 演练，不改容器
deploy.sh rollback <项目>               # 手动回滚
deploy.sh cleanup                       # 清悬空镜像 + 7 天前的构建缓存（每日 04:00 自动跑）
```

## 边界（必须知道）

- **密钥始终只在服务器 `.env`**，CI 只拿一把部署 SSH 私钥。
- **CI 的镜像构建只验证 Dockerfile 可用**，不推送、不传输。caller 里写的 `build_args` 也只作用于这一次验证构建，**生产构建的参数来自 compose.yml 的 `build.args`**（值取自项目目录下的 `.env`）。
- **构建期变量缺失不会报错，只会静默产出缺配置的镜像**（统计 id 为空、地图 key 为空）。所以 conf 里用 `BUILD_ENV_REQUIRED` 把它变成硬失败；确实不需要就删掉那一行。
- **验收 L3 行为层未自动化**：只到 HTTP 状态 + 压缩/缓存头 + 镜像身份，真浏览器链路仍需单独跑 e2e。
- **服务器构建会占用生产内存**：nuantie 构建峰值约 1.5G / 3.7G，构建期间不要同时跑多个项目。
- **服务器构建要拉 npm 包**（~270 KB/s）：首次构建 home 这类 Next.js 项目要几分钟，层缓存命中后才是秒级。
- `central-stack` 形态依赖集中栈 compose 的服务名稳定，改服务名要同步改 conf。
- 保留 `push_image` 开关与私有 registry（`registry.hxym18.com`），跨境带宽改善后可切回镜像交付。
