#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/xhpx7301/Fetch-Proxy.git"
SERVICE_DIR="${INSTALL_DIR:-/opt/fetch-relay}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash deploy.sh"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "未找到 Git，请先安装 git 后重试。"
  exit 1
fi

if [[ -d "${SCRIPT_DIR}/.git" ]]; then
  REPO_DIR="${SCRIPT_DIR}"
else
  REPO_DIR="${REPO_DIR:-/opt/fetch-proxy-source}"
  if [[ -e "${REPO_DIR}" && ! -d "${REPO_DIR}/.git" ]]; then
    echo "${REPO_DIR} 已存在但不是 Git 仓库，无法安全覆盖。"
    exit 1
  fi
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    echo "首次运行，正在下载 Fetch Proxy 项目..."
    git clone "${REPO_URL}" "${REPO_DIR}"
  fi
fi

echo "正在同步 GitHub 项目更新..."
if ! git -C "${REPO_DIR}" pull --ff-only; then
  echo "项目同步失败。请检查网络，或先处理本地 Git 修改后再重试。"
  exit 1
fi

if [[ -f "${SERVICE_DIR}/.env" ]]; then
  echo "检测到已有服务，将保留现有域名、白名单和中转密钥，只更新代码。"
  exec env SKIP_GIT_SYNC=1 bash "${REPO_DIR}/update.sh"
fi

echo "未检测到已有服务，将进入首次安装流程。"
exec bash "${REPO_DIR}/install.sh"
