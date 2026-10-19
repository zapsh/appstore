#!/bin/bash
# Adminer install script (invoked by the zap appstore)
#
# Injected environment variables (provided by zapexec):
#   ZAP_PATH APPS_DIR PKG_PATH APP_PATH BUILD_PATH ZAP_DATA_PATH
#   APP_VERSION MAJOR_VERSION MINOR_VERSION CPU_NUM
# Options (app.yaml options.install, injected as same-named env vars):
#   PORT          access port (default 8888)
#   PHP_VERSION   runtime PHP (auto = auto-pick the highest installed version)
#   DB_HOST       managed database host (default 127.0.0.1)
#   DB_PORT       database port (default 3306)
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="Adminer"

INSTALL_DIR="${APPS_DIR}/adminer"

LOG_DIR="${ZAP_DATA_PATH}/logs"

log_info "Preparing to install ${APP_TITLE}"

# ── download & extract ──────────────────────────────────────────────
# 保留官方文件名 adminer.php（不改名 index.php）：文件名自解释，且升级时
# 直接覆盖同名文件即可；zapd 的 /webapps/adminer 路由以 adminer.php 作为默认入口。
ARCHIVE="adminer-${APP_VERSION}.php"
URL="https://github.com/vrana/adminer/releases/download/v${APP_VERSION}/${ARCHIVE}"

rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"
download_file "${URL}" "${BUILD_PATH}/${ARCHIVE}"

SRC_DIR="${BUILD_PATH}/${ARCHIVE}"
if [ ! -f "${SRC_DIR}" ]; then
   log_error "Unexpected extraction result: source file not found: ${SRC_DIR}"
    exit 1
fi

ensure_dir "${INSTALL_DIR}"
mv "${SRC_DIR}" "${INSTALL_DIR}/adminer.php"
log_ok "Program deployed to: ${INSTALL_DIR}/adminer.php"

# ── runtime user & permissions ──────────────────────────────────────────
RUN_USER="www"
chown -R "${RUN_USER}" "${INSTALL_DIR}" 2>/dev/null || log_warn "Failed to change owner (user ${RUN_USER}); please verify permissions manually"



# ── register instance info ────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${HOST_IP}" ] || HOST_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
[ -n "${HOST_IP}" ] || HOST_IP="127.0.0.1"

ensure_dir "${APP_PATH}"
cat >"${APP_PATH}/info.yaml" <<EOF
instance: adminer
install_dir: ${INSTALL_DIR}
config_file: ${INSTALL_DIR}/adminer.php
web_url: http://${HOST_IP}:2663/webapps/adminer/
expose: none
tags:
  - webapp
  - mysql
  - sqlite
  - mariadb
  - postgresql
EOF

log_ok "${APP_TITLE} ${APP_VERSION} installed successfully"
log_info "Access URL: http://${HOST_IP}:2663/webapps/adminer/ (keep the trailing slash; log in with an existing MySQL / MariaDB account)"
