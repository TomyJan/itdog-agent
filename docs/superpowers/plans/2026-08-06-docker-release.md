# ITDOG Agent Docker 自动发布实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 构建并自动发布 Docker Hub 上的 `linux/amd64`、`linux/arm64` ITDOG Agent 镜像，让用户只提供 `DEVICE_UUID` 即可通过 Docker Compose 运行节点。

**架构：** 下载脚本从官方归档提取并验证两个 ELF 二进制，Dockerfile 根据 `TARGETARCH` 复制对应文件。每日检查工作流比较成功发布缓存中的二进制 SHA-256，发现变化后把同一批文件作为 artifact 传给可复用 Docker 发布工作流，避免检查与构建之间下载到不同版本。

**技术栈：** POSIX Shell、Docker Buildx、Docker Compose、GitHub Actions、Docker Hub

---

## 文件结构

- 创建 `.gitignore`：忽略下载产物和本地缓存。
- 创建 `scripts/download-agent.sh`：下载、解包和验证官方双架构 agent。
- 创建 `tests/download-agent.test.sh`：使用本地 fixture 验证下载脚本的成功与失败行为。
- 创建 `docker-entrypoint.sh`：校验 UUID，并按二进制哈希和 UUID 同步 `node_id` 状态。
- 创建 `tests/docker-entrypoint.test.sh`：验证入口脚本的必填变量、状态保留和状态重置行为。
- 创建 `Dockerfile`：安装运行依赖并组装目标架构镜像。
- 创建 `.dockerignore`：限制构建上下文。
- 创建 `compose.yaml`：提供只需 UUID 的节点服务定义。
- 创建 `.github/workflows/docker.yml`：手动或复用触发的 Docker Hub 多架构发布。
- 创建 `.github/workflows/check-update.yml`：每日检查并按需调用发布工作流。
- 修改 `README.md`：说明使用方式、Secret、标签和自动发布规则。

### 任务 1：下载并校验官方二进制

**文件：**

- 创建：`tests/download-agent.test.sh`
- 创建：`scripts/download-agent.sh`
- 创建：`.gitignore`

- [ ] **步骤 1：编写成功下载和架构错误测试**

测试创建两个只含 `agent` 的 tar.gz fixture，并通过测试 PATH 中的 `curl`、`file` 替身驱动真实下载脚本：

```sh
run_download() {
  PATH="$fake_bin:$PATH" \
    ITDOG_AGENT_BASE_URL='https://fixtures.invalid' \
    sh "$repo_root/scripts/download-agent.sh" "$output_dir"
}

run_download
cmp "$fixtures/amd64/agent" "$output_dir/agent_amd64"
cmp "$fixtures/arm64/agent" "$output_dir/agent_arm64"

FILE_FORCE_WRONG_ARCH=1 run_download && fail '架构错误时应失败'
```

- [ ] **步骤 2：运行测试并确认红灯**

运行：

```bash
bash tests/download-agent.test.sh
```

预期：FAIL，原因是 `scripts/download-agent.sh` 尚不存在。

- [ ] **步骤 3：实现最小下载脚本**

脚本接口固定为一个输出目录参数，并为每个架构执行下载、解包、查找和 ELF 校验：

```sh
#!/bin/sh
set -eu

output_dir=${1:?用法: download-agent.sh OUTPUT_DIR}
base_url=${ITDOG_AGENT_BASE_URL:-https://dl.itdog.cn/agent}

for arch in amd64 arm64; do
  archive="$tmp_dir/agent_${arch}.tar.gz"
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "$base_url/agent_${arch}.tar.gz" --output "$archive"
  tar -xzf "$archive" -C "$extract_dir"
  agent=$(find "$extract_dir" -type f -name agent -print -quit)
  validate_architecture "$agent" "$arch"
  install -m 0755 "$agent" "$output_dir/agent_${arch}"
done
```

`validate_architecture` 必须要求 `file` 输出同时包含 `ELF 64-bit` 以及目标架构对应的 `x86-64` 或 `ARM aarch64`。

- [ ] **步骤 4：运行测试并确认绿灯**

运行：`bash tests/download-agent.test.sh`

预期：2 个测试通过，退出码为 0。

- [ ] **步骤 5：提交任务 1**

```bash
git add .gitignore scripts/download-agent.sh tests/download-agent.test.sh
git commit -m "feat(下载): 添加双架构 agent 获取与校验"
```

### 任务 2：实现容器入口与镜像

**文件：**

- 创建：`tests/docker-entrypoint.test.sh`
- 创建：`docker-entrypoint.sh`
- 创建：`Dockerfile`
- 创建：`.dockerignore`

- [ ] **步骤 1：编写入口脚本行为测试**

使用临时状态目录和临时哈希文件测试 4 个行为：

```sh
env -u DEVICE_UUID sh docker-entrypoint.sh true && fail '缺少 UUID 时应失败'

DEVICE_UUID=uuid-a ITDOG_AGENT_STATE_DIR="$state" \
  ITDOG_AGENT_SHA256_FILE="$hash_file" sh docker-entrypoint.sh true
test ! -e "$state/node_id"

printf old > "$state/node_id"
DEVICE_UUID=uuid-a ITDOG_AGENT_STATE_DIR="$state" \
  ITDOG_AGENT_SHA256_FILE="$hash_file" sh docker-entrypoint.sh true
test -e "$state/node_id"

DEVICE_UUID=uuid-b ITDOG_AGENT_STATE_DIR="$state" \
  ITDOG_AGENT_SHA256_FILE="$hash_file" sh docker-entrypoint.sh true
test ! -e "$state/node_id"
```

随后改变哈希文件内容，再验证 `node_id` 被删除。

- [ ] **步骤 2：运行入口测试并确认红灯**

运行：`bash tests/docker-entrypoint.test.sh`

预期：FAIL，原因是 `docker-entrypoint.sh` 尚不存在。

- [ ] **步骤 3：实现最小入口脚本**

入口脚本读取构建时生成的 agent SHA-256，并将哈希与 UUID 写入状态标记：

```sh
state_dir=${ITDOG_AGENT_STATE_DIR:-/opt/itdog-agent}
sha_file=${ITDOG_AGENT_SHA256_FILE:-/usr/local/share/itdog-agent.sha256}
marker="$state_dir/.agent-identity"
identity="$(cat "$sha_file"):$DEVICE_UUID"

if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$identity" ]; then
  rm -f "$state_dir/node_id"
  printf '%s\n' "$identity" > "$marker.tmp"
  mv "$marker.tmp" "$marker"
fi

exec "$@"
```

脚本必须先检查 `DEVICE_UUID` 非空、状态目录可创建、SHA 文件可读。

- [ ] **步骤 4：运行入口测试并确认绿灯**

运行：`bash tests/docker-entrypoint.test.sh`

预期：5 个测试通过，退出码为 0。

- [ ] **步骤 5：创建 Dockerfile 与构建上下文规则**

Dockerfile 使用 Debian 12 slim，并把 agent 放在卷外：

```dockerfile
FROM debian:bookworm-slim
ARG TARGETARCH
ARG VERSION=dev
ARG SOURCE_REVISION=unknown
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates tini zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 agent-downloads/agent_${TARGETARCH} /usr/local/bin/itdog-agent
RUN sha256sum /usr/local/bin/itdog-agent | cut -d ' ' -f 1 > /usr/local/share/itdog-agent.sha256
WORKDIR /opt/itdog-agent
VOLUME ["/opt/itdog-agent"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/itdog-agent"]
```

- [ ] **步骤 6：运行脚本回归测试和 Dockerfile 静态检查**

运行：

```bash
bash tests/download-agent.test.sh
bash tests/docker-entrypoint.test.sh
git diff --check
```

预期：所有测试通过，`git diff --check` 无输出。

- [ ] **步骤 7：提交任务 2**

```bash
git add Dockerfile .dockerignore docker-entrypoint.sh tests/docker-entrypoint.test.sh
git commit -m "feat(镜像): 添加 agent 容器运行环境"
```

### 任务 3：提供 Compose 与使用文档

**文件：**

- 创建：`compose.yaml`
- 修改：`README.md`

- [ ] **步骤 1：创建 Compose 配置**

```yaml
services:
  itdog-agent:
    image: tomyjan/itdog-agent:latest
    environment:
      DEVICE_UUID: ${DEVICE_UUID:?请设置 DEVICE_UUID}
    cap_add:
      - NET_RAW
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - itdog-agent-data:/opt/itdog-agent
    restart: unless-stopped

volumes:
  itdog-agent-data:
```

- [ ] **步骤 2：使用 Compose 解析器验证结构**

运行：

```powershell
$env:DEVICE_UUID='00000000-0000-0000-0000-000000000000'
docker compose -f compose.yaml config --format json | ConvertFrom-Json | Out-Null
```

预期：退出码为 0；未设置 `DEVICE_UUID` 时解析失败。

- [ ] **步骤 3：重写 README**

README 必须包含：Docker Hub 镜像、POSIX Shell 与 PowerShell 启动命令、查看日志/停止/升级命令、支持架构、状态卷、`NET_RAW` 原因、Docker Hub Secret 配置、手动版本默认值和每日检查时间。

- [ ] **步骤 4：提交任务 3**

```bash
git add compose.yaml README.md
git commit -m "docs(使用): 添加 Compose 与发布配置说明"
```

### 任务 4：实现自动检查和多架构发布工作流

**文件：**

- 创建：`.github/workflows/docker.yml`
- 创建：`.github/workflows/check-update.yml`

- [ ] **步骤 1：创建可复用 Docker 发布工作流**

触发器必须同时声明：

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        required: false
        type: string
  workflow_call:
    inputs:
      version:
        required: false
        type: string
      agent_artifact:
        required: false
        type: string
      amd64_sha256:
        required: false
        type: string
      arm64_sha256:
        required: false
        type: string
    secrets:
      DOCKERHUB_USERNAME:
        required: true
      DOCKERHUB_TOKEN:
        required: true
```

作业中必须完成输入版本校验、artifact/官方下载二选一、预期哈希校验、Docker Hub 登录、QEMU/Buildx 初始化，以及 `linux/amd64,linux/arm64` 构建推送。版本为空时通过 `TZ=Asia/Singapore date +%Y%m%d` 计算。

- [ ] **步骤 2：创建每日更新检查工作流**

```yaml
on:
  schedule:
    - cron: '0 16 * * *'
  workflow_dispatch:
```

检查作业恢复 `itdog-agent-v1-` 前缀下最近的缓存，运行下载脚本并比较两个二进制 SHA-256。变化时上传短期 artifact，并由后续作业调用：

```yaml
publish:
  needs: check
  if: needs.check.outputs.changed == 'true'
  uses: ./.github/workflows/docker.yml
  with:
    agent_artifact: ${{ needs.check.outputs.artifact_name }}
    amd64_sha256: ${{ needs.check.outputs.amd64_sha256 }}
    arm64_sha256: ${{ needs.check.outputs.arm64_sha256 }}
  secrets: inherit
```

- [ ] **步骤 3：运行 GitHub Actions 结构校验**

运行：

```bash
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
```

预期：退出码为 0，无诊断输出。

- [ ] **步骤 4：运行完整回归验证**

运行：

```bash
bash tests/download-agent.test.sh
bash tests/docker-entrypoint.test.sh
git diff --check
```

然后下载真实官方二进制，并再次运行 `file` 和 SHA-256 检查。Docker 守护进程可用时构建本机平台镜像；不可用时记录为环境验证缺口。

- [ ] **步骤 5：提交任务 4**

```bash
git add .github/workflows/docker.yml .github/workflows/check-update.yml
git commit -m "ci(发布): 添加 Docker 自动检查与多架构发版"
```

### 任务 5：最终一致性检查

**文件：**

- 检查：所有新增和修改文件

- [ ] **步骤 1：对照设计逐项检查**

确认 Docker Hub Secret、日期时区、两个触发器、两个架构、缓存键、artifact 交接、UUID、状态卷、`NET_RAW` 和 `nofile` 均在代码与 README 中一致。

- [ ] **步骤 2：运行最终验证命令**

```bash
bash tests/download-agent.test.sh
bash tests/docker-entrypoint.test.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
git diff --check
git status --short
```

预期：测试和 lint 全部通过；Git 状态只包含已明确保留的用户文件。

