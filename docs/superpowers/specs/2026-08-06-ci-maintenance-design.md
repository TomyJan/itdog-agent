# CI 依赖维护与代码检查设计

## 目标

参考 `MoeURL/.github` 的组织方式，为本仓库增加 Dependabot 和代码检查，同时只保留适合 Shell 与 Docker 项目的检查项。

## 依赖更新

`.github/dependabot.yml` 每周检查两类依赖：

- Dockerfile 中的基础镜像。
- `.github/workflows` 中引用的 GitHub Actions。

本仓库没有 npm 或 Go 模块，因此不复制参考仓库中对应的 ecosystem 配置。GitHub Actions 继续固定到完整 commit SHA，Dependabot 负责提交后续更新。

## 代码检查

`.github/workflows/code-check.yml` 支持手动触发，并在 `master` 分支 push 和 pull request 时运行。工作流只申请 `contents: read` 权限，检出代码时不持久化 GitHub 凭据。

检查拆分为三个独立 job：

1. `Lint` 使用 ShellCheck 检查仓库 Shell 脚本，并使用固定版本和 SHA-256 校验后的 actionlint 检查所有 GitHub Actions 工作流。
2. `Test` 运行 `tests/download-agent.test.sh` 和 `tests/docker-entrypoint.test.sh`。
3. `Build` 下载官方双架构 agent，在 runner 原生 `amd64` 平台实际构建镜像，并使用测试 UUID 解析 Compose 配置。

三个 job 独立执行，使 lint、行为测试和镜像构建的失败原因可以直接定位。构建 job 不登录 registry、不推送镜像，也不接触 Docker Hub Secrets。

## 验证

本地验收包括 actionlint、现有 Shell 测试、Compose 解析、Docker 构建以及 `git diff --check`。`check-update.yml` 保持现有 reusable workflow 调用方式不变。
