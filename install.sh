#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
NETWORK_NAME="${DOCKER_NETWORK:-fetch-relay-net}"
NPM_CONTAINER="${NPM_CONTAINER:-npm}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose plugin are required before installation."
  exit 1
fi

read -r -p "Relay domain (for example fetch.example.com): " RELAY_DOMAIN
while [[ -z "${RELAY_DOMAIN}" || "${RELAY_DOMAIN}" == *"/"* || "${RELAY_DOMAIN}" == *":"* ]]; do
  echo "Enter a hostname only, without https://, paths, or ports."
  read -r -p "Relay domain: " RELAY_DOMAIN
done

read -r -p "Allowed subscription domains, comma separated: " ALLOWED_HOSTS
while [[ -z "${ALLOWED_HOSTS}" ]]; do
  echo "At least one allowed subscription domain is required."
  read -r -p "Allowed subscription domains: " ALLOWED_HOSTS
done

RELAY_SECRET="$(openssl rand -hex 32)"
echo "A new relay secret has been generated. Keep it private."

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
  echo "NPM container '${NPM_CONTAINER}' was not found. Connect it to ${NETWORK_NAME} before creating the proxy host."
fi

cd "${INSTALL_DIR}"
docker compose up -d --force-recreate

cat <<EOF

Fetch relay is running.

In Nginx Proxy Manager, create a Proxy Host:
  Domain:        ${RELAY_DOMAIN}
  Scheme:        http
  Forward Host:  fetch-relay
  Forward Port:  3210

In Advanced, add:
  access_log off;
  proxy_buffering off;
  resolver 127.0.0.11 valid=30s ipv6=off;
  resolver_timeout 5s;

After SSL is configured, use this MiSub Fetch Proxy prefix:
  https://${RELAY_DOMAIN}/api/${RELAY_SECRET}?url=

Test the base URL with: curl -i https://${RELAY_DOMAIN}/
Expected response: HTTP 404 and {"error":"Not found"}
EOF
