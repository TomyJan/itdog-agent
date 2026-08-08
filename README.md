# ITDOG Agent Docker

将 ITDOG 贡献节点 Agent 封装为 Docker 镜像，支持 `linux/amd64` 和 `linux/arm64`。

- **源码仓库：** [GitHub](https://github.com/TomyJan/itdog-agent)
- **Docker 镜像：** [Docker Hub](https://hub.docker.com/r/tomyjan/itdog-agent)

本仓库不是 ITDOG 官方项目。镜像中的 agent 二进制直接来自 ITDOG 官方下载地址：

- `https://dl.itdog.cn/agent/agent_amd64.tar.gz`
- `https://dl.itdog.cn/agent/agent_arm64.tar.gz`

## 快速开始

### 准备 UUID

先在 ITDOG 节点管理页面取得设备 UUID。启动节点时，唯一必填配置是 `DEVICE_UUID`。

Linux 或 macOS：

```bash
DEVICE_UUID='<your-uuid>' docker compose up -d
```

PowerShell：

```powershell
$env:DEVICE_UUID = '<your-uuid>'
docker compose up -d
```

查看运行日志：

```bash
docker compose logs -f itdog-agent
```

停止节点：

```bash
docker compose down
```

`docker compose down` 会保留 agent 的节点状态。确认不再需要该节点的数据时，可以运行 `docker compose down -v` 一并删除数据卷。

### 升级镜像

```bash
docker compose pull
docker compose up -d
```

镜像内 agent 二进制或 `DEVICE_UUID` 变化时，入口脚本会删除旧 `node_id` 并重新注册。普通容器重启会保留现有 `node_id`。

### IPv6 连通性

Compose 默认创建 IPv4/IPv6 双栈网络。Docker 为容器分配 ULA IPv6 地址，并通过宿主机 NAT66 访问公网。宿主机必须先具备可用的公网 IPv6 地址和默认路由：

```bash
ip -6 address show scope global
ip -6 route show default
```

如果宿主机通过路由通告（Router Advertisement，RA）获取 IPv6 默认路由，Docker 启用 IPv6 转发后，Linux 会在 `accept_ra=1` 时停止接受 RA。启动容器前，应将上联网卡的 `accept_ra` 持久化为 `2`。以下示例的上联网卡为 `ens18`，请按实际接口名修改：

```bash
UPLINK=ens18
printf 'net.ipv6.conf.%s.accept_ra = 2\n' "$UPLINK" \
  | sudo tee /etc/sysctl.d/90-docker-ipv6-ra.conf
sudo sysctl --system
```

应用后确认默认路由和宿主机 IPv6 出站正常：

```bash
ip -6 route show default
curl -6 --connect-timeout 10 https://api64.ipify.org
```

如果默认路由已经消失，需要先通过宿主机网络管理服务重新获取 RA，或按网络服务商提供的 IPv6 网关临时恢复默认路由。

从旧版 IPv4-only Compose 网络升级时，需要重建默认网络才能应用 IPv6 配置。以下操作会短暂停止容器，但不会删除命名卷中的节点状态：

```bash
docker compose down
docker compose up -d
```

### 使用其他镜像

Compose 默认拉取 `tomyjan/itdog-agent:latest`。fork 本仓库或使用固定版本时，可以额外设置 `ITDOG_AGENT_IMAGE`：

```bash
DEVICE_UUID='<your-uuid>' \
ITDOG_AGENT_IMAGE='yourname/itdog-agent:20260806' \
docker compose up -d
```

## 容器运行配置

配置与官方裸机安装脚本保持以下对应关系：

| 官方安装行为 | 容器配置 |
| --- | --- |
| 以 `/opt/itdog-agent` 为工作目录 | 同路径作为工作目录和持久卷 |
| 注入 `DEVICE_UUID` | Compose 必填环境变量 |
| `LimitNOFILE=1048576` | Compose `nofile` 软硬限制均为 `1048576` |
| systemd 自动重启 | `restart: unless-stopped` |
| root 服务创建原始 ICMP socket | 仅增加 `NET_RAW` capability |
| 直接使用宿主机 IP 网络栈 | 使用 host 网络模式 |

官方 agent 是动态链接的 PyInstaller 单文件程序。运行镜像基于 Debian 12 slim，包含 glibc、`zlib1g`、CA 证书和 `tini`。下载阶段使用的 `curl`、`tar` 不会进入最终镜像。

## 镜像发布

### Docker Hub 准备

1. 在 Docker Hub 创建名为 `itdog-agent` 的仓库。
2. 创建具有目标仓库 Read、Write、Delete 权限的 Personal Access Token。Docker Hub 更新仓库简介需要 Delete 权限对应的仓库管理能力。
3. 在 GitHub 仓库的 `Settings > Secrets and variables > Actions` 中添加：

| Secret | 内容 |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | Docker Hub Personal Access Token |

发布目标由 Secret 动态计算为 `<DOCKERHUB_USERNAME>/itdog-agent`。Token 用于 Docker Hub 登录和更新仓库元信息，不会传入 Docker build 上下文或镜像层。

### 手动发布

在 GitHub Actions 中运行 `Docker` 工作流。`version` 可以留空；留空时使用新加坡时区当天日期，格式为 `YYYYMMDD`，例如 `20260806`。

每次发布会同时推送：

- `<DOCKERHUB_USERNAME>/itdog-agent:<version>`
- `<DOCKERHUB_USERNAME>/itdog-agent:latest`

两个标签都是包含 `linux/amd64`、`linux/arm64` 的多架构 manifest。

镜像推送成功后，工作流还会把本 README 同步到 Docker Hub Overview，并更新仓库短描述。Dockerfile 中的 OCI 标签属于镜像元数据，Docker Hub 不会自动用它们填充仓库页面。

### 由其他工作流调用

同一仓库内的工作流可以直接复用发布工作流：

```yaml
jobs:
  publish:
    uses: ./.github/workflows/docker.yml
    with:
      version: '20260806'
    secrets: inherit
```

省略 `version` 时同样使用新加坡时区当天日期。

### 自动检查更新

`Check agent update` 工作流每天新加坡时间 00:00 运行，也支持手动触发。它会：

1. 下载官方 `amd64`、`arm64` agent。
2. 比较最近一次成功发布所缓存的二进制 SHA-256。
3. 任一架构变化时，调用 `Docker` 工作流发布镜像。
4. 发布成功后更新缓存；发布失败则保留旧缓存，便于下次重试。

更新检测比较解包后的实际 ELF 文件，不受 gzip 元数据变化影响。ITDOG 未提供签名或官方 SHA-256，因此下载真实性依赖官方 HTTPS 端点。

## 本地构建

先下载并校验官方双架构二进制：

```bash
./scripts/download-agent.sh agent-downloads
```

构建当前平台镜像：

```bash
docker build --build-arg VERSION=dev -t itdog-agent:dev .
```

运行 Shell 测试：

```bash
bash tests/download-agent.test.sh
bash tests/docker-entrypoint.test.sh
```

## 许可证

仓库代码按 [LICENSE](./LICENSE) 提供。ITDOG Agent 二进制及服务的使用还应遵守 ITDOG 的相关条款。
