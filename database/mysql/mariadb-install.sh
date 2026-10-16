#!/bin/bash
# MariaDB Install Script
# ENV: ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION (MAJOR_VERSION/MINOR_VERSION set by caller)
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"


MYSQL_SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/mariadb-${MYSQL_SHORT_VERSION}"

MYSQL_LINK="/usr/local/mysql"

# ── guard: installed / half-installed check ──
# Same as mysql: the panel registers the app only after this script exits 0.
# A mid-install failure leaves no info.yaml, so clean up a link/dir without it;
# only bail when a data dir with real data is already present.
if app_install_complete; then
    log_error "mariadb already installed (info.yaml present); uninstall it first"
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
    log_error "${MYSQL_LINK} exists and is not our symlink (possibly a manual MySQL/MariaDB install); remove it manually before retrying"
    exit 1
elif [ -d "${INSTALL_DIR}" ]; then
    if db_data_initialized "${INSTALL_DIR}/data"; then
        log_error "${INSTALL_DIR} data dir already initialized (may hold real data); not auto-cleaning, remove it manually"
        exit 1
    fi
    log_warn "leftover install dir ${INSTALL_DIR} (data not initialized); cleaning up and continuing"
    remove_path "${INSTALL_DIR}"
fi

# ── system user ──
if ! id mysql >/dev/null 2>&1; then
    ensure_user mysql mysql
fi

# ── runtime dependencies ──
# mariadbd needs libaio.so.1; the client needs libncurses.so.6.
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
                || { log_error "missing libaio.so.1 (required by mariadbd). Install libaio1t64 (Ubuntu 24.04+/Debian 13+) or libaio1 and retry"; exit 1; }
        fi
        # client loads libncurses.so.6; symlink from present libncursesw.so.6 if the package is unavailable
        have_lib 'libncurses.so.*' \
            || pkg_install_any apt libncurses6 libncurses5 \
            || link_lib_compat libncurses.so.6 libncursesw.so.6 \
            || { log_error "missing libncurses (required by mariadb client). Install libncurses6 (or libncurses5 on older systems) and retry"; exit 1; }
        ;;
    dnf | yum)
        have_lib libaio.so.1 \
            || pkg_install_any "${PKG_MGR}" libaio \
            || { log_error "missing libaio.so.1 (required by mariadbd). Install libaio and retry"; exit 1; }
        have_lib 'libncurses.so.*' \
            || pkg_install_any "${PKG_MGR}" ncurses-libs ncurses-compat-libs \
            || { log_error "missing libncurses (required by mariadb client). Install ncurses-libs and retry"; exit 1; }
        pkg_install_any "${PKG_MGR}" numactl-libs || log_warn "numactl-libs install failed (optional; NUMA pinning will be skipped)"
        ;;
    *)
        log_warn "unknown package manager; ensure libaio.so.1 and libncurses are installed"
        ;;
esac

mkdir -p /var/log/mysql /var/run/mysqld
chown -R mysql:mysql /var/log/mysql /var/run/mysqld

# ── extract binary tarball ──
PKG_TARBALL="mariadb-${APP_VERSION}-linux-systemd-x86_64.tar.gz"
cd "${PKG_PATH}"
if [ -d "${INSTALL_DIR}" ]; then
    log_info "reusing existing install dir: ${INSTALL_DIR} (skip download/extract)"
else
    # drop a half-extracted dir left by a failed tar before retrying
    remove_path "${APPS_DIR}/mariadb-${APP_VERSION}-linux-systemd-x86_64"
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_info "downloading mariadb: ${PKG_TARBALL}"
        download_file "$(pkg_mirror)/mariadb/${PKG_TARBALL}" "${PKG_TARBALL}"
    fi
    tar xf "${PKG_TARBALL}" -C "${APPS_DIR}"
    if [ ! -d "${INSTALL_DIR}" ]; then
        mv "${APPS_DIR}/mariadb-${APP_VERSION}-linux-systemd-x86_64" "${INSTALL_DIR}"
    fi
fi

# recreate symlink idempotently (-sfn avoids nesting an existing dir into a link)
ln -sfn "${INSTALL_DIR}" /usr/local/mysql

ln -sf "${INSTALL_DIR}/bin/mariadb" /usr/local/bin/mariadb
ln -sf "${INSTALL_DIR}/bin/mysql" /usr/local/bin/mysql
ln -sf "${INSTALL_DIR}/bin/mysqldump" /usr/local/bin/mysqldump

# ── config ──
# only back up if a real config exists (no empty .bak dirs on rerun)
if [ -f "/etc/mysql/my.cnf" ]; then
    mv /etc/mysql /etc/mysql.bak.$(date +%s)
fi
ensure_dir "/etc/mysql"

# innodb buffer pool = 50% of RAM, clamped 128M..8G
MEM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
BP_MB=$(( MEM_MB / 2 ))
[ "${BP_MB}" -lt 128 ] && BP_MB=128
[ "${BP_MB}" -gt 8192 ] && BP_MB=8192
INNODB_BP="${BP_MB}M"

cat > /etc/mysql/my.cnf <<EOF
[client-server]
port            = 3306
socket          = /tmp/mysql.sock

[mysqld]
user            = mysql
basedir         = /usr/local/mysql
datadir         = /usr/local/mysql/data
tmpdir          = /tmp
pid-file        = /var/run/mysqld/mysql.pid
# listen on localhost only; matches info.yaml expose
bind-address     = 127.0.0.1
# server-id required when log_bin is enabled
server-id        = 1

character-set-server  = utf8mb4
collation-server      = utf8mb4_general_ci


max_connections         = 500
connect_timeout         = 10
wait_timeout            = 600
max_allowed_packet      = 32M
thread_cache_size = 50


default_storage_engine  = InnoDB

# dynamic value computed above (INNODB_BP)
innodb_buffer_pool_size = ${INNODB_BP}
innodb_log_file_size    = 256M
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table   = 1

log_bin                     = mysql-bin
binlog_format               = ROW
binlog_row_image            = FULL
# 7 days
binlog_expire_logs_seconds  = 604800

log_error               = /var/log/mysql/error.log

[client]
default-character-set   = utf8mb4
EOF

cd "${INSTALL_DIR}"

# initialize data dir
DATA_DIR="${INSTALL_DIR}/data"
if db_data_initialized "${DATA_DIR}"; then
    log_info "data dir already initialized; skipping mariadb-install-db (rerun won't re-init or overwrite)"
else
    # drop a half-initialized dir; mariadb-install-db fails if stray files remain
    remove_path "${DATA_DIR}"
    ${INSTALL_DIR}/scripts/mariadb-install-db --user=mysql --datadir="${DATA_DIR}" --basedir="${INSTALL_DIR}"
fi
# ensure data dir owned by mysql (fresh init or reused)
chown -R mysql:mysql "${DATA_DIR}"

# ── system auto start ──
if command -v systemctl >/dev/null 2>&1; then
    cp -f "${INSTALL_DIR}/support-files/systemd/mariadb.service" /etc/systemd/system/mysql.service
    systemctl daemon-reload
    systemctl enable mysql.service
    systemctl start mysql.service
else
    cp "${INSTALL_DIR}/support-files/mysql.server" /etc/init.d/mysql
    chmod +x /etc/init.d/mysql
    chkconfig --add mysql
    chkconfig mysql on
    service mysql start
fi

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
# only generate the zapadm credential. root needs no password:
# MariaDB 10.4+ configures root@localhost with unix_socket auth (OS root via the
# local socket, no password), and zap only consumes the zapadm credential — so
# setting a root password is pointless and would add a plaintext arg. All admin
# operations below run as OS root over the socket.
ZAPADM_PASSWORD="$(get_or_gen_cred zapadm)" || exit 1

# wait up to 300s; first init can exceed 60s on slow disks.
# root uses unix_socket auth, so the probe over the socket needs no password.
MARIADB_READY=0
for _ in $(seq 1 300); do
    if "${INSTALL_DIR}/bin/mysqladmin" -u root status >/dev/null 2>&1; then
        MARIADB_READY=1
        break
    fi
    sleep 1
done
if [ "${MARIADB_READY}" -ne 1 ]; then
    log_error "mariadbd not ready within 300s; check /var/log/mysql/error.log"
    exit 1
fi

# ── zapadm panel account (idempotent: CREATE IF NOT EXISTS + ALTER to match creds) ──
"${INSTALL_DIR}/bin/mysql" -u root <<SQL
CREATE USER IF NOT EXISTS 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
ALTER USER 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'zapadm'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# remove default anonymous accounts (''@host, created with the test db).
# 10.4+ exposes mysql.user as a view over mysql.global_priv, so DROP USER per row
# (QUOTE escapes the host); DELETE is not allowed.
ANON_SQL="$("${INSTALL_DIR}/bin/mysql" -u root -N -B -e \
    "SELECT CONCAT('DROP USER IF EXISTS ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User = '';")" \
    || { log_error "failed to query anonymous accounts"; exit 1; }
if [ -n "${ANON_SQL}" ]; then
    printf '%s\n' "${ANON_SQL}" | "${INSTALL_DIR}/bin/mysql" -u root
fi

# verify: no anonymous accounts may remain
ANON_LEFT="$("${INSTALL_DIR}/bin/mysql" -u root -N -B -e \
    "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User = '';")" \
    || { log_error "failed to re-check anonymous accounts"; exit 1; }
if [ -n "${ANON_LEFT}" ]; then
    log_error "anonymous accounts still exist; handle manually: ${ANON_LEFT}"
    exit 1
fi

# ── register instance info (apps/<category>/<name>/info.yaml, shown as "installed") ──
# svc_name=mysql (systemd unit mysql.service); status and start/stop go through
# systemctl. pid_file is kept as a fallback probe on non-systemd hosts.
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: mysql
instance: mariadb-${MYSQL_SHORT_VERSION}
install_dir: ${INSTALL_DIR}
version: ${APP_VERSION}
config_file: /etc/mysql/my.cnf
pid_file: /var/run/mysqld/mysql.pid
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

echo "mariadb install successful"
