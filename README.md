# Fetch Proxy

给 MiSub 使用的受限机场订阅拉取中转。适用于机场拒绝 Cloudflare Worker IP、但 VPS 可以正常拉取订阅的情况。

## 这是什么

MiSub 拉取机场订阅时，请求路径改为：

```text
MiSub -> Fetch Proxy（你的 VPS）-> 机场订阅域名
```

机场看到的出口 IP 是 VPS，而不是 Cloudflare Worker。Fetch Proxy 只允许访问你指定的机场域名，并将订阅正文和流量信息转回 MiSub。

它不会：

- 提供节点代理、加速或测速功能。
- 计算节点的真实流量。
- 接受任意 URL 转发请求。

## 功能与安全边界

- 仅允许 `.env` 中 `ALLOWED_HOSTS` 列出的 HTTPS 域名。
- 使用路径中的 `RELAY_SECRET` 鉴权。
- 只允许最多 3 次、仍在白名单内的重定向。
- 单次订阅响应上限为 8 MiB，超时为 20 秒。
- 透传机场的 `subscription-userinfo` 响应头，供 MiSub 展示已用、总量和到期信息。
- Docker 不公开暴露服务端口，仅由 Nginx Proxy Manager 转发。

## 快速开始

### 前置条件

- Debian/Ubuntu VPS，已安装 Docker Engine 与 Docker Compose Plugin。
- 一个已解析到 VPS 的子域名，例如 `fetch.example.com`。
- 已运行 Nginx Proxy Manager，容器名默认是 `npm`，并占用 VPS 的 `80/443`。
- 需要中转的机场订阅域名，例如 `sub.example.com`，不是完整订阅链接。

### 一键安装或更新

以后不需要再次执行 `git clone`。在首次安装和后续更新时，都在已有项目目录执行：

```bash
cd ~/Fetch-Proxy
sudo bash deploy.sh
```

它会自动同步 GitHub：首次运行进入安装流程；检测到已部署服务后，仅更新服务代码，保留 `.env` 中的中转域名、白名单和密钥。

### 手动首次部署

```bash
git clone https://github.com/xhpx7301/Fetch-Proxy.git
cd Fetch-Proxy
sudo bash install.sh
```

脚本会依次询问：

1. 中转域名，例如 `fetch.example.com`。
2. 机场白名单域名，多个域名用英文逗号分隔。

随后它会自动生成中转密钥、创建 Docker 网络 `fetch-relay-net`、启动服务，并尝试把 NPM 容器接入该网络。

若 NPM 容器名称不是 `npm`：

```bash
sudo NPM_CONTAINER=你的NPM容器名 bash install.sh
```

## 配置 Nginx Proxy Manager

安装脚本或 `manage.sh` 菜单的第 7 项会显示当前配置。NPM 中新增 Proxy Host：

| 项目 | 填写内容 |
| --- | --- |
| Domain Names | 你的中转域名 |
| Scheme | `http` |
| Forward Hostname / IP | `fetch-relay` |
| Forward Port | `3210` |

在 **Advanced** 粘贴：

```nginx
access_log off;
proxy_buffering off;
resolver 127.0.0.11 valid=30s ipv6=off;
resolver_timeout 5s;
```

在 **SSL** 标签页申请该域名的证书，并开启 **Force SSL**。

完成后，在 VPS 测试：

```bash
curl -i https://你的中转域名/
```

预期是 `HTTP 404` 和：

```json
{"error":"Not found"}
```

这不是错误，而是服务正常且未携带密钥时的安全响应。

## 配置 MiSub

1. 打开“机场订阅”，编辑要中转拉取的机场。
2. 打开“使用专属拉取代理 (Fetch Proxy)”。
3. 填入管理菜单第 6 项输出的完整地址：

```text
https://你的中转域名/api/中转密钥?url=
```

4. 保留末尾的 `?url=`，不要在这个框中填写机场订阅链接。
5. 点击“测试代理”，成功后保存并刷新订阅。

机场原始订阅链接仍填写在上方“订阅链接”输入框。多个机场可以共用一个中转前缀，前提是它们的域名均在白名单中。

## 日常管理

在克隆本仓库的目录中执行：

```bash
cd Fetch-Proxy
sudo bash manage.sh
```

安装或更新完成后，也可以在任意目录直接输入：

```bash
fetch
```

| 菜单项 | 用途 |
| --- | --- |
| 服务状态 | 查看容器是否正常运行。 |
| 最近日志 | 查看最近的中转请求和错误。 |
| 管理机场白名单 | 查看、逐项新增、逐项删除或替换全部机场域名，并自动重启服务。 |
| 轮换中转密钥 | 泄露密钥后生成新密钥并重启服务。随后必须更新 MiSub。 |
| 修改中转域名 | 保存新域名，用于生成提示；NPM 和 DNS 也需要同步调整。 |
| 显示 MiSub 专属拉取代理 (Fetch Proxy) | 自动生成可直接填入 MiSub 的完整前缀。 |
| 查看 NPM Proxy Host 与 SSL 配置 | 显示当前域名对应的 NPM 填写内容与验证命令。 |

## 更新项目

```bash
cd Fetch-Proxy
sudo bash deploy.sh
```

不要对已有目录重复执行 `git clone`，否则会提示目录已存在。`deploy.sh` 会自动拉取 GitHub 最新代码并更新服务，但不会修改 `/opt/fetch-relay/.env`，因此不会丢失白名单、中转域名或密钥。

## 更换 VPS

1. 将中转域名的 DNS 指向新 VPS。
2. 在新 VPS 克隆本仓库并执行 `sudo bash install.sh`。
3. 用 NPM 配置新的 Proxy Host 与 SSL。
4. 将 MiSub 中的专属拉取代理前缀更新为新 VPS 输出的地址。
5. 在 MiSub 点击“测试代理”，确认节点数正常后再停用旧 VPS。

## 常见问题

| 现象 | 优先检查 |
| --- | --- |
| NPM 访问域名返回 `502` | NPM 与 `fetch-relay` 是否在同一 Docker 网络；Advanced 是否有 `resolver 127.0.0.11`。 |
| 域名根路径返回 `404` | 正常，说明 NPM 和服务已连通。 |
| MiSub 测试代理失败 `502` | 机场域名是否列入白名单；VPS 是否能直接访问机场；查看“最近日志”。 |
| MiSub 能获取节点但没有流量信息 | 先更新本项目到支持 `subscription-userinfo` 透传的版本；若仍没有，机场本身未提供该响应头。 |
| 修改白名单后仍失败 | 使用管理菜单修改，确认域名仅为主机名且没有 `https://`、路径或 Token。 |
| 机场仍返回 `403` | 该机场也可能封锁 VPS IP 或要求指定 User-Agent；尝试在 MiSub 选择对应客户端的自定义 User-Agent。 |

## 重要文件

| 文件 | 位置 | 说明 |
| --- | --- | --- |
| 服务配置 | `/opt/fetch-relay/.env` | 白名单、密钥、中转域名和 Docker 网络。 |
| 服务程序 | `/opt/fetch-relay/server.mjs` | Node.js 中转服务。 |
| Compose 文件 | `/opt/fetch-relay/docker-compose.yml` | Docker 容器配置。 |
| 本仓库 | `Fetch-Proxy/` | 安装、更新、管理脚本与文档。 |

## 安全规则

- `.env` 已被 Git 忽略，不能提交、公开或截图。
- `RELAY_SECRET`、机场订阅 Token 都属于敏感信息。泄露后立即轮换。
- `ALLOWED_HOSTS` 只填机场域名，多个值用英文逗号分隔；禁止使用 `*`。
- 不要将服务改成任意 URL 转发器，否则 VPS 会成为可被滥用的开放代理。
- 如密钥泄露，可在菜单选择“轮换中转密钥”。轮换后更新 MiSub 中所有使用该中转的订阅。
