#!/bin/bash
# Adminer upgrade script (invoked by the zap appstore)
#
# Injected environment variables (provided by zapexec): ZAP_PATH APPS_DIR APP_PATH BUILD_PATH ZAP_DATA_PATH
#                                                       APP_VERSION MAJOR_VERSION MINOR_VERSION APP_OLD_VERSION
# Options (app.yaml options.upgrade):
#   PHP_VERSION   PHP to use after upgrade (auto = chosen by zapd on each request)
#
# Strategy: keep config.inc.php (blowfish_secret and server settings), replace the program files;
#           the /usr/local/apps/adminer symlink switches to the new version directory, so the
#           access entry point stays unchanged.
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="Adminer"
VERSION="${APP_VERSION:-}"
[ -n "${VERSION}" ] || { log_error "Missing APP_VERSION, cannot upgrade"; exit 1; }

OLD_VERSION="${APP_OLD_VERSION:-unknown}"

INSTALL_DIR="${APPS_DIR}/adminer"
LINK_DIR="${APPS_DIR}/adminer"
LOG_DIR="${ZAP_DATA_PATH}/logs"

log_info "Preparing to upgrade ${APP_TITLE}: ${OLD_VERSION} -> ${VERSION}"

# ── locate the old install dir & config ────────────────────────────────────
OLD_DIR=""
INFO_FILE="${APP_PATH}/info.yaml"
if [ -f "${INFO_FILE}" ]; then
    OLD_DIR="$(grep -m1 '^install_dir:' "${INFO_FILE}" 2>/dev/null | sed 's/^install_dir:[[:space:]]*//' || true)"
fi
[ -n "${OLD_DIR}" ] || OLD_DIR="${LINK_DIR}"


# ── download & extract the new version ────────────────────────────────────────
ARCHIVE="adminer-${VERSION}.php"
URL="https://github.com/vrana/adminer/releases/download/v${VERSION}/${ARCHIVE}"

rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"
download_file "${URL}" "${BUILD_PATH}/${ARCHIVE}"

SRC_DIR="${BUILD_PATH}/${ARCHIVE}"
[ -f "${SRC_DIR}" ] || { log_error "Unexpected extraction result: source file not found: ${SRC_DIR}"; exit 1; }

# ── deploy the new version ──────────────────────────────────────────────
rm -rf "${INSTALL_DIR}"
ensure_dir "${INSTALL_DIR}"
mv "${SRC_DIR}" "${INSTALL_DIR}/adminer.php"
log_ok "Program deployed to: ${INSTALL_DIR}/adminer.php"



RUN_USER="www"

chown -R "${RUN_USER}" "${INSTALL_DIR}" 2>/dev/null || log_warn "Failed to change owner (user ${RUN_USER})"

# ── update registered info ────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${HOST_IP}" ] || HOST_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
[ -n "${HOST_IP}" ] || HOST_IP="127.0.0.1"
PORT_SHOW="$(grep -m1 '^port:' "${INFO_FILE}" 2>/dev/null | sed 's/^port:[[:space:]]*//' || true)"
[ -n "${PORT_SHOW}" ] || PORT_SHOW=8888

ensure_dir "${APP_PATH}"
cat >"${INFO_FILE}" <<EOF
instance: adminer
install_dir: ${INSTALL_DIR}
config_file: ${INSTALL_DIR}/adminer.php
web_url: http://${HOST_IP}:${PORT_SHOW}/webapps/adminer/
expose: none
port: ${PORT_SHOW}
tags:
  - webapp
  - mysql
  - sqlite
  - mariadb
  - postgresql
EOF

log_ok "${APP_TITLE} ${VERSION} upgraded successfully"
log_info "Access URL: http://${HOST_IP}:${PORT_SHOW}/webapps/adminer/"
