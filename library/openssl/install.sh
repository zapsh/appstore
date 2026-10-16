#!/bin/bash
#=============================================================================
# OpenSSL Install Script
#
# ENV VARS:ZAP_PATH APPS_DIR PKG_PATH APP_PATH
#   APP_NAME APP_VERSION MAJOR_VERSION MINOR_VERSION BUILD_PATH CPU_NUM
#
# Override ENV VARS:
#   OPENSSL_MIRROR      mirrors + /openssl
#   OPENSSL_ENABLE_WEAK 1 | 0 only for OpenSSL 1.1.x,3.x has no such option
#                          --enable-weak-ssl-ciphers support only for 1.1.x
#   OPENSSL_EXTRA_CONFIG     ./config extra args,eg: no-asm threads
#=============================================================================
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 版本与安装目录 ─────────────────────────────────────────────────────────
APP_VERSION="${APP_VERSION:-1.1.1w}"
if [ -z "${MAJOR_VERSION:-}" ]; then MAJOR_VERSION="${APP_VERSION%%.*}"; fi
if [ -z "${MINOR_VERSION:-}" ]; then _ver_rest="${APP_VERSION#*.}"; MINOR_VERSION="${_ver_rest%%.*}"; fi
SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_PATH="${APPS_DIR}/openssl${SHORT_VERSION}"
OPENSSL_MIRROR="${OPENSSL_MIRROR:-$(pkg_mirror)/openssl}"
OPENSSL_ENABLE_WEAK="${OPENSSL_ENABLE_WEAK:-1}"
OPENSSL_EXTRA_CONFIG="${OPENSSL_EXTRA_CONFIG:-}"

log_info "Installing OpenSSL ${APP_VERSION} -> ${INSTALL_PATH}"

# ──  perl check and install ───────────────────────────────────────────────────────
_ensure_perl() {
    if ! command -v perl >/dev/null 2>&1; then
        log_warn "缺少 perl(OpenSSL 编译必需),尝试自动安装 ..."
        if is_os ubuntu debian; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y perl >/dev/null 2>&1 || true
        elif is_os alpine; then
            apk add --no-cache perl >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y perl >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y perl >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v perl >/dev/null 2>&1; then
        log_error "required perl not found,please install it first"
        return 1
    fi
    # OpenSSL 3.x 的 Configure 需要 Text::Template(1.1.x 不需要)
    if [ "${MAJOR_VERSION}" != "1" ] && ! perl -MText::Template -e 1 >/dev/null 2>&1; then
        log_warn "The Perl module "Text::Template" is missing (required by OpenSSL 3.x Configure), attempting to automatically install..."
        if is_os ubuntu debian; then
            apt-get install -y libtext-template-perl >/dev/null 2>&1 || true
        elif is_os alpine; then
            apk add --no-cache perl-text-template >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y perl-Text-Template >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y perl-Text-Template >/dev/null 2>&1 || true
        fi
        if ! perl -MText::Template -e 1 >/dev/null 2>&1; then
            log_warn "The installation of the Text::Template module failed, please install it manually and try again."
        fi
    fi
    return 0
}
_ensure_perl || exit 1

# ── download and extract ─────────────────────────────────────────────────────
cd "${PKG_PATH}"
SRC_TGZ="openssl-${APP_VERSION}.tar.gz"
if [ ! -f "${SRC_TGZ}" ]; then
    log_info "downloading ${OPENSSL_MIRROR}/${SRC_TGZ}"
    fetch_file "${OPENSSL_MIRROR}/${SRC_TGZ}" "${SRC_TGZ}" || exit 1
fi

# ── BUILD_PATH check ────────────────────────────
if [[ "${BUILD_PATH}" != "${ZAP_PATH}/data/appstore/runs/"*"/build" ]]; then
    log_error "BUILD_PATH exception (${BUILD_PATH}), access denied for cleaning"
    exit 1
fi
log_info "Clean BUILD_PATH: ${BUILD_PATH}"
rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"

log_info "Extracting ${SRC_TGZ}"
extract_archive "${SRC_TGZ}" "${BUILD_PATH}" || exit 1
SRC_DIR="${BUILD_PATH}/openssl-${APP_VERSION}"
if [ ! -f "${SRC_DIR}/Configure" ]; then
    log_error "Extraction failed: ${SRC_DIR}/Configure not found, please check the archive content"
    exit 1
fi
cd "${SRC_DIR}"

# ── configure ──────────────────────────────────────────────────────────────
# configure args with rpath and prefix
config_args=(
    "-Wl,-rpath=${INSTALL_PATH}/lib"
    "--prefix=${INSTALL_PATH}"
    "--openssldir=${INSTALL_PATH}/ssl"
    "--libdir=lib"
    shared
    -fPIC
)
# 1.1.x enable weak ciphers
if [ "${MAJOR_VERSION}" = "1" ] && [ "${OPENSSL_ENABLE_WEAK}" = "1" ]; then
    config_args+=(enable-weak-ssl-ciphers)
fi
# extra config options (e.g., no-asm / threads)
if [ -n "${OPENSSL_EXTRA_CONFIG}" ]; then
    read -r -a _extra <<< "${OPENSSL_EXTRA_CONFIG}"
    config_args+=("${_extra[@]}")
fi

log_info "configure OpenSSL-${APP_VERSION} ..."
./config "${config_args[@]}"
log_ok "configure completed, starting compilation (parallel ${CPU_NUM:-auto}, failure automatically falls back to serial)"

# make install
log_info "make -j${CPU_NUM:-auto} && make install"
MakeInstall

if [ ! -x "${INSTALL_PATH}/bin/openssl" ]; then
    log_error "MakeInstall failed"
    exit 1
fi
log_ok "Compilation completed: ${INSTALL_PATH}"

# ── ssl data(openssl.cnf / certs / private)───────────────────────
ensure_dir "${INSTALL_PATH}/ssl"
if [ ! -f "${INSTALL_PATH}/ssl/openssl.cnf" ]; then
    if [ -f "${SRC_DIR}/apps/openssl.cnf" ]; then
        cp -f "${SRC_DIR}/apps/openssl.cnf" "${INSTALL_PATH}/ssl/openssl.cnf"
    elif [ -f "${SRC_DIR}/openssl.cnf" ]; then
        cp -f "${SRC_DIR}/openssl.cnf" "${INSTALL_PATH}/ssl/openssl.cnf"
    else
        log_warn "The openssl.cnf template was not found. Please manually place it in ${INSTALL_PATH}/ssl/."
    fi
fi



# with php:
#   export PKG_CONFIG_PATH=<prefix>/lib/pkgconfig  (PHP >= 8.1 pkg-config)
#   ./configure --with-openssl=<prefix>            (PHP 7.x with-dir)
#   pkg-config --cflags --libs openssl             (once,set PKG_CONFIG_PATH)

# register ld.so.conf
# if [ "${MAJOR_VERSION}" != "1" ]; then
#     ensure_dir /etc/ld.so.conf.d
#     printf '%s\n' "${INSTALL_PATH}/lib" > "/etc/ld.so.conf.d/zap-openssl-${MAJOR_VERSION}.conf"
#     ldconfig >/dev/null 2>&1 || log_warn "ldconfig failed, please execute ldconfig manually"
# fi


# ── version ───────────────────────────────────────────────────────────────
log_info "openssl version: $("${INSTALL_PATH}/bin/openssl" version)"
log_info "openssl data directory: $("${INSTALL_PATH}/bin/openssl" version -d)"


# register instance info
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<YAML
instance: openssl${SHORT_VERSION}
install_dir: ${INSTALL_PATH}
version: ${APP_VERSION}
config_file: ${INSTALL_PATH}/ssl/openssl.cnf
config_files: 
  - path: ${INSTALL_PATH}/ssl/openssl.cnf
    label: openssl.cnf
  - path: ${INSTALL_PATH}/lib/pkgconfig/openssl.pc
    label: openssl.pc
expose: none
tags:
  - library
  - crypto
bin: ${INSTALL_PATH}/bin/openssl
pkg-config: ${INSTALL_PATH}/lib/pkgconfig/openssl.pc
YAML

log_info "instance info registered: ${APP_PATH}/info.yaml"

log_ok "openssl ${APP_VERSION} installation completed successfully"
