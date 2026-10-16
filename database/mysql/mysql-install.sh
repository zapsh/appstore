#!/bin/bash
# MySQL Install Script
# ENV: ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION (MAJOR_VERSION/MINOR_VERSION set by caller)
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

MYSQL_SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/mysql-${MYSQL_SHORT_VERSION}"
MYSQL_LINK="/usr/local/mysql"

# ── guard: installed / half-installed check ──
# The panel registers the app only after this script exits 0. A mid-install
# failure leaves no info.yaml, so a link/dir without it is a half-done install
# to clean up; only bail when a data dir with real data is already present.
if app_install_complete; then
    log_error "mysql already installed (info.yaml present); uninstall it first"
    exit 1
fi
if [ -L "${MYSQL_LINK}" ]; then
    RESOLVED="$(readlink -f "${MYSQL_LINK}" 2>/dev/null || true)"
    if [ -z "${RESOLVED}" ] || [ ! -d "${RESOLVED}" ]; then
        log_warn "stale symlink ${MYSQL_LINK} -> missing target; removing"
        remove_path "${MYSQL_LINK}"
    elif db_data_initialized "${RESOLVED}/data"; then
        log_error "${MYSQL_LINK} -> ${RESOLVED} data dir already initialized (may hold real data); not auto-cleaning"
        log_error "back up the data, then remove ${RESOLVED} and ${MYSQL_LINK} before reinstalling"
        exit 1
    elif path_under "${RESOLVED}" "${APPS_DIR}"; then
        log_warn "leftover install found (data not initialized); cleaning up and continuing"
        service_stop_disable mysql.service || true
        remove_path "${MYSQL_LINK}"
        remove_path "${RESOLVED}"
        remove_path /etc/mysql
        remove_path /etc/init.d/mysql
        remove_path /etc/systemd/system/mysql.service
        if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
    else
        log_error "${MYSQL_LINK} -> ${RESOLVED} is outside APPS_DIR; not auto-cleaning, remove it manually"
        exit 1
    fi
elif [ -e "${MYSQL_LINK}" ]; then
    log_error "${MYSQL_LINK} exists and is not our symlink (possibly a manual install); remove it manually before retrying"
    exit 1
elif [ -d "${INSTALL_DIR}" ]; then
    if db_data_initialized "${INSTALL_DIR}/data"; then
        log_error "${INSTALL_DIR} data dir already initialized (may hold real data); not auto-cleaning, remove it manually"
        exit 1
    fi
    log_warn "leftover install dir ${INSTALL_DIR} (data not initialized); cleaning up and continuing"
    remove_path "${INSTALL_DIR}"
fi

# ── runtime dependencies ──
# mysqld needs libaio.so.1; the mysql client needs libncurses.so.6.
# On Ubuntu 24.04+/Debian 13+ these are renamed (libaio.so.1t64 / libncursesw.so.6),
# so fall back to a compat symlink when the package is unavailable.
PKG_MGR="$(pkg_manager || true)"
case "${PKG_MGR}" in
    apt)
        apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed (continuing)"
        if ! have_lib libaio.so.1; then
            pkg_install_any apt libaio1t64 libaio1 \
                || log_warn "libaio package missing; trying compat symlink"
            link_lib_compat libaio.so.1 libaio.so.1t64 \
                || { log_error "missing libaio.so.1 (required by mysqld). Install libaio1t64 (Ubuntu 24.04+/Debian 13+) or libaio1 and retry"; exit 1; }
        fi
        # client loads libncurses.so.6; symlink from present libncursesw.so.6 if the package is unavailable
        have_lib 'libncurses.so.*' \
            || pkg_install_any apt libncurses6 libncurses5 \
            || link_lib_compat libncurses.so.6 libncursesw.so.6 \
            || { log_error "missing libncurses (required by mysql client). Install libncurses6 (or libncurses5 on older systems) and retry"; exit 1; }

        pkg_install_any apt numactl

        ;;
    dnf | yum)
        have_lib libaio.so.1 \
            || pkg_install_any "${PKG_MGR}" libaio \
            || { log_error "missing libaio.so.1 (required by mysqld). Install libaio and retry"; exit 1; }
        have_lib 'libncurses.so.*' \
            || pkg_install_any "${PKG_MGR}" ncurses-libs ncurses-compat-libs \
            || { log_error "missing libncurses (required by mysql client). Install ncurses-libs and retry"; exit 1; }

        have_lib 'libnuma.so.*' \
            || pkg_install_any "${PKG_MGR}" numactl numactl-libs
        ;;
    *)
        log_warn "unknown package manager; ensure libaio.so.1 and libncurses are installed"
        ;;
esac

# ── system user ──
ensure_user mysql mysql || { log_error "failed to create mysql user/group"; exit 1; }
ensure_dir "/var/log/mysql" || log_warn "failed to create dir: /var/log/mysql"
ensure_dir "/var/run/mysqld" || log_warn "failed to create dir: /var/run/mysqld"
chown -R mysql:mysql /var/log/mysql /var/run/mysqld

# ── pick official binary matching host glibc ──
# Only MySQL 8.0+ is supported (5.7 and earlier removed).
if [ "${MAJOR_VERSION}" -lt 8 ]; then
    log_error "MySQL ${APP_VERSION} is no longer supported; 5.7 and earlier removed, use 8.0+"
    exit 1
fi
# Official binaries are built against a glibc version:
#   glibc >= 2.28 : use the glibc2.28 build (works for 8.4/9.x and 8.0)
#   glibc 2.17~2.27: only 8.0 ships a glibc2.17 build (8.0.46)
#   glibc <  2.17 : no usable official binary
GLIBC_VERSION=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
GLIBC_MAJOR="${GLIBC_VERSION%%.*}"
GLIBC_MINOR="${GLIBC_VERSION#*.}"
GLIBC_MINOR="${GLIBC_MINOR%%.*}"
case "${GLIBC_MAJOR}${GLIBC_MINOR}" in
    '' | *[!0-9]*)
        log_error "could not detect system glibc version ('${GLIBC_VERSION:-}')"
        exit 1 ;;
esac

MYSQL_MINOR="${APP_VERSION#*.}"
MYSQL_MINOR="${MYSQL_MINOR%%.*}"
case "${MYSQL_MINOR}" in
    '' | *[!0-9]*)
        log_error "failed to parse MySQL minor version: ${APP_VERSION}"
        exit 1 ;;
esac

if [ "${GLIBC_MAJOR}" -gt 2 ] \
    || { [ "${GLIBC_MAJOR}" -eq 2 ] && [ "${GLIBC_MINOR}" -ge 28 ]; }; then
    GLIBC_PKG="2.28"
elif [ "${GLIBC_MAJOR}" -eq 2 ] && [ "${GLIBC_MINOR}" -ge 17 ]; then
    if [ "${MAJOR_VERSION}" -ne 8 ] || [ "${MYSQL_MINOR}" -ne 0 ]; then
        log_error "system glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} only supports MySQL 8.0 series (8.0.46 available)"
        log_error "MySQL ${APP_VERSION} needs glibc >= 2.28 — pick 8.0.46 or upgrade (Debian 10+/Ubuntu 20.04+/RHEL 8+)"
        exit 1
    fi
    GLIBC_PKG="2.17"
else
    log_error "system glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} too old; MySQL official binaries need glibc >= 2.17"
    exit 1
fi
if [ "${MAJOR_VERSION}" -eq 8 ] && [ "${MYSQL_MINOR}" -eq 0 ]; then
    # 8.0 always uses the glibc2.17 build so one binary runs on both old and new hosts
    GLIBC_PKG="2.17"
fi

log_info "system glibc ${GLIBC_MAJOR}.${GLIBC_MINOR}; using glibc${GLIBC_PKG} official package"
PKG_TARBALL="mysql-${APP_VERSION}-linux-glibc${GLIBC_PKG}-x86_64-minimal.tar.xz"
PKG_EXTRACT_DIR="mysql-${APP_VERSION}-linux-glibc${GLIBC_PKG}-x86_64-minimal"

cd "${PKG_PATH}"
if [ -d "${INSTALL_DIR}" ]; then
    log_info "reusing existing install dir: ${INSTALL_DIR} (skip download/extract)"
else
    # drop a half-extracted dir left by a failed tar before retrying
    remove_path "${APPS_DIR}/${PKG_EXTRACT_DIR}"
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_info "downloading mysql: ${PKG_TARBALL}"
        download_file "$(pkg_mirror)/mysql/${PKG_TARBALL}" "${PKG_TARBALL}" || true
    fi
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_error "mysql download failed: ${PKG_TARBALL} not found"
        exit 1
    fi
    log_info "extracting mysql: ${PKG_TARBALL} -> ${APPS_DIR}"
    tar xf "${PKG_TARBALL}" -C "${APPS_DIR}"

    if [ -d "${APPS_DIR}/${PKG_EXTRACT_DIR}" ] && [ ! -d "${INSTALL_DIR}" ]; then
        mv "${APPS_DIR}/${PKG_EXTRACT_DIR}" "${INSTALL_DIR}"
    fi
    if [ ! -d "${INSTALL_DIR}" ]; then
        log_error "error unpacking mysql: ${INSTALL_DIR} not found"
        exit 1
    fi
fi

if [ "${SET_DEFAULT:-false}" = "true" ]; then
    log_info "setting mysql as default: /usr/local/bin/mysql"
    ln -sf "${INSTALL_DIR}/bin/mysql" /usr/local/bin/mysql
    ln -sf "${INSTALL_DIR}/bin/mysqldump" /usr/local/bin/mysqldump
    ln -sf "${INSTALL_DIR}/bin/myisamchk" /usr/local/bin/myisamchk
    ln -sf "${INSTALL_DIR}/bin/mysqlcheck" /usr/local/bin/mysqlcheck
fi

if [ ! -d "/usr/local/mysql" ]; then
    log_info "creating symlink: /usr/local/mysql -> ${INSTALL_DIR}"
    ln -sf "${INSTALL_DIR}" /usr/local/mysql
fi

if [ -f "/etc/mysql/my.cnf" ]; then
    log_info "backing up /etc/mysql to /etc/mysql.bak.$(date +%Y%m%d%H%M%S)"
    mv /etc/mysql "/etc/mysql.bak.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p /etc/mysql

cd "${INSTALL_DIR}"
mkdir -p mysql-files
chmod 750 mysql-files
# only runtime-writable dirs become mysql-owned; bin/lib stay root (least privilege + faster)
chown -R mysql:mysql "${INSTALL_DIR}/mysql-files"
chown -R mysql:mysql /var/log/mysql /var/run/mysqld

# init data dir (no password); set root password afterwards
DATA_DIR="${INSTALL_DIR}/data"
if db_data_initialized "${DATA_DIR}"; then
    log_info "data dir already initialized; skipping mysqld --initialize-insecure (rerun won't re-init or overwrite)"
    DATA_REUSED=1
else
    remove_path "${DATA_DIR}"
    bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=/usr/local/mysql/data --user=mysql
    DATA_REUSED=0
fi
# ensure data dir owned by mysql (fresh init or reused)
chown -R mysql:mysql "${DATA_DIR}"

# innodb buffer pool = 50% of RAM, clamped 128M..8G
MEM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
BP_MB=$(( MEM_MB / 2 ))
[ "${BP_MB}" -lt 128 ] && BP_MB=128
[ "${BP_MB}" -gt 8192 ] && BP_MB=8192
INNODB_BP="${BP_MB}M"

cat > /etc/mysql/my.cnf <<EOF
[client]
port            = 3306
socket          = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4

[mysqld]
user            = mysql
port            = 3306
socket          = /tmp/mysql.sock
basedir        = /usr/local/mysql
datadir         = /usr/local/mysql/data
log-error       = /var/log/mysql/error.log
pid-file        = /var/run/mysqld/mysqld.pid
skip-external-locking
skip-name-resolve
# listen on localhost only; matches info.yaml expose
bind-address     = 127.0.0.1
# server-id required when binlog is enabled
server-id        = 1

max_allowed_packet              = 32M


slow_query_log_file = /var/log/mysql/mysql-slow.log
slow_query_log      = 1
long_query_time     = 1


character-set-server = utf8mb4
collation-server     = utf8mb4_0900_ai_ci
log_timestamps       = SYSTEM


# dynamic value computed above (INNODB_BP)
innodb_buffer_pool_size = ${INNODB_BP}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 1

max_connections         = 500
max_connect_errors       = 1000
thread_cache_size = 50

log_bin         = mysql-bin
binlog_format   = ROW
binlog_row_image = FULL
# 7 days
binlog_expire_logs_seconds = 604800

EOF

# ── system auto start ──
log_info "setting up mysql service, enable on boot"
if [ ! -d /etc/init.d ]; then
    cp support-files/mysql.server /etc/init.d/mysql
    chmod +x /etc/init.d/mysql
fi
if command -v systemctl >/dev/null 2>&1; then
    cp -f "${PKG_PATH}/mysql.service" /etc/systemd/system/mysql.service
    systemctl daemon-reload
    systemctl enable mysql.service
    systemctl start mysql.service
elif command -v chkconfig >/dev/null 2>&1; then
    chkconfig --add mysql
    chkconfig mysql on
    service mysql start
fi
log_ok "mysql service setup done"

# ── credentials (root / zapadm) ──
# passwords are managed by the credential store (/etc/zap/credentials/mysql_<user>.cred, 0400)
get_or_gen_cred() {
    local user="$1"
    if ! "${ZAPCTL}" cred exists mysql "${user}" >/dev/null 2>&1; then
        log_info "generating and storing mysql/${user} credential" >&2
        "${ZAPCTL}" cred gen mysql "${user}" >/dev/null \
            || { log_error "failed to generate mysql/${user} credential" >&2; return 1; }
    fi
    local pass
    pass="$("${ZAPCTL}" cred show mysql "${user}")" \
        || { log_error "failed to read mysql/${user} credential" >&2; return 1; }
    if [ -z "${pass}" ]; then
        log_error "mysql/${user} credential is empty" >&2
        return 1
    fi
    printf '%s' "${pass}"
}
MYSQL_ROOT_PASSWORD="$(get_or_gen_cred root)" || exit 1
ZAPADM_PASSWORD="$(get_or_gen_cred zapadm)" || exit 1

# pass creds via a 0600 temp file (avoids plaintext on cmdline / "Using a password" warnings)
ROOT_CNF="$(mktemp /tmp/mysql-root.XXXXXX.cnf)"
trap 'rm -f "${ROOT_CNF:-}"' EXIT
printf '[client]\nuser = root\npassword = %s\n' "${MYSQL_ROOT_PASSWORD}" > "${ROOT_CNF}"

# wait up to 300s; first InnoDB init can exceed 60s on slow disks.
# A reused data dir has a passworded root, so probe with creds.
log_info "waiting for mysqld ready (max 300s)"
MYSQLD_READY=0
for _ in $(seq 1 300); do
    if [ "${DATA_REUSED}" = "1" ]; then
        if bin/mysqladmin --defaults-extra-file="${ROOT_CNF}" status >/dev/null 2>&1; then
            MYSQLD_READY=1
            break
        fi
    else
        if bin/mysqladmin -u root status >/dev/null 2>&1; then
            MYSQLD_READY=1
            break
        fi
    fi
    sleep 1
done
if [ "${MYSQLD_READY}" -ne 1 ]; then
    log_error "mysqld not ready within 300s; check /var/log/mysql/error.log"
    exit 1
fi

log_info "mysqld ready; setting root password"
if [ "${DATA_REUSED}" != "1" ]; then
    bin/mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
SQL
fi

log_info "creating zapadm user"
bin/mysql --defaults-extra-file="${ROOT_CNF}" <<SQL
CREATE USER IF NOT EXISTS 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
ALTER USER 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'zapadm'@'localhost' WITH GRANT OPTION;
DELETE FROM mysql.user WHERE User = '';
FLUSH PRIVILEGES;
SQL

EMPTY_PW_USERS="$(bin/mysql --defaults-extra-file="${ROOT_CNF}" -N -B -e \
    "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE authentication_string = '' AND plugin IN ('mysql_native_password','caching_sha2_password') AND account_locked = 'N';")" \
    || { log_error "failed to query empty-password accounts"; exit 1; }
if [ -n "${EMPTY_PW_USERS}" ]; then
    log_error "empty-password accounts still exist; handle manually: ${EMPTY_PW_USERS}"
    exit 1
fi

log_info "checking root empty-password login"
if bin/mysql -u root -e "SELECT 1" </dev/null >/dev/null 2>&1; then
    log_error "root still loginable with empty password; hardening failed"
    exit 1
fi

# restart mysql
log_info "restarting mysql"
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart mysql.service
elif command -v service >/dev/null 2>&1; then
    service mysql restart
fi
log_info "mysql restart done"

log_info "writing mysql info.yaml to ${APP_PATH}/info.yaml"
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: mysql
instance: mysql-${MYSQL_SHORT_VERSION}
install_dir: ${INSTALL_DIR}
version: ${APP_VERSION}
config_file: /etc/mysql/my.cnf
pid_file: /var/run/mysqld/mysqld.pid
log_files:
  - /var/log/mysql/error.log
  - /var/log/mysql/mysql-slow.log
expose:
  - unix:/tmp/mysql.sock
  - tcp:127.0.0.1:3306
tags:
  - database
  - sql
EOF

echo "mysql install successful"
