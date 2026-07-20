#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
ENV_FILE="${INSTALL_DIR}/.env"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash manage.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose plugin are required."
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "No installation found at ${INSTALL_DIR}. Run install.sh first."
  exit 1
fi

get_env() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n 1
}

set_env() {
  local key="$1"
  local value="$2"
  local temp_file
  temp_file="$(mktemp)"
  awk -v key="${key}" -v value="${value}" -F= '
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "${ENV_FILE}" > "${temp_file}"
  mv "${temp_file}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
}

compose() {
  (cd "${INSTALL_DIR}" && docker compose "$@")
}

restart_relay() {
  compose up -d --force-recreate
}

pause() {
  echo
  read -r -p "Press Enter to return to the menu..." _
}

show_prefix() {
  local domain secret
  domain="$(get_env RELAY_DOMAIN)"
  secret="$(get_env RELAY_SECRET)"

  if [[ -z "${domain}" || -z "${secret}" ]]; then
    echo "RELAY_DOMAIN or RELAY_SECRET is missing from ${ENV_FILE}."
    return
  fi

  echo
  echo "MiSub 专属拉取代理 (Fetch Proxy):"
  echo "https://${domain}/api/${secret}?url="
  echo
  echo "Treat this as a secret. Do not post it in screenshots or chat messages."
}

change_allowed_hosts() {
  local current updated
  current="$(get_env ALLOWED_HOSTS)"
  echo "Current allowed hosts: ${current}"
  read -r -p "New hosts (comma separated hostnames): " updated
  updated="$(printf '%s' "${updated}" | tr -d '[:space:]')"

  if [[ ! "${updated}" =~ ^[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*$ ]]; then
    echo "Invalid host list. Enter hostnames only, for example: sub.example.com,api.example.net"
    return
  fi

  set_env ALLOWED_HOSTS "${updated}"
  restart_relay
  echo "Allowed hosts updated and relay restarted."
}

rotate_secret() {
  local confirm new_secret
  read -r -p "Rotate the relay secret? Existing MiSub proxy prefixes will stop working. [y/N]: " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Cancelled."
    return
  fi

  new_secret="$(openssl rand -hex 32)"
  set_env RELAY_SECRET "${new_secret}"
  restart_relay
  echo "Relay secret rotated. Update every affected MiSub subscription now."
  show_prefix
}

change_domain() {
  local current updated
  current="$(get_env RELAY_DOMAIN)"
  echo "Current relay domain: ${current}"
  read -r -p "New relay domain (hostname only): " updated

  if [[ ! "${updated}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Invalid hostname."
    return
  fi

  set_env RELAY_DOMAIN "${updated}"
  echo "Saved. Also create or update the matching Nginx Proxy Manager host and SSL certificate."
  show_prefix
}

show_npm_setup() {
  local domain network
  domain="$(get_env RELAY_DOMAIN)"
  network="$(get_env DOCKER_NETWORK)"

  if [[ -z "${domain}" ]]; then
    echo "RELAY_DOMAIN is missing from ${ENV_FILE}."
    return
  fi

  echo
  echo "Nginx Proxy Manager Proxy Host"
  echo "  Domain Names:               ${domain}"
  echo "  Scheme:                     http"
  echo "  Forward Hostname / IP:      fetch-relay"
  echo "  Forward Port:               3210"
  echo
  echo "Advanced configuration:"
  cat <<'EOF'
access_log off;
proxy_buffering off;
resolver 127.0.0.11 valid=30s ipv6=off;
resolver_timeout 5s;
EOF
  echo
  echo "SSL tab: request a certificate for ${domain}, then enable Force SSL."
  echo "Ensure the NPM container is connected to Docker network: ${network:-fetch-relay-net}"
  echo "After saving, test: curl -i https://${domain}/"
  echo "Expected: HTTP 404 and {\"error\":\"Not found\"}"
}

while true; do
  clear || true
  echo "Fetch Proxy management"
  echo "Installation: ${INSTALL_DIR}"
  echo
  echo "1) Service status"
  echo "2) Recent logs"
  echo "3) Change allowed subscription hosts"
  echo "4) Rotate relay secret"
  echo "5) Change relay domain"
  echo "6) 显示 MiSub 专属拉取代理 (Fetch Proxy)"
  echo "7) 查看 NPM Proxy Host 与 SSL 配置"
  echo "0) Exit"
  echo
  read -r -p "Choose an option: " choice

  case "${choice}" in
    1) compose ps; pause ;;
    2) compose logs --tail=80 fetch-relay; pause ;;
    3) change_allowed_hosts; pause ;;
    4) rotate_secret; pause ;;
    5) change_domain; pause ;;
    6) show_prefix; pause ;;
    7) show_npm_setup; pause ;;
    0) exit 0 ;;
    *) echo "Unknown option."; pause ;;
  esac
done
