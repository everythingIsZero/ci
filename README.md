# ci — 共享 CI/CD 流水线

跨项目的部署自动化：**构建在云端，切换在服务器，两者彻底分开**。

## 为什么这样设计

生产服务器 2C4G（可用内存约 1.8G）。原来的做法是在生产机上 `docker compose up -d --build`，带来两个后果：

1. 构建与线上抢内存；
2. `up -d --build` 把「构建」和「替换」绑成一步 —— 构建成功就替换，新容器起不来就是 502。

本仓把这两件事拆开：镜像在 GitHub Actions 构建（失败不碰线上），服务器只做「自检 → 切换 → 验收 → 回滚」。

## 结构

```
.github/workflows/ci.yml      可复用：安装 → 门禁 → 构建镜像 → 导出
.github/workflows/deploy.yml  可复用：传镜像 → 调服务器部署器
scripts/deploy.sh             服务器侧唯一入口（deploy/rollback/status/verify/selfcheck）
scripts/install.sh            把部署器与配置装到 /opt/deploy
projects/<项目>.conf          每个项目的部署参数
```

## 接入一个新项目

1. 在本仓 `projects/` 加一个 `<项目>.conf`（照 nuantie.conf 或 home.conf 抄）
2. 项目仓加 `.github/workflows/deploy.yml`（约 20 行，见下方模板）
3. 项目仓 Settings → Secrets 配 `DEPLOY_SSH_KEY` / `DEPLOY_SSH_HOST` / `DEPLOY_SSH_USER`
4. 本地执行 `bash scripts/install.sh` 同步部署器
5. 先 `deploy.sh deploy <项目> --dry-run` 验证，再手动触发一次真实部署

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
    secrets: inherit
```

## 两种部署形态（部署器自动适配）

| 形态 | 目录结构 | 切换方式 |
|---|---|---|
| `self-compose` | `/opt/<项目>/app` + `compose.yml` | `compose -f app/compose.yml --project-directory . up -d --no-build` |
| `central-stack` | `/opt/<项目>/releases/<date>` + 集中 `docker-compose.yml` | `compose -f 集中栈 up -d --no-build <service>` |

两者都靠**重新打 tag** 切换（`<新镜像> → compose 里那个镜像名`），**不改任何 compose 文件**，因此不会影响同栈的其他服务。

## 部署器命令

```sh
deploy.sh list                          # 已接入项目
deploy.sh status <项目>                 # 当前镜像 / 上次结果 / 回滚点
deploy.sh verify <项目>                 # 只跑验收，不动容器
deploy.sh selfcheck <项目> [镜像]       # 只跑旁路自检
deploy.sh deploy <项目> --sha <sha>     # 完整部署
deploy.sh deploy <项目> --dry-run       # 演练，不改容器
deploy.sh rollback <项目>               # 手动回滚
```

## 边界（必须知道）

- **密钥始终只在服务器 `.env`**，CI 只拿一把部署 SSH 私钥。
- **CI 的镜像冒烟只验结构**（镜像能执行），真正的启动验证在服务器旁路自检（那里才有生产 env）。
- **验收 L3 行为层未自动化**：目前只到 HTTP 状态 + 压缩/缓存头。真浏览器链路仍需单独跑 e2e。
- `central-stack` 形态依赖集中栈 compose 的服务名稳定，改服务名要同步改 conf。
