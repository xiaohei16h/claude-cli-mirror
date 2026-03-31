# Claude CLI Mirror (Caddy)

国内 Claude Code CLI 安装镜像，基于 Caddy 反向代理。

## 快速部署

```bash
# 1. 克隆仓库
git clone https://github.com/<your-repo>/claude-cli-mirror.git
cd claude-cli-mirror

# 2. 配置环境变量
cp .env.example .env
# 编辑 .env，设置 MIRROR_DOMAIN 为你的域名

# 3. 确保域名 DNS 已指向服务器，然后启动
docker compose up -d
```

## 配置说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MIRROR_DOMAIN` | `localhost` | 镜像站域名 |
| `GCS_BUCKET` | `claude-code-dist-...` | GCS bucket 前缀（一般无需修改） |
| `HTTP_PORT` | `80` | HTTP 监听端口 |
| `HTTPS_PORT` | `443` | HTTPS 监听端口（仅 `AUTO_HTTPS=on` 时生效） |
| `AUTO_HTTPS` | `off` | HTTPS 模式。`off` = 仅 HTTP；`on` = 自动 Let's Encrypt 证书 |

默认使用 HTTP 协议。如需启用 HTTPS，在 `.env` 中设置 `AUTO_HTTPS=on`，Caddy 会自动申请 Let's Encrypt 证书。

## 用户使用

```bash
# 安装最新版（默认从 npm registry 获取）
curl -fsSL http://<mirror>/install.sh | bash

# 安装 stable 版（GCS 标记的稳定版）
curl -fsSL http://<mirror>/install.sh | bash -s stable

# 安装指定版本
curl -fsSL http://<mirror>/install.sh | bash -s 2.1.88

# 查看最新版本号
curl http://<mirror>/version
```

已安装且为最新版本时，脚本会自动跳过下载。

## API 端点

| 路径 | 说明 |
|------|------|
| `/install.sh` | 安装脚本 |
| `/version` | 最新版本号（npm registry） |
| `/version/stable` | 稳定版本号（GCS） |
| `/storage/{path}` | 代理 GCS 二进制下载 |
| `/health` | 健康检查 |

## 本地测试

```bash
docker compose up -d

curl http://localhost/health         # => ok
curl http://localhost/install.sh     # => 安装脚本内容
curl http://localhost/version        # => latest (npm)
curl http://localhost/version/stable # => stable (GCS)
```

## 注意事项

- 此镜像仅解决**首次安装**问题。安装后 Claude Code 的自动更新仍会直连官方服务器
- 如需代理更新，可配置 `HTTPS_PROXY` 环境变量，或定期通过镜像重新安装
- 二进制文件约 ~200MB，首次下载需要一定时间
