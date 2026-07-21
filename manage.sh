#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
ENV_FILE="${INSTALL_DIR}/.env"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash manage.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "需要 Docker Engine 和 Docker Compose Plugin。"
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "未在 ${INSTALL_DIR} 找到已有安装，请先运行 install.sh。"
  exit 1
fi

get_env() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n 1
}

normalize_allowed_hosts() {
  local raw host normalized=""
  local relay_domain
  local -A seen=()
  relay_domain="$(get_env RELAY_DOMAIN)"
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
    if [[ -n "${relay_domain}" && ( "${host}" == "${relay_domain}" || "${host}" == *"${relay_domain}"* ) ]]; then
      echo "机场白名单不能包含中转域名：${relay_domain}" >&2
      return 1
    fi
    if [[ -n "${seen[${host}]:-}" ]]; then
      continue
    fi
    seen["${host}"]=1
    normalized+="${normalized:+,}${host}"
  done

  printf '%s' "${normalized}"
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
  read -r -p "按 Enter 返回菜单..." _
}

show_prefix() {
  local domain secret
  domain="$(get_env RELAY_DOMAIN)"
  secret="$(get_env RELAY_SECRET)"

  if [[ -z "${domain}" || -z "${secret}" ]]; then
    echo "${ENV_FILE} 缺少 RELAY_DOMAIN 或 RELAY_SECRET。"
    return
  fi

  echo
  echo "MiSub 专属拉取代理 (Fetch Proxy)："
  echo "https://${domain}/api/${secret}?url="
  echo
  echo "此地址包含密钥，请勿截图、分享或发送到聊天记录。"
}

show_allowed_hosts() {
  local current host index=1
  current="$(get_env ALLOWED_HOSTS)"
  echo "当前机场域名白名单："
  IFS=',' read -r -a hosts <<< "${current}"
  for host in "${hosts[@]}"; do
    [[ -n "${host}" ]] || continue
    echo "  ${index}) ${host}"
    ((index += 1))
  done
}

save_allowed_hosts() {
  set_env ALLOWED_HOSTS "$1"
  restart_relay
  echo "机场白名单已更新，中转服务已重启。"
}

add_allowed_host() {
  local current added updated
  current="$(get_env ALLOWED_HOSTS)"
  read -r -p "新增机场域名（只填一个域名）：" added

  if ! updated="$(normalize_allowed_hosts "${current},${added}")"; then
    echo "格式不正确。只填写机场域名，例如：sub.example.com"
    return
  fi

  save_allowed_hosts "${updated}"
}

remove_allowed_host() {
  local current target host updated="" found=false
  current="$(get_env ALLOWED_HOSTS)"
  read -r -p "删除机场域名（必须与列表完全一致）：" target
  target="$(printf '%s' "${target}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

  IFS=',' read -r -a hosts <<< "${current}"
  for host in "${hosts[@]}"; do
    if [[ "${host}" == "${target}" ]]; then
      found=true
      continue
    fi
    updated+="${updated:+,}${host}"
  done

  if [[ "${found}" != true ]]; then
    echo "白名单中未找到：${target}"
    return
  fi
  if [[ -z "${updated}" ]]; then
    echo "至少需要保留一个机场域名，不能删除最后一项。"
    return
  fi

  if ! updated="$(normalize_allowed_hosts "${updated}")"; then
    echo "剩余白名单格式异常，请使用“替换全部白名单”修复。"
    return
  fi

  save_allowed_hosts "${updated}"
}

replace_allowed_hosts() {
  local updated
  read -r -p "新的完整白名单（多个域名用英文逗号分隔）：" updated

  if ! updated="$(normalize_allowed_hosts "${updated}")"; then
    echo "格式不正确。只填写机场域名，例如：sub.example.com,api.example.net"
    return
  fi

  save_allowed_hosts "${updated}"
}

manage_allowed_hosts() {
  local choice
  while true; do
    echo
    show_allowed_hosts
    echo
    echo "1) 新增机场域名"
    echo "2) 删除机场域名"
    echo "3) 替换全部白名单"
    echo "0) 返回上级菜单"
    read -r -p "请选择操作：" choice

    case "${choice}" in
      1) add_allowed_host; pause ;;
      2) remove_allowed_host; pause ;;
      3) replace_allowed_hosts; pause ;;
      0) return ;;
      *) echo "无效选项。"; pause ;;
    esac
  done
}

rotate_secret() {
  local confirm new_secret
  read -r -p "确认轮换中转密钥？现有 MiSub 代理地址将立即失效。[y/N]：" confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "已取消。"
    return
  fi

  new_secret="$(openssl rand -hex 32)"
  set_env RELAY_SECRET "${new_secret}"
  restart_relay
  echo "中转密钥已轮换，请立即更新所有使用此中转的 MiSub 订阅。"
  show_prefix
}

change_domain() {
  local current updated
  current="$(get_env RELAY_DOMAIN)"
  echo "当前中转域名：${current}"
  read -r -p "新的中转域名（只填域名）：" updated

  if [[ ! "${updated}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "域名格式不正确。"
    return
  fi

  set_env RELAY_DOMAIN "${updated}"
  echo "已保存。请同时在 Nginx Proxy Manager 中创建或更新对应的 Proxy Host 和 SSL 证书。"
  show_prefix
}

show_npm_setup() {
  local domain network
  domain="$(get_env RELAY_DOMAIN)"
  network="$(get_env DOCKER_NETWORK)"

  if [[ -z "${domain}" ]]; then
    echo "${ENV_FILE} 缺少 RELAY_DOMAIN。"
    return
  fi

  echo
  echo "Nginx Proxy Manager Proxy Host 配置"
  echo "  Domain Names：              ${domain}"
  echo "  Scheme：                    http"
  echo "  Forward Hostname / IP：     fetch-relay"
  echo "  Forward Port：              3210"
  echo
  echo "Advanced 配置："
  cat <<'EOF'
access_log off;
proxy_buffering off;
resolver 127.0.0.11 valid=30s ipv6=off;
resolver_timeout 5s;
EOF
  echo
  echo "SSL 标签页：为 ${domain} 申请证书，然后启用 Force SSL。"
  echo "确认 NPM 容器已接入 Docker 网络：${network:-fetch-relay-net}"
  echo "保存后验证：curl -i https://${domain}/"
  echo "预期：HTTP 404 和 {\"error\":\"Not found\"}"
}

update_service() {
  local source_dir
  source_dir="$(get_env SOURCE_DIR)"

  if [[ -z "${source_dir}" || ! -f "${source_dir}/deploy.sh" ]]; then
    echo "未找到项目源码目录，无法从菜单自动更新。"
    echo "请在项目目录执行：sudo bash deploy.sh"
    return
  fi

  echo "即将同步 GitHub 并更新服务，现有域名、白名单和密钥会保留。"
  exec bash "${source_dir}/deploy.sh"
}

uninstall_service() {
  if [[ ! -f "${INSTALL_DIR}/uninstall.sh" ]]; then
    echo "未找到卸载脚本，请先执行一次“同步项目并更新服务”。"
    return
  fi

  exec bash "${INSTALL_DIR}/uninstall.sh"
}

while true; do
  clear || true
  echo "Fetch Proxy 管理菜单"
  echo "安装目录：${INSTALL_DIR}"
  echo
  echo "1) 查看服务状态"
  echo "2) 查看最近日志"
  echo "3) 管理机场域名白名单"
  echo "4) 轮换中转密钥"
  echo "5) 修改中转域名"
  echo "6) 显示 MiSub 专属拉取代理 (Fetch Proxy)"
  echo "7) 查看 NPM Proxy Host 与 SSL 配置"
  echo "8) 同步 GitHub 并更新服务"
  echo "9) 卸载 Fetch Proxy"
  echo "0) 退出"
  echo
  read -r -p "请选择操作：" choice

  case "${choice}" in
    1) compose ps; pause ;;
    2) compose logs --tail=80 fetch-relay; pause ;;
    3) manage_allowed_hosts ;;
    4) rotate_secret; pause ;;
    5) change_domain; pause ;;
    6) show_prefix; pause ;;
    7) show_npm_setup; pause ;;
    8) update_service ;;
    9) uninstall_service ;;
    0) exit 0 ;;
    *) echo "无效选项。"; pause ;;
  esac
done
