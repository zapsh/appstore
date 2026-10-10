#!/bin/bash
#
# MariaDB Install Script
# Version : 1.0.1
# inject variables: ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"


MYSQL_SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/mariadb-${MYSQL_SHORT_VERSION}"

MYSQL_LINK="/usr/local/mysql"

# ── 已安装 / 安装残局检查 ──────────────────────────────────
# 与 MySQL 同理：系统只在脚本成功退出后写 meta.yaml（面板「已安装」才可卸载），
# 中途失败（如 mariadb-install-db / 启动缺 libaio.so.1）会留下目录与软链，
# 于是「面板说没装（不能卸载）+ 脚本说装了（不能重装）」的死锁。
# 判据：APP_PATH/info.yaml = 装完了 → 拒绝；否则清理残局后继续装。
if app_install_complete; then
    log_error "mariadb 已安装（${APP_PATH}/info.yaml 已登记）,请先卸载后再安装"
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
    log_error "${MYSQL_LINK} 已存在且不是本包创建的软链（可能是手工安装的 MySQL/MariaDB）:不自动处理"
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

# ── 系统用户 ───────────────────────────────────────────────
if ! id mysql >/dev/null 2>&1; then
    ensure_user mysql mysql
fi

# ── 运行时依赖库 ───────────────────────────────────────────
# 与 MySQL 同理：Ubuntu 24.04+/Debian 13+ 的 libaio1 已改名 libaio1t64，
# 且只提供 libaio.so.1t64（官方二进制按 libaio.so.1 加载），故装完补同名软链；
# libncurses5 也已下线（见 bash_utils::have_lib / link_lib_compat）。
PKG_MGR="$(pkg_manager || true)"
case "${PKG_MGR}" in
    apt)
        apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update 失败(继续尝试安装)"
        if ! have_lib libaio.so.1; then
            pkg_install_any apt libaio1t64 libaio1 \
                || log_warn "libaio 包未装上，尝试用已有库做兼容软链"
            link_lib_compat libaio.so.1 libaio.so.1t64 \
                || { log_error "缺少 libaio.so.1：mariadbd 必需。请手动安装 libaio1t64(Ubuntu 24.04+/Debian 13+) 或 libaio1 后重试"; exit 1; }
        fi
        # 官方包里的 mariadb 客户端按 libncurses.so.6 加载（不是 libncursesw.so.6）：
        # 源里装不上时用已有的 libncursesw.so.6 建同名软链兜底
        have_lib 'libncurses.so.*' \
            || pkg_install_any apt libncurses6 libncurses5 \
            || link_lib_compat libncurses.so.6 libncursesw.so.6 \
            || { log_error "缺少 libncurses：mariadb 客户端必需。请手动安装 libncurses6(或旧系统的 libncurses5) 后重试"; exit 1; }
        ;;
    dnf | yum)
        have_lib libaio.so.1 \
            || pkg_install_any "${PKG_MGR}" libaio \
            || { log_error "缺少 libaio.so.1：mariadbd 必需。请手动安装 libaio 后重试"; exit 1; }
        have_lib 'libncurses.so.*' \
            || pkg_install_any "${PKG_MGR}" ncurses-libs ncurses-compat-libs \
            || { log_error "缺少 libncurses：mariadb 客户端必需。请手动安装 ncurses-libs 后重试"; exit 1; }
        pkg_install_any "${PKG_MGR}" numactl-libs || log_warn "numactl-libs 安装失败(可选,NUMA 绑核会退化)"
        ;;
    *)
        log_warn "未识别的包管理器：请自行确认 libaio.so.1 与 libncurses 已安装"
        ;;
esac

mkdir -p /var/log/mysql /var/run/mysqld
chown -R mysql:mysql /var/log/mysql /var/run/mysqld

# ── 解压二进制包 ───────────────────────────────────────────
PKG_TARBALL="mariadb-${APP_VERSION}-linux-systemd-x86_64.tar.gz"
cd "${PKG_PATH}"
if [ -d "${INSTALL_DIR}" ]; then
    log_info "复用已存在的安装目录: ${INSTALL_DIR}（跳过下载 / 解压）"
else
    # 半解压残留：tar 中途失败会留下不完整的解压目录，先清掉再重新解压
    remove_path "${APPS_DIR}/mariadb-${APP_VERSION}-linux-systemd-x86_64"
    if [ ! -f "${PKG_TARBALL}" ]; then
        log_info "下载 mariadb: ${PKG_TARBALL}"
        # 统一走 bash_utils::download_file（curl --progress-bar / wget --show-progress）：
        # 非 TTY 下以 \r 原地刷新，日志里只占一行进度条，而非 wget 默认的逐行 dot 进度
        download_file "$(pkg_mirror)/mariadb/${PKG_TARBALL}" "${PKG_TARBALL}"
    fi
    tar xf "${PKG_TARBALL}" -C "${APPS_DIR}"
    if [ ! -d "${INSTALL_DIR}" ]; then
        mv "${APPS_DIR}/mariadb-${APP_VERSION}-linux-systemd-x86_64" "${INSTALL_DIR}"
    fi
fi

# 软链幂等重建（-sfn 不会把已有目录变成嵌套链接）
ln -sfn "${INSTALL_DIR}" /usr/local/mysql

ln -sf "${INSTALL_DIR}/bin/mariadb" /usr/local/bin/mariadb
ln -sf "${INSTALL_DIR}/bin/mysql" /usr/local/bin/mysql
ln -sf "${INSTALL_DIR}/bin/mysqldump" /usr/local/bin/mysqldump

# ── 配置 ───────────────────────────────────────────────────
# 只有确实存在配置时才备份（空目录不留一堆 .bak，重跑也不会重复备份）
if [ -f "/etc/mysql/my.cnf" ]; then
    mv /etc/mysql /etc/mysql.bak.$(date +%s)
fi
ensure_dir "/etc/mysql"

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

character-set-server  = utf8mb4
collation-server      = utf8mb4_general_ci


max_connections         = 500
connect_timeout         = 10
wait_timeout            = 600
max_allowed_packet      = 32M
thread_cache_size = 50 


default_storage_engine  = InnoDB

# total memory 50% - 70%
innodb_buffer_pool_size = 512M
innodb_log_file_size    = 256M
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table   = 1

log_bin                     = mysql-bin
binlog_format               = ROW
binlog_row_image            = FULL
# 7 days (7*24*60*60=604800)
binlog_expire_logs_seconds  = 604800

log_error               = /var/log/mysql/error.log

[client]
default-character-set   = utf8mb4
EOF

cd "${INSTALL_DIR}"
chown -R mysql:mysql "${INSTALL_DIR}"

# 初始化数据目录
DATA_DIR="${INSTALL_DIR}/data"
if db_data_initialized "${DATA_DIR}"; then
    log_info "数据目录已初始化,跳过 mariadb-install-db（重跑不重复初始化,也不覆盖已有库）"
else
    # 半初始化残局：目录下有零散文件时 mariadb-install-db 会失败，先清掉
    remove_path "${DATA_DIR}"
    ${INSTALL_DIR}/scripts/mariadb-install-db --user=mysql --datadir="${DATA_DIR}" --basedir="${INSTALL_DIR}"
fi

# ── 开机自启 ───────────────────────────────────────────────
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
# 只生成 zapadm 凭据。root 不需要密码：
# MariaDB 10.4+ 的 mariadb-install-db 默认把 root@localhost 配为 unix_socket 认证
# （仅 OS root 经本地 socket 免密登录，原生密码分支为 'invalid'），
# 且 zap 全链路只消费 zapadm 凭据——设置 root 密码既无意义还引入命令行明文，
# 故省略；以下管理操作一律以 OS root 身份经 socket 免密执行。
ZAPADM_PASSWORD="$(get_or_gen_cred zapadm)" || exit 1


# 等待 mariadbd 就绪（最多 60s）
MARIADB_READY=0
for _ in $(seq 1 60); do
    if "${INSTALL_DIR}/bin/mysqladmin" -u root status >/dev/null 2>&1; then
        MARIADB_READY=1
        break
    fi
    sleep 1
done
if [ "${MARIADB_READY}" -ne 1 ]; then
    log_error "mariadbd 60s 内未就绪，请查看 /var/log/mysql/error.log"
    exit 1
fi

# ── zapadm 面板账号（幂等：CREATE IF NOT EXISTS + ALTER 对齐凭据库）──
"${INSTALL_DIR}/bin/mysql" -u root <<SQL
CREATE USER IF NOT EXISTS 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
ALTER USER 'zapadm'@'localhost' IDENTIFIED BY '${ZAPADM_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'zapadm'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# ── 清除默认匿名空密码账号（''@localhost 等，随 test 库一起创建）──
# 10.4+ 的 mysql.user 是 mysql.global_priv 的视图，不能 DELETE，
# 只能 DROP USER；按行生成（QUOTE 负责转义 host），覆盖任意 host 形态
ANON_SQL="$("${INSTALL_DIR}/bin/mysql" -u root -N -B -e \
    "SELECT CONCAT('DROP USER IF EXISTS ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User = '';")" \
    || { log_error "查询匿名账号失败"; exit 1; }
if [ -n "${ANON_SQL}" ]; then
    printf '%s\n' "${ANON_SQL}" | "${INSTALL_DIR}/bin/mysql" -u root
fi

# 安全校验：匿名账号必须清干净
ANON_LEFT="$("${INSTALL_DIR}/bin/mysql" -u root -N -B -e \
    "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User = '';")" \
    || { log_error "复查匿名账号失败"; exit 1; }
if [ -n "${ANON_LEFT}" ]; then
    log_error "仍存在匿名账号，请人工处理: ${ANON_LEFT}"
    exit 1
fi



# ── 登记实例信息(apps/<category>/<name>/info.yaml,供「已安装」展示)──────
# svc_name=mysql(systemd unit mysql.service),状态探测与面板启停走
# systemctl;pid_file 保留,作为无 systemd 环境下的兜底探活依据。
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: mysql
instance: mariadb-${MYSQL_SHORT_VERSION}
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
