#!/bin/bash
# Adminer uninstall script (invoked by the zap appstore)
#
# Injected environment variables (provided by zapexec): ZAP_PATH APPS_DIR APP_PATH APP_VERSION
#                                                       MAJOR_VERSION MINOR_VERSION
#
# Safety policy (core principle: never accidentally delete other directories)
#   1. The install dir always follows install_dir recorded in info.yaml; the symlink is only a fallback;
#   2. The target must be a DIRECT child of APPS_DIR (/usr/local/apps);
#   3. Empty value / root path / APPS_DIR itself / out-of-bounds path -> all rejected for deletion;
#   4. Re-verify state once more before deleting; abort immediately if any check fails.
#
# The shared helpers normalize_dir / yaml_value / assert_under_apps_dir
# all come from ${ZAP_PATH}/scripts/zap/bash_utils.sh and can be reused by other app packages.
#
# Note: only the program directory and symlink are removed; database data is never touched.
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="Adminer"
LINK_DIR="${APPS_DIR}/adminer"
INFO_FILE="${APP_PATH}/info.yaml"

# ── main flow ──────────────────────────────────────────────────

# Install dir: info.yaml registration first, symlink target second (shared helper, see bash_utils.sh)
INSTALL_DIR="$(resolve_install_dir "${INFO_FILE}" "${LINK_DIR}")"

if [ -z "${INSTALL_DIR}" ]; then
    log_error "Could not determine the install directory (info.yaml missing and symlink absent); aborting uninstall"
    exit 1
fi

log_info "Preparing to uninstall ${APP_TITLE} (install dir ${INSTALL_DIR})"

# Directory already gone: just clean up the stale symlink and finish normally (idempotent)
if [ ! -d "${INSTALL_DIR}" ] && [ ! -L "${INSTALL_DIR}" ]; then
    log_warn "Install directory does not exist (may have been cleaned already): ${INSTALL_DIR}"
    if [ -L "${LINK_DIR}" ]; then
        rm -f "${LINK_DIR}"
        log_ok "Removed the stale symlink: ${LINK_DIR}"
    fi
    log_ok "${APP_TITLE} uninstalled successfully"
    exit 0
fi

# Pre-delete safety check: must be under APPS_DIR and a direct child of it
assert_under_apps_dir "${INSTALL_DIR}" "${APPS_DIR}" || exit 1

# Remove the symlink
if [ -L "${LINK_DIR}" ]; then
    rm -f "${LINK_DIR}"
    log_ok "Removed the symlink: ${LINK_DIR}"
fi

# Final check before deletion
[ -d "${INSTALL_DIR}" ] || {
    log_error "Directory state changed, aborting deletion: ${INSTALL_DIR}"
    exit 1
}
rm -rf "${INSTALL_DIR}"
log_ok "Removed the install directory: ${INSTALL_DIR}"

log_ok "${APP_TITLE} uninstalled successfully"
