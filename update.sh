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

install -m 644 "${SCRIPT_DIR}/server.mjs" "${INSTALL_DIR}/server.mjs"
install -m 644 "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
cd "${INSTALL_DIR}"
docker compose up -d --force-recreate
docker compose logs --tail=20 fetch-relay
