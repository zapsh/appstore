#!/bin/bash
# MySQL 安装脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

MYSQL_SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/mysql-${MYSQL_SHORT_VERSION}"
MYSQL_LINK="/usr/local/mysql"

# ── 已安装 / 安装残局检查 ──────────────────────────────────
# 系统只在脚本【成功退出】后才写 meta.yaml（面板据此显示「已安装」并可卸载）。
# 因此安装中途失败（典型：mysqld 初始化缺 libaio.so.1）时，面板仍显示未安装
# → 卸载按钮不可用；而这里若只看 /usr/local/mysql 在不在又说「已安装」
# → 装也装不了、卸也卸不掉，形成死锁。
# 判据：APP_PATH/info.yaml（脚本末尾登记）= 装完了 → 拒绝重装；
#       目录/软链还在但没登记 = 装了一半的残局 → 清理后继续装。
if app_install_complete; then
    log_error "mysql 已安装（${APP_PATH}/info.yaml 已登记）,请先卸载 mysql 后再安装"
    exit 1
fi
if [ -L "${MYSQL_LINK}" ]; then
    RESOLVED="$(readlink -f "${MYSQL_LINK}" 2>/dev/null || true)"
    if [ -z "${RESOLVED}" ] || [ ! -d "${RESOLVED}" ]; then
        log_warn "残留软链 ${MYSQL_LINK} 指向已不存在的位置（${RESOLVED:-空}）,直接移除"
        remove_path "${MYSQL_LINK}"
    elif db_data_initialized "${RESOLVED}/data"; then
        log_error "${MYSQL_LINK} -> ${RESOLVED} 的数据目录已初始化（可能含真实数据）,不自动清理"
        log_error "重装请先备份数据,再手动删除 ${RESOLVED} 与 ${MYSQL_LINK} 后重试"
        exit 1
    elif path_under "${RESOLVED}" "${APPS_DIR}"; then
        log_warn "检测到上次安装残留: ${MYSQL_LINK} -> ${RESOLVED}（数据目录未初始化）,自动清理后继续安装"
        service_stop_disable mysql.service || true
        remove_path "${MYSQL_LINK}"
        remove_path "${RESOLVED}"
        remove_path /etc/mysql
        remove_path /etc/init.d/mysql
        remove_path /etc/systemd/system/mysql.service
        if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
    else
        log_error "${MYSQL_LINK} -> ${RESOLVED} 不在 ${APPS_DIR} 下,不自动清理;请人工确认后移除"
        exit 1
    fi
elif [ -e "${MYSQL_LINK}" ]; then
    log_error "${MYSQL_LINK} 已存在且不是本包创建的软链（可能是手工安装的 MySQL）:不自动处理"
    log_error "如需继续,请先备份并手动移除 ${MYSQL_LINK} 后重试"
    exit 1
elif [ -d "${INSTALL_DIR}" ]; then
    if db_data_initialized "${INSTALL_DIR}/data"; then
        log_error "${INSTALL_DIR} 数据目录已初始化（可能含真实数据）,不自动清理;请先备份并手动删除后重试"
        exit 1
    fi
    log_warn "检测到残留安装目录 ${INSTALL_DIR}（数据目录未初始化）,自动清理后继续安装"
    remove_path "${INSTALL_DIR}"
fi

# ── 运行时依赖库 ───────────────────────────────────────────
# mysqld 需要 libaio.so.1、mysql 客户端需要 libncurses；包名随发行版 / 版本变化：
# Ubuntu 24.04+、Debian 13+（is_os_ge ubuntu 24.04 / is_os_ge debian 13）里
# libaio1 已改名 libaio1t64，且该包只提供 libaio.so.1t64 —— 官方二进制仍按
# libaio.so.1 加载，所以装完还要补同名软链（link_lib_compat）；libncurses5 也已下线。
# 因此：先按 soname 探测，缺失再按候选包名逐个尝试，最后按 soname 复核。
PKG_MGR="$(pkg_manager || true)"
case "${PKG_MGR}" in
    apt)
        apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update 失败(继续尝试安装)"
        if ! have_lib libaio.so.1; then
            pkg_install_any apt libaio1t64 libaio1 \
                || log_warn "libaio 包未装上，尝试用已有库做兼容软链"
            link_lib_compat libaio.so.1 libaio.so.1t64 \
                || { log_error "缺少 libaio.so.1：mysqld 必需。请手动安装 libaio1t64(Ubuntu 24.04+/Debian 13+) 或 libaio1 后重试"; exit 1; }
        fi
        # 官方包里的 mysql 客户端按 libncurses.so.6 加载（不是 libncursesw.so.6）：
        # 源里装不上时退而求其次，用系统已有的 libncursesw.so.6 建同名软链，
        # 比直接判失败退出更有用（客户端起不来，本脚本后续的 SQL 也执行不了）
        have_lib 'libncurses.so.*' \
            || pkg_install_any apt libncurses6 libncurses5 \
            || link_lib_compat libncurses.so.6 libncursesw.so.6 \
            || { log_error "缺少 libncurses：mysql 客户端必需。请手动安装 libncurses6(或旧系统的 libncurses5) 后重试"; exit 1; }
        ;;
    dnf | yum)
        have_lib libaio.so.1 \
            || pkg_install_any "${PKG_MGR}" libaio \
            || { log_error "缺少 libaio.so.1：mysqld 必需。请手动安装 libaio 后重试"; exit 1; }
        have_lib 'libncurses.so.*' \
            || pkg_install_any "${PKG_MGR}" ncurses-libs ncurses-compat-libs \
            || { log_error "缺少 libncurses：mysql 客户端必需。请手动安装 ncurses-libs 后重试"; exit 1; }
        ;;
    *)
        log_warn "未识别的包管理器：请自行确认 libaio.so.1 与 libncurses 已安装"
        ;;
esac

# ── 系统用户 ───────────────────────────────────────────────
# mysqld 以 mysql 用户/组运行（--user=mysql、chown mysql:mysql 均依赖它）
ensure_user mysql mysql || { log_error "创建 mysql 用户/组失败"; exit 1; }
ensure_dir "/var/log/mysql" || log_warn "安装目录创建失败: /var/log/mysql"
ensure_dir "/var/run/mysqld" || log_warn "安装目录创建失败: /var/run/mysqld"
chown -R mysql:mysql /var/log/mysql /var/run/mysqld

# ── 选择与系统 glibc 匹配的官方二进制包 ───────────────────
# 仅支持 MySQL 8.0+（5.7 及更早版本已移除）
if [ "${MAJOR_VERSION}" -lt 8 ]; then
    log_error "MySQL ${APP_VERSION} 不再受支持：已移除 5.7 及更早版本，请选择 8.0+"
    exit 1
fi
# 官方二进制按 glibc 构建，按系统 glibc 选择可用包：
#   glibc >= 2.28 : 9.x / 8.4 / 8.0 全系可用（glibc2.28 构建，更高的 2.3x 向下兼容）
#   glibc 2.17~2.27: 仅 8.0 系列提供 glibc2.17 构建（当前可选 8.0.46）
#   glibc <  2.17 : 无可用官方二进制
GLIBC_VERSION=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
GLIBC_MAJOR="${GLIBC_VERSION%%.*}"
GLIBC_MINOR="${GLIBC_VERSION#*.}"
GLIBC_MINOR="${GLIBC_MINOR%%.*}"
case "${GLIBC_MAJOR}${GLIBC_MINOR}" in
    '' | *[!0-9]*)
        log_error "无法探测系统 glibc 版本(取到 '${GLIBC_VERSION:-空}')，无法选择安装包"
        exit 1 ;;
esac

MYSQL_MINOR="${APP_VERSION#*.}"
MYSQL_MINOR="${MYSQL_MINOR%%.*}"
case "${MYSQL_MINOR}" in
    '' | *[!0-9]*)
        log_error "无法解析 MySQL 次版本号: ${APP_VERSION}"
        exit 1 ;;
esac

if [ "${GLIBC_MAJOR}" -gt 2 ] \
    || { [ "${GLIBC_MAJOR}" -eq 2 ] && [ "${GLIBC_MINOR}" -ge 28 ]; }; then
    GLIBC_PKG="2.28"
elif [ "${GLIBC_MAJOR}" -eq 2 ] && [ "${GLIBC_MINOR}" -ge 17 ]; then
    # 旧系统（CentOS 7 / Debian 9 等）：只有 8.0 系列有 glibc2.17 构建
    if [ "${MAJOR_VERSION}" -ne 8 ] || [ "${MYSQL_MINOR}" -ne 0 ]; then
        log_error "系统 glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} 仅支持 MySQL 8.0 系列（当前可选 8.0.46）"
        log_error "MySQL ${APP_VERSION} 需要 glibc >= 2.28，请改选 8.0.46，或升级系统（建议 Debian 10+ / Ubuntu 20.04+ / RHEL 8+）"
        exit 1
    fi
    GLIBC_PKG="2.17"
else
    log_error "系统 glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} 过低：MySQL 官方二进制需要 glibc >= 2.17"
    exit 1
fi
if [ "${MAJOR_VERSION}" -eq 8 ] && [ "${MYSQL_MINOR}" -eq 0 ]; then
    # 安装 8.0 系列时，强制使用 8.0.46（glibc2.17 构建）以兼容旧系统
    GLIBC_PKG="2.17"
fi

log_info "系统 glibc ${GLIBC_MAJOR}.${GLIBC_MINOR}，使用 glibc${GLIBC_PKG} 官方包"
PKG_TARBALL="mysql-${APP_VERSION}-linux-glibc${GLIBC_PKG}-x86_64-minimal.tar.xz"
PKG_EXTRACT_DIR="mysql-${APP_VERSION}-linux-glibc${GLIBC_PKG}-x86_64-minimal"

cd "${PKG_PATH}"
if [ -d "${INSTALL_DIR}" ]; then
    log_info "复用已存在的安装目录: ${INSTALL_DIR}（跳过下载 / 解压）"
else
    # 半解压残留：tar 中途失败会留下不完整的解压目录，先清掉再重新解压
    remove_path "${APPS_DIR}/${PKG_EXTRACT_DIR}"
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_info "下载 mysql: ${PKG_TARBALL}"
        download_file "$(pkg_mirror)/mysql/${PKG_TARBALL}" "${PKG_TARBALL}" || true
    fi
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_error "下载 mysql 失败: ${PKG_TARBALL} 不存在"
        exit 1
    fi
    log_info "解压 mysql: ${PKG_TARBALL} -> ${APPS_DIR}"
    tar xf "${PKG_TARBALL}" -C "${APPS_DIR}"

    # ── 安装目录（解压目录名含 glibc 标识，统一重命名为 mysql-版本） mysql-8.0 ──
    if [ -d "${APPS_DIR}/${PKG_EXTRACT_DIR}" ] && [ ! -d "${INSTALL_DIR}" ]; then
        mv "${APPS_DIR}/${PKG_EXTRACT_DIR}" "${INSTALL_DIR}"
    fi
    if [ ! -d "${INSTALL_DIR}" ]; then
        log_error "Error unpacking mysql: ${INSTALL_DIR} not found"
        exit 1
    fi
fi

if [ "${SET_DEFAULT:-false}" = "true" ]; then
    log_info "设置 mysql 命令为默认: /usr/local/bin/mysql"
    ln -sf "${INSTALL_DIR}/bin/mysql" /usr/local/bin/mysql
    ln -sf "${INSTALL_DIR}/bin/mysqldump" /usr/local/bin/mysqldump
    ln -sf "${INSTALL_DIR}/bin/myisamchk" /usr/local/bin/myisamchk
    ln -sf "${INSTALL_DIR}/bin/mysqlcheck" /usr/local/bin/mysqlcheck
fi

if [ ! -d "/usr/local/mysql" ]; then
    log_info "Create soft link: /usr/local/mysql -> ${INSTALL_DIR}"
    ln -sf "${INSTALL_DIR}" /usr/local/mysql
fi

if [ -f "/etc/mysql/my.cnf" ]; then
    log_info "backup /etc/mysql to /etc/mysql.bak.$(date +%Y%m%d%H%M%S)"
    mv /etc/mysql "/etc/mysql.bak.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p /etc/mysql

cd "${INSTALL_DIR}"
mkdir -p mysql-files
chmod 750 mysql-files
chown -R mysql:mysql "${INSTALL_DIR}"

# 初始化数据目录（无密码模式，随后设置 root 密码）
DATA_DIR="${INSTALL_DIR}/data"
if db_data_initialized "${DATA_DIR}"; then
    log_info "数据目录已初始化,跳过 mysqld --initialize-insecure（重跑不重复初始化,也不覆盖已有库）"
    DATA_REUSED=1
else
    remove_path "${DATA_DIR}"
    bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=/usr/local/mysql/data --user=mysql
    DATA_REUSED=0
fi

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

max_allowed_packet              = 32M


slow_query_log_file = /var/log/mysql/mysql-slow.log
slow_query_log      = 1
long_query_time     = 1


character-set-server = utf8mb4
collation-server     = utf8mb4_0900_ai_ci
log_timestamps       = SYSTEM


# default 128M (total memory  50% - 70%)
innodb_buffer_pool_size = 512M 
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 1

max_connections         = 500
max_connect_errors       = 1000
thread_cache_size = 50

log_bin         = mysql-bin
binlog_format   = ROW
binlog_row_image = FULL
# 7 days (7*24*60*60=604800)
binlog_expire_logs_seconds = 604800 

EOF

# ── system auto start ───────────────────────────────────────────────
log_info "setup mysql service, enable auto start on boot"
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

# ── 账号凭据（root / zapadm）──────────────────────────────
# 密码统一由凭据库托管（/etc/zap/credentials/mysql_<user>.cred，0400 加密存储）：
get_or_gen_cred() {
    local user="$1"
    if ! "${ZAPCTL}" cred exists mysql "${user}" >/dev/null 2>&1; then
        log_info "生成并保存 mysql/${user} 凭据" >&2
        "${ZAPCTL}" cred gen mysql "${user}" >/dev/null \
            || { log_error "生成 mysql/${user} 凭据失败" >&2; return 1; }
    fi
    local pass
    pass="$("${ZAPCTL}" cred show mysql "${user}")" \
        || { log_error "读取 mysql/${user} 凭据失败" >&2; return 1; }
    if [ -z "${pass}" ]; then
        log_error "mysql/${user} 凭据为空" >&2
        return 1
    fi
    printf '%s' "${pass}"
}
MYSQL_ROOT_PASSWORD="$(get_or_gen_cred root)" || exit 1
ZAPADM_PASSWORD="$(get_or_gen_cred zapadm)" || exit 1

# 此后凭据经 0600 临时配置文件传入（mktemp 默认 0600）：
# 1) 避免命令行明文（ps 对同机用户可见） 2) 消除 "Using a password..." 告警
ROOT_CNF="$(mktemp /tmp/mysql-root.XXXXXX.cnf)"
trap 'rm -f "${ROOT_CNF:-}"' EXIT
printf '[client]\nuser = root\npassword = %s\n' "${MYSQL_ROOT_PASSWORD}" > "${ROOT_CNF}"

# 等待 mysqld 就绪（最多 60s）
# 复用已初始化的数据目录时 root 已有密码（来自同一凭据库），探活必须带凭据
log_info "wait for mysqld ready (max 60s)"
MYSQLD_READY=0
for _ in $(seq 1 60); do
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
    log_error "mysqld 60s 内未就绪，请查看 /var/log/mysql/error.log"
    exit 1
fi

log_info "mysqld ready, set root password"
if [ "${DATA_REUSED}" != "1" ]; then
    bin/mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
SQL
fi

log_info "create zapadm user"
bin/mysql --defaults-extra-file="${ROOT_CNF}" <<SQL
CREATE USER IF NOT EXISTS 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
ALTER USER 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'zapadm'@'localhost' WITH GRANT OPTION;
DELETE FROM mysql.user WHERE User = '';
FLUSH PRIVILEGES;
SQL

EMPTY_PW_USERS="$(bin/mysql --defaults-extra-file="${ROOT_CNF}" -N -B -e \
    "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE authentication_string = '' AND plugin IN ('mysql_native_password','caching_sha2_password') AND account_locked = 'N';")" \
    || { log_error "查询空密码账号失败"; exit 1; }
if [ -n "${EMPTY_PW_USERS}" ]; then
    log_error "仍存在空密码账号，请人工处理: ${EMPTY_PW_USERS}"
    exit 1
fi

log_info "check root login with empty password"
if bin/mysql -u root -e "SELECT 1" </dev/null >/dev/null 2>&1; then
    log_error "root 空密码仍可登录，安全加固失败"
    exit 1
fi

# restart mysql
log_info "restart mysql"
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart mysql.service
elif command -v service >/dev/null 2>&1; then
    service mysql restart
fi
log_info "mysql restart done"

log_info "write mysql info.yaml to ${APP_PATH}/info.yaml"
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
