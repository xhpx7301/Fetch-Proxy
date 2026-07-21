#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
STATE_FILE="${INSTALL_DIR}/.install-state"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash uninstall.sh"
  exit 1
fi

if [[ ! -f "${INSTALL_DIR}/.env" || ! -f "${INSTALL_DIR}/server.mjs" ]]; then
  echo "未在 ${INSTALL_DIR} 找到完整的 Fetch Proxy 安装，已取消。"
  exit 1
fi

read -r -p "将停止并删除 Fetch Proxy 服务、配置和 fetch 命令。输入 UNINSTALL 确认：" confirm
if [[ "${confirm}" != "UNINSTALL" ]]; then
  echo "已取消卸载。"
  exit 0
fi

get_state() {
  local key="$1"
  [[ -f "${STATE_FILE}" ]] || return 0
  sed -n "s/^${key}=//p" "${STATE_FILE}" | tail -n 1
}

network_name="$(get_state DOCKER_NETWORK)"
npm_container="$(get_state NPM_CONTAINER)"
network_created="$(get_state NETWORK_CREATED)"
npm_connected="$(get_state NPM_CONNECTED)"

echo "正在停止并删除 Fetch Proxy 容器..."
(cd "${INSTALL_DIR}" && docker compose down --remove-orphans) || true

if [[ "${npm_connected}" == "1" && -n "${network_name}" && -n "${npm_container}" ]]; then
  echo "正在断开 NPM 容器与 Fetch Proxy 网络的连接..."
  docker network disconnect "${network_name}" "${npm_container}" 2>/dev/null || true
fi

if [[ "${network_created}" == "1" && -n "${network_name}" ]]; then
  if docker network rm "${network_name}" >/dev/null 2>&1; then
    echo "已删除本次安装创建的 Docker 网络：${network_name}"
  else
    echo "Docker 网络 ${network_name} 仍被其他容器使用，已保留。"
  fi
fi

if [[ -f "/usr/local/bin/fetch" ]] && grep -q '/opt/fetch-relay/manage.sh' "/usr/local/bin/fetch"; then
  rm -f "/usr/local/bin/fetch"
fi

rm -rf "${INSTALL_DIR}"

echo
echo "Fetch Proxy 已卸载。"
echo "为避免影响其他站点，以下内容未自动删除："
echo "  1. Nginx Proxy Manager 中的 Proxy Host 与 SSL 证书。"
echo "  2. DNS 中的中转域名记录。"
echo "确认不再使用后，请在对应面板手动删除它们。"

