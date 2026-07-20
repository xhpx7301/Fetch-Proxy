#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash update.sh"
  exit 1
fi

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  echo "No existing installation found at ${INSTALL_DIR}. Run install.sh first."
  exit 1
fi

install -m 644 "${SCRIPT_DIR}/server.mjs" "${INSTALL_DIR}/server.mjs"
install -m 644 "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
cd "${INSTALL_DIR}"
docker compose up -d --force-recreate
docker compose logs --tail=20 fetch-relay

