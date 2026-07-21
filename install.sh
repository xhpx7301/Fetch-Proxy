#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
NETWORK_NAME="${DOCKER_NETWORK:-fetch-relay-net}"
NPM_CONTAINER="${NPM_CONTAINER:-npm}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash install.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "请先安装 Docker Engine 和 Docker Compose Plugin，再运行本脚本。"
  exit 1
fi

if [[ -f "${INSTALL_DIR}/.env" ]]; then
  echo "检测到已有 Fetch Proxy 安装：${INSTALL_DIR}"
  echo "请使用 sudo bash deploy.sh 自动同步项目并更新服务。"
  echo "如需修改白名单、密钥或域名，请使用 sudo bash manage.sh。"
  exit 0
fi

echo
echo "[1/2] 中转域名：必须是你自己拥有、且 DNS 已解析到本服务器的子域名。"
echo "      例如：fetch.example.com"
echo "      不要填写机场域名、https://、端口或路径。"
read -r -p "请输入中转域名：" RELAY_DOMAIN
while [[ -z "${RELAY_DOMAIN}" || "${RELAY_DOMAIN}" == *"/"* || "${RELAY_DOMAIN}" == *":"* ]]; do
  echo "格式不正确：只填写域名，例如 fetch.example.com。"
  read -r -p "请输入中转域名：" RELAY_DOMAIN
done

echo
echo "[2/2] 机场域名白名单：填写需要通过本服务器拉取的机场订阅域名。"
echo "      例如：sub.example.com,api.example.net"
echo "      只填写域名；不要填写完整订阅链接、Token、https:// 或路径。"
read -r -p "请输入机场域名白名单（多个用英文逗号分隔）：" ALLOWED_HOSTS
while [[ -z "${ALLOWED_HOSTS}" ]]; do
  echo "至少需要填写一个机场域名。"
  read -r -p "请输入机场域名白名单：" ALLOWED_HOSTS
done

echo
echo "请确认以下配置："
echo "  中转域名：${RELAY_DOMAIN}"
echo "  机场白名单：${ALLOWED_HOSTS}"
read -r -p "确认无误并开始部署？[y/N]：" CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "已取消。请重新运行脚本后填写正确内容。"
  exit 0
fi

RELAY_SECRET="$(openssl rand -hex 32)"
echo "已生成新的中转密钥，请勿截图、分享或提交到 GitHub。"

install -d -m 700 "${INSTALL_DIR}"
install -m 644 "${SCRIPT_DIR}/server.mjs" "${INSTALL_DIR}/server.mjs"
install -m 644 "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"

cat > "${INSTALL_DIR}/.env" <<EOF
ALLOWED_HOSTS=${ALLOWED_HOSTS}
RELAY_SECRET=${RELAY_SECRET}
DOCKER_NETWORK=${NETWORK_NAME}
RELAY_DOMAIN=${RELAY_DOMAIN}
EOF
chmod 600 "${INSTALL_DIR}/.env"

if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network create "${NETWORK_NAME}" >/dev/null
fi

if docker container inspect "${NPM_CONTAINER}" >/dev/null 2>&1; then
  docker network connect "${NETWORK_NAME}" "${NPM_CONTAINER}" 2>/dev/null || true
else
  echo "未找到 NPM 容器 '${NPM_CONTAINER}'。创建 Proxy Host 前，请先将它接入 Docker 网络 ${NETWORK_NAME}。"
fi

cd "${INSTALL_DIR}"
docker compose up -d --force-recreate

cat <<EOF

Fetch Proxy 已启动。

请在 Nginx Proxy Manager 新建 Proxy Host：
  域名：        ${RELAY_DOMAIN}
  协议：        http
  上游主机：    fetch-relay
  上游端口：    3210

在 Advanced 中添加：
  access_log off;
  proxy_buffering off;
  resolver 127.0.0.11 valid=30s ipv6=off;
  resolver_timeout 5s;

申请 SSL 证书并启用 Force SSL 后，将以下完整地址填入 MiSub 的“使用专属拉取代理 (Fetch Proxy)”：
  https://${RELAY_DOMAIN}/api/${RELAY_SECRET}?url=

注意：末尾 ?url= 必须保留，中转密钥不可泄露。

验证命令：curl -i https://${RELAY_DOMAIN}/
预期响应：HTTP 404 和 {"error":"Not found"}
EOF
