#!/bin/bash
# OpenSSL Uninstall Script
# ENV VARS:ZAP_PATH APPS_DIR APP_OLD_VERSION
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"



#Parse the old version from APP_OLD_VERSION，获取 MAJOR_VERSION MINOR_VERSION
OLD_MAJOR_VERSION=$(version_major "${APP_OLD_VERSION}")
OLD_MINOR_VERSION=$(version_minor "${APP_OLD_VERSION}")
SHORT_VERSION="${OLD_MAJOR_VERSION}.${OLD_MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/openssl${SHORT_VERSION}"

INFO_FILE="${APP_PATH}/info.yaml"
INSTALL_DIR="$(resolve_install_dir "${INFO_FILE}" "${LINK_DIR}")"


echo "uninstall openssl ${SHORT_VERSION}  ${INSTALL_DIR}"

# remove ld.so.conf.d file if exists
if [ -f "/etc/ld.so.conf.d/zap-openssl-${OLD_MAJOR_VERSION}.conf" ]; then
    log_info "Removing /etc/ld.so.conf.d/zap-openssl-${OLD_MAJOR_VERSION}.conf"
    rm -f "/etc/ld.so.conf.d/zap-openssl-${OLD_MAJOR_VERSION}.conf"
    ldconfig >/dev/null 2>&1 || true
fi

# openssl must be installed under ${APPS_DIR}, otherwise it may be a system openssl, cannot uninstall
assert_under_apps_dir "${INSTALL_DIR}" "${APPS_DIR}" || exit 1
if [ "$(dirname "${INSTALL_DIR}")" != "${APPS_DIR}" ]; then
    log_error "Installation directory is not under ${APPS_DIR}, cannot uninstall"
    exit 1
fi


if command -v readelf >/dev/null 2>&1; then
    case "${OLD_MAJOR_VERSION}" in
        3) _so="libssl\.so\.3" ;;
        *) _so="libssl\.so\.${OLD_MAJOR_VERSION}\.[0-9]" ;;
    esac
    _dependents=""
    for _b in "${APPS_DIR}"/*/bin/* "${APPS_DIR}"/*/sbin/*; do
        [ -f "${_b}" ] || continue
        if readelf -d "${_b}" 2>/dev/null | grep -qE "${_so}"; then
            _dependents="${_dependents} ${_b}"
        fi
    done
    if [ -n "${_dependents}" ]; then
        log_warn "The following programs still link to openssl${SHORT_VERSION}, they will fail to start after removal:${_dependents}"
    fi
fi

if [ -d "${INSTALL_DIR}" ]; then
    rm -rf "${INSTALL_DIR}"
fi

echo "openssl ${SHORT_VERSION} uninstalled successfully"

