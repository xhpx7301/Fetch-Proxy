#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash update.sh"
  exit 1
fi

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  echo "未在 ${INSTALL_DIR} 找到已有安装，请先运行 install.sh。"
  exit 1
fi

if [[ "${SKIP_GIT_SYNC:-0}" != "1" && -d "${SCRIPT_DIR}/.git" ]]; then
  echo "正在同步 GitHub 项目更新..."
  if ! git -C "${SCRIPT_DIR}" pull --ff-only; then
    echo "项目同步失败。请检查网络，或先处理本地 Git 修改后再重试。"
    exit 1
  fi
fi

install -m 644 "${SCRIPT_DIR}/server.mjs" "${INSTALL_DIR}/server.mjs"
install -m 644 "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
install -m 755 "${SCRIPT_DIR}/manage.sh" "${INSTALL_DIR}/manage.sh"
install -m 755 "${SCRIPT_DIR}/fetch" "/usr/local/bin/fetch"
cd "${INSTALL_DIR}"
docker compose up -d --force-recreate
echo "更新完成，当前服务日志："
docker compose logs --tail=20 fetch-relay
