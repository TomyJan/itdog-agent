# ITDOG Agent Docker 自动发布设计

## 目标

为官方仅提供裸机安装脚本的 ITDOG Agent 增加 Docker 交付方式，并满足以下要求：

- Docker 发布工作流既能由其他工作流调用，也能手动触发。
- 发布版本允许显式传入；未传入时使用新加坡时区当天日期，格式为 `YYYYMMDD`。
- 每天新加坡时间 00:00 检查官方 `amd64`、`arm64` agent 二进制是否变化，仅在发生变化时发布。
- 发布 Docker Hub 多架构镜像，同时维护日期版本标签和 `latest` 标签。
- Compose 用户只需提供 `DEVICE_UUID` 环境变量即可启动节点。

默认镜像名为 `tomyjan/itdog-agent`。发布工作流通过 Docker Hub 用户名 Secret 计算实际镜像名，便于 fork 后使用自己的命名空间。

## 官方行为核验

官方安装脚本执行以下操作：

1. 仅接受一个设备 UUID，并以 `DEVICE_UUID` 环境变量传给 agent。
2. 仅支持 `amd64` 和 `arm64`，分别下载固定 URL 下的压缩包。
3. 安装 `curl` 和 `tar`，将压缩包中的 `agent` 安装到 `/opt/itdog-agent/agent`。
4. 删除旧 `node_id`，通过 systemd 以 `/opt/itdog-agent` 为工作目录运行 agent。
5. 配置自动重启，并设置 `LimitNOFILE=1048576`。

进一步检查两个官方 ELF 文件后确认：

- 两个二进制均为动态链接的 PyInstaller 单文件程序。
- 启动器依赖 glibc、`libdl`、`libpthread` 和 zlib；其余 Python、OpenSSL、libcurl 等库包含在单文件包中，并在启动时释放到 `/tmp`。
- agent 直接创建 IPv4/IPv6 原始 ICMP socket，因此容器需要 `CAP_NET_RAW`。
- agent 会在 `/opt/itdog-agent` 写入 PID 和节点状态，因此该目录必须可写并应持久化。
- 启动期间未发现 agent 调用 `ping`、`curl`、`traceroute` 等外部命令。

因此，运行镜像使用 Debian 12 slim，并显式安装 `ca-certificates`、`zlib1g` 和 `tini`。`curl`、`tar` 只属于下载阶段，不进入运行镜像。容器保持 root 身份，以对齐官方 systemd 服务并允许创建原始 socket；不授予 `NET_ADMIN` 或 `privileged` 等额外权限。

## 组件设计

### 二进制下载脚本

`scripts/download-agent.sh` 负责下载两个官方归档、提取 agent、校验 ELF 架构并输出规范化文件：

- `agent-downloads/agent_amd64`
- `agent-downloads/agent_arm64`

更新检测比较提取后二进制的 SHA-256，而不是压缩包的 SHA-256。这样可以忽略 gzip 元数据变化，只在实际程序变化时发布。

脚本使用 HTTPS 证书校验、有限次数重试和安全的临时目录。任一架构下载、解包或架构校验失败时，整个流程失败，不发布不完整镜像。

### Docker 镜像

`Dockerfile` 根据 BuildKit 的 `TARGETARCH` 复制对应二进制，构建 `linux/amd64` 和 `linux/arm64` 镜像。镜像包含以下运行约束：

- 工作目录：`/opt/itdog-agent`
- agent 路径：`/usr/local/bin/itdog-agent`
- 状态卷：`/opt/itdog-agent`
- PID 1：`tini`
- 入口脚本：校验 `DEVICE_UUID` 后使用 `exec` 启动 agent
- OCI 标签：版本、源码仓库、源码 revision

agent 放在状态卷之外，避免挂载 `/opt/itdog-agent` 后遮蔽可执行文件。

### Docker 发布工作流

`.github/workflows/docker.yml` 支持：

- `workflow_dispatch`：手动发布，可选 `version`。
- `workflow_call`：由其他工作流调用，可选 `version`、二进制 artifact 名称和两个预期 SHA-256。

处理流程如下：

1. 检出仓库。
2. 从调用方 artifact 获取已检查的二进制；没有 artifact 时直接运行下载脚本。
3. 校验两个二进制及调用方提供的预期 SHA-256。
4. 解析版本；空值使用 `TZ=Asia/Singapore date +%Y%m%d`。
5. 使用 `DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN` 登录 Docker Hub。
6. 通过 QEMU、Buildx 构建并推送多架构镜像。
7. 发布 `<version>` 和 `latest` 两个标签。
8. 仅在镜像推送成功后，以组合二进制 SHA-256 为键保存 GitHub Actions 缓存。

版本值必须满足 Docker 标签格式。缺少 Secret、哈希不匹配或任一平台构建失败时，不更新任何缓存记录。

### 自动更新工作流

`.github/workflows/check-update.yml` 同时支持定时和手动检查。GitHub Actions cron 使用 UTC，因此配置为每天 16:00 UTC，对应新加坡次日 00:00。

处理流程如下：

1. 恢复最近一次成功发布对应的 agent 二进制缓存。
2. 下载当前两个官方二进制并计算 SHA-256。
3. 两个哈希均未变化时正常结束。
4. 任一哈希变化时，将本次二进制上传为短期 artifact。
5. 调用 Docker 发布工作流，并传入 artifact 名称和两个预期哈希。
6. Docker 发布成功后由发布工作流写入新缓存；失败时保留旧缓存，使次日或手动重试仍会检测到更新。

首次运行没有缓存，视为发现更新并发布初始镜像。

## Compose 使用方式

`compose.yaml` 默认拉取 `tomyjan/itdog-agent:latest`，配置以下内容：

- 必填环境变量 `DEVICE_UUID`
- `CAP_NET_RAW`
- `nofile` 软硬限制 `1048576`
- `/opt/itdog-agent` 命名卷
- `unless-stopped` 重启策略

用户在 POSIX Shell 中运行：

```bash
DEVICE_UUID='<your-uuid>' docker compose up -d
```

PowerShell 使用等价的环境变量赋值后运行 `docker compose up -d`。无需 `.env` 文件或其他必填配置。

## Secret 与权限

仓库需要配置以下 GitHub Actions Secrets：

- `DOCKERHUB_USERNAME`：Docker Hub 用户名。
- `DOCKERHUB_TOKEN`：Docker Hub Personal Access Token，至少具有目标仓库的 Read & Write 权限。

工作流仅申请 `contents: read` 权限。Docker Hub Token 不传入 Docker build 上下文，也不会写入镜像层。

## 测试与验证

实现需要覆盖以下验证：

- 下载脚本在缺少架构文件、哈希错误和非法参数时失败。
- 入口脚本在缺少 `DEVICE_UUID` 时失败，并能原样 `exec` 用户命令。
- YAML 文件可解析，`workflow_call`、`workflow_dispatch` 和 cron 配置存在。
- Compose 展开后包含镜像、UUID、能力、卷和 `nofile` 配置。
- Dockerfile 仅声明 `amd64`、`arm64` 所需路径，并包含已核验的运行依赖。
- Docker 守护进程可用时，实际构建本机架构镜像并验证入口行为；不可用时明确记录该验证缺口。

