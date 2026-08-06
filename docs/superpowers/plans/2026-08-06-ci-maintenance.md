# CI 依赖维护与代码检查实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 增加每周依赖更新和针对 Shell、GitHub Actions、Compose、Docker 镜像的持续检查。

**架构：** Dependabot 分别跟踪 Docker 与 GitHub Actions 依赖。代码检查工作流将静态检查、行为测试和镜像构建拆成三个 job，避免任何发布权限或 Secret。

**技术栈：** GitHub Actions、Dependabot、ShellCheck、actionlint、Docker、Docker Compose

---

## 文件结构

- 创建 `.github/dependabot.yml`：声明 Docker 与 GitHub Actions 每周更新。
- 创建 `.github/workflows/code-check.yml`：运行 lint、测试和构建验证。

### 任务 1：配置 Dependabot

**文件：**

- 创建：`.github/dependabot.yml`

- [ ] **步骤 1：添加依赖生态配置**

声明 `version: 2`，为根目录配置 `docker` 和 `github-actions` 两个 ecosystem，更新周期均为 `weekly`。

- [ ] **步骤 2：验证配置结构**

运行 actionlint 以外的 YAML 解析检查，并确认两个 ecosystem 均存在且目录均为 `/`。

### 任务 2：增加代码检查工作流

**文件：**

- 创建：`.github/workflows/code-check.yml`

- [ ] **步骤 1：添加触发器和最小权限**

工作流在手动触发、`master` push 和 `master` pull request 时运行，只声明 `contents: read`。

- [ ] **步骤 2：添加 Lint job**

检出代码后运行 ShellCheck。下载 actionlint `v1.7.7` 的 Linux amd64 归档，以固定 SHA-256 校验后解包并执行。

- [ ] **步骤 3：添加 Test job**

运行两个现有 Shell 测试脚本，保留各自的测试输出和退出状态。

- [ ] **步骤 4：添加 Build job**

运行官方下载脚本准备构建上下文，构建本机架构镜像，并以测试 UUID 执行 `docker compose config --quiet`。

### 任务 3：完整验证

**文件：**

- 检查：`.github/dependabot.yml`
- 检查：`.github/workflows/code-check.yml`
- 回归：`tests/download-agent.test.sh`
- 回归：`tests/docker-entrypoint.test.sh`

- [ ] **步骤 1：运行 actionlint 和 YAML 结构断言**

预期无 actionlint 诊断，Dependabot 包含且仅包含本仓库需要的两个 ecosystem。

- [ ] **步骤 2：运行 Shell 测试与 Compose 解析**

预期两个测试脚本全部通过，Compose 在提供 `DEVICE_UUID` 时可成功解析。

- [ ] **步骤 3：实际构建镜像**

使用现有 `agent-downloads` 构建 `itdog-agent:ci`，预期 Docker 构建退出码为 0。

- [ ] **步骤 4：检查最终差异**

运行 `git diff --check` 并确认 `check-update.yml` 未发生变化。
