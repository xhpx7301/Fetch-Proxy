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

normalize_allowed_hosts() {
  local raw host normalized=""
  raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  IFS=',' read -r -a hosts <<< "${raw}"

  if [[ -z "${raw}" || ${#hosts[@]} -eq 0 ]]; then
    return 1
  fi

  for host in "${hosts[@]}"; do
    if [[ ! "${host}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
      echo "白名单域名格式不正确：${host}" >&2
      return 1
    fi
    if [[ "${host}" == "${RELAY_DOMAIN}" || "${host}" == *"${RELAY_DOMAIN}"* ]]; then
      echo "机场白名单不能包含中转域名：${RELAY_DOMAIN}" >&2
      return 1
    fi
    normalized+="${normalized:+,}${host}"
  done

  printf '%s' "${normalized}"
}

echo
echo "[1/2] 中转域名：必须是你自己拥有、且 DNS 已解析到本服务器的子域名。"
echo "      例如：fetch.example.com"
echo "      不要填写机场域名、https://、端口或路径。"
read -r -p "请输入中转域名：" RELAY_DOMAIN
while [[ -z "${RELAY_DOMAIN}" || "${RELAY_DOMAIN}" == *"/"* || "${RELAY_DOMAIN}" == *":"* ]]; do
  echo "格式不正确：只填写域名，例如 fetch.example.com。"
  read -r -p "请输入中转域名：" RELAY_DOMAIN
done
RELAY_DOMAIN="$(printf '%s' "${RELAY_DOMAIN}" | tr '[:upper:]' '[:lower:]')"

echo
echo "[2/2] 机场域名白名单：填写需要通过本服务器拉取的机场订阅域名。"
echo "      例如：sub.example.com,api.example.net"
echo "      只填写域名；不要填写完整订阅链接、Token、https:// 或路径。"
while true; do
  read -r -p "请输入机场域名白名单（多个用英文逗号分隔）：" ALLOWED_HOSTS_INPUT
  if ALLOWED_HOSTS="$(normalize_allowed_hosts "${ALLOWED_HOSTS_INPUT}")"; then
    break
  fi
  echo "请重新填写有效的机场域名白名单。"
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
install -m 755 "${SCRIPT_DIR}/manage.sh" "${INSTALL_DIR}/manage.sh"
install -m 755 "${SCRIPT_DIR}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
install -m 755 "${SCRIPT_DIR}/fetch" "/usr/local/bin/fetch"

cat > "${INSTALL_DIR}/.env" <<EOF
ALLOWED_HOSTS=${ALLOWED_HOSTS}
RELAY_SECRET=${RELAY_SECRET}
DOCKER_NETWORK=${NETWORK_NAME}
RELAY_DOMAIN=${RELAY_DOMAIN}
SOURCE_DIR=${SCRIPT_DIR}
EOF
chmod 600 "${INSTALL_DIR}/.env"

NETWORK_CREATED=0
NPM_CONNECTED=0

if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network create "${NETWORK_NAME}" >/dev/null
  NETWORK_CREATED=1
fi

if docker container inspect "${NPM_CONTAINER}" >/dev/null 2>&1; then
  if ! docker network inspect "${NETWORK_NAME}" -f '{{range .Containers}}{{println .Name}}{{end}}' | grep -Fxq "${NPM_CONTAINER}"; then
    docker network connect "${NETWORK_NAME}" "${NPM_CONTAINER}"
    NPM_CONNECTED=1
  fi
else
  echo "未找到 NPM 容器 '${NPM_CONTAINER}'。创建 Proxy Host 前，请先将它接入 Docker 网络 ${NETWORK_NAME}。"
fi

cat > "${INSTALL_DIR}/.install-state" <<EOF
DOCKER_NETWORK=${NETWORK_NAME}
NPM_CONTAINER=${NPM_CONTAINER}
NETWORK_CREATED=${NETWORK_CREATED}
NPM_CONNECTED=${NPM_CONNECTED}
EOF
chmod 600 "${INSTALL_DIR}/.install-state"

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

日常管理：以后在任意目录直接输入 fetch，即可打开 Fetch Proxy 管理菜单。
菜单中可直接同步安装/更新；卸载会删除服务，但会保留 NPM 和 DNS 配置以免影响其他站点。
EOF
