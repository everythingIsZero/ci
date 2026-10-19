# ci — 共享构建门禁

**本仓只做一件事：跨项目的构建门禁（typecheck / lint / test）。它不部署任何东西。**

> 2026-10-19：原来的自研部署器（ssh → `/opt/deploy/bin/deploy.sh`）整体退役。
> 退役原因、旧实现的原文、以及「哪些实测结论仍然有效」，见
> `Projects/.archive-ci-deployer-20261019/README.md` 与工作区 `knowledge/deployment.md`。
> **不要往本仓加回部署逻辑。** 加回来就等于重建刚拆掉的那套东西。

## 现在怎么发布

发布走平台原语，不走脚本：工作区 `knowledge/new-project.md`（新项目接入 10 步）与
`knowledge/migrate-to-swarm.md`（Swarm 迁移与验收）。

## 结构

```
.github/workflows/ci.yml       可复用：安装 → 门禁 → 可选构建镜像（只验 Dockerfile 能构建）
.github/workflows/deploy.yml   已停用：被调用即报错并说明原因，不做任何事
```

## 接入一个项目（只要门禁）

在项目仓加一个 25 行的 workflow：

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: everythingIsZero/ci/.github/workflows/ci.yml@main
    with:
      project: <项目名>
      gate_cmd: pnpm typecheck && pnpm test
      # 仓里 package.json 已声明 packageManager 时，pnpm_version 必须留空，
      # 两处都指定会报 Multiple versions of pnpm specified（zbh 接入时踩过）
      pnpm_version: ""
    secrets: inherit
```

要点：

- **本仓必须 public** —— 私有仓的 reusable workflow 只能被同组织调用，个人账号会 `workflow was not found`。
- `concurrency` 放在 job 级：workflow 级 `cancel-in-progress` 会在新 push 时取消正在跑的 run。
- `permissions: contents: read`：门禁 job 不需要写权限，默认权限会让 postinstall 拿到可推仓的 token。
- `push_image` 与 `REGISTRY_*` 输入是旧路线（私有 registry）的遗留，**已无 registry 可用，不要打开**。
