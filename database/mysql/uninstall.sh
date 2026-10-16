#!/bin/bash
# Combined uninstall script for MySQL / MariaDB (invoked by zap appstore;
# the version family is auto-detected). Both families install as mysql.service,
# share /etc/mysql/my.cnf, and use the common "mysql" credential domain (root / zapadm).
# ENV (injected by zapexec): APPS_DIR APP_VERSION MAJOR_VERSION MINOR_VERSION
#   APP_FAMILY ZAPCTL ZAP_PATH
# Option: BACKUP_DATA ("true" backs up then deletes; "false" deletes directly).
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh" 2>/dev/null || true
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { echo "[info] $*"; }
    log_warn()  { echo "[warn] $*"; }
    log_error() { echo "[error] $*" >&2; }
    log_ok()    { echo "[ok] $*"; }
fi

# Family is decided by APP_FAMILY from version_meta. Only when that is missing
# (older zapexec or missing meta) fall back to guessing from the major version
# with a warning, so uninstall still proceeds.
if [ -n "${APP_FAMILY:-}" ]; then
    FAMILY="${APP_FAMILY}"
else
    case "${MAJOR_VERSION:-}" in
        10|11|12) FAMILY="mariadb" ;;
        *) FAMILY="mysql" ;;
    esac
    log_warn "APP_FAMILY not injected; guessing family=${FAMILY} from major version (upgrade zapexec to use version_meta)"
fi

SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/${FAMILY}-${SHORT_VERSION}"
# tolerate early installs named by full version
if [ ! -d "${INSTALL_DIR}" ]; then
    LEGACY_DIR="${APPS_DIR}/${FAMILY}-${APP_VERSION}"
    if [ -d "${LEGACY_DIR}" ]; then
        INSTALL_DIR="${LEGACY_DIR}"
    fi
fi

# ── stop and disable the service ──
# Both families now run as mysql.service. Also stop/disable a legacy
# mariadb.service in case an older install is still present on the host.
log_info "stopping ${FAMILY} service"
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop mysql.service 2>/dev/null || true
    systemctl disable mysql.service 2>/dev/null || true
    systemctl stop mariadb.service 2>/dev/null || true
    systemctl disable mariadb.service 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    service mysql stop 2>/dev/null || true
    service mariadb stop 2>/dev/null || true
    chkconfig --del mysql 2>/dev/null || true
    chkconfig --del mariadb 2>/dev/null || true
fi
sleep 3

# ── back up data and config (skipped when BACKUP_DATA=false) ──
if [ "${BACKUP_DATA:-true}" = "true" ]; then
    BAK_DIR="/root/zap_bak/${FAMILY}"
    mkdir -p "${BAK_DIR}"
    if [ -d "${INSTALL_DIR}/data" ]; then
        cp -Rf "${INSTALL_DIR}/data" "${BAK_DIR}/${FAMILY}.$(date +%Y%m%d%H%M%S)"
    fi
    if [ -d "/etc/mysql" ]; then
        cp -Rf /etc/mysql "${BAK_DIR}/${FAMILY}.cnf.$(date +%Y%m%d%H%M%S)"
    fi
else
    log_info "skip data/config backup (BACKUP_DATA=false)"
fi

# ── remove symlinks and commands ──
if [ -L "/usr/local/mysql" ]; then
    rm -rf /usr/local/mysql
fi
if [ -L "/usr/local/mariadb" ]; then
    rm -rf /usr/local/mariadb
fi
rm -f /usr/local/bin/mysql /usr/local/bin/mysqldump /usr/local/bin/myisamchk \
      /usr/local/bin/mysqld_safe /usr/local/bin/mysqlcheck /usr/local/bin/mariadb \
      /usr/local/bin/mariadb-install-db

# ── remove the install dir (zap then cleans the APP_PATH metadata) ──
if [ -n "${INSTALL_DIR}" ] && [ -d "${INSTALL_DIR}" ]; then
    log_info "removing ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
fi

# ── remove service and config files ──
# drop legacy mariadb unit/init scripts too, in case they linger from an old install
rm -f /etc/init.d/mysql /etc/init.d/mariadb
rm -f /etc/systemd/system/mysql.service /etc/systemd/system/mariadb.service
rm -f /etc/mysql/my.cnf
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

# ── remove credentials (both families share the "mysql" credential domain) ──
log_info "removing ${FAMILY} credentials"
"${ZAPCTL:-/usr/local/bin/zapctl}" cred rm mysql root 2>/dev/null || true
"${ZAPCTL:-/usr/local/bin/zapctl}" cred rm mysql zapadm 2>/dev/null || true

log_ok "${FAMILY} uninstall successful"
