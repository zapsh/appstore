#!/bin/bash
# phpMyAdmin 安装脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：
#   ZAP_PATH APPS_DIR PKG_PATH APP_PATH BUILD_PATH ZAP_DATA_PATH
#   APP_VERSION MAJOR_VERSION MINOR_VERSION CPU_NUM
# 选项（app.yaml options.install，以同名环境变量注入）：
#   PORT          访问端口（默认 8888）
#   PHP_VERSION   运行 PHP（auto = 自动选已安装的最高版本）
#   DB_HOST       被管理数据库地址（默认 127.0.0.1）
#   DB_PORT       数据库端口（默认 3306）
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="phpMyAdmin"

DB_HOST_OPT="${DB_HOST:-127.0.0.1}"
DB_PORT_OPT="${DB_PORT:-3306}"
PA_SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/phpmyadmin-${PA_SHORT_VERSION}"
LINK_DIR="${APPS_DIR}/phpmyadmin"

LOG_DIR="${ZAP_DATA_PATH}/logs"

log_info "准备安装 ${APP_TITLE} "

# ── 下载并解压 ──────────────────────────────────────────────
ARCHIVE="phpMyAdmin-${APP_VERSION}-all-languages.tar.gz"
URL="$(pkg_mirror)/webapps/${ARCHIVE}"

rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"
download_file "${URL}" "${BUILD_PATH}/${ARCHIVE}"
extract_archive "${BUILD_PATH}/${ARCHIVE}" "${BUILD_PATH}" || {
    log_error "解压失败：${ARCHIVE}"
    exit 1
}

SRC_DIR="${BUILD_PATH}/phpMyAdmin-${APP_VERSION}-all-languages"
if [ ! -d "${SRC_DIR}" ]; then
    # 少数版本压缩包顶层目录名可能不同，回退取唯一子目录
    SRC_DIR="$(find "${BUILD_PATH}" -maxdepth 1 -mindepth 1 -type d | head -n1)"
fi
[ -d "${SRC_DIR}" ] || { log_error "解压结果异常，未找到源码目录"; exit 1; }

# ── 部署到安装目录 ──────────────────────────────────────────
if [ -d "${INSTALL_DIR}" ]; then
    BAK_DIR="${INSTALL_DIR}.bak.$(date +%s)"
    log_warn "安装目录已存在，先备份为 ${BAK_DIR}"
    mv "${INSTALL_DIR}" "${BAK_DIR}"
fi
ensure_dir "$(dirname "${INSTALL_DIR}")"
mv "${SRC_DIR}" "${INSTALL_DIR}"
ln -sfn "${INSTALL_DIR}" "${LINK_DIR}"
log_ok "程序已部署：${INSTALL_DIR}"

# ── 生成 config.inc.php ─────────────────────────────────────
ensure_dir "${INSTALL_DIR}/tmp" "${INSTALL_DIR}/upload" "${INSTALL_DIR}/save"
SECRET="$(random_password 32 | tr -d '\n')"
cat >"${INSTALL_DIR}/config.inc.php" <<EOF
<?php
/**
 * phpMyAdmin 配置（由 ZAP 应用商店生成，自动生成请勿手改 blowfish_secret）
 * 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
 */
declare(strict_types=1);

\$cfg['blowfish_secret'] = '${SECRET}';
\$cfg['DefaultLang'] = 'zh_CN';
\$cfg['TempDir'] = '/tmp';
\$cfg['UploadDir'] = '${LINK_DIR}/upload';
\$cfg['SaveDir'] = '${LINK_DIR}/save';

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['host'] = '${DB_HOST_OPT}';
\$cfg['Servers'][\$i]['port'] = '${DB_PORT_OPT}';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
EOF
log_ok "已生成 config.inc.php（数据库 ${DB_HOST_OPT}:${DB_PORT_OPT}）"

# ── 运行用户与权限 ──────────────────────────────────────────
RUN_USER="www"
id -u www >/dev/null 2>&1 || RUN_USER="nginx"
id -u "${RUN_USER}" >/dev/null 2>&1 || RUN_USER="$(id -un)"
chown -R "${RUN_USER}" "${INSTALL_DIR}" 2>/dev/null || log_warn "修改属主失败（用户 ${RUN_USER}），请手动确认权限"
find "${INSTALL_DIR}" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "${INSTALL_DIR}" -type f -exec chmod 0644 {} + 2>/dev/null || true
chmod 0770 "${INSTALL_DIR}/tmp" "${INSTALL_DIR}/upload" "${INSTALL_DIR}/save" 2>/dev/null || true


# ── 登记实例信息 ────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${HOST_IP}" ] || HOST_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
[ -n "${HOST_IP}" ] || HOST_IP="127.0.0.1"

ensure_dir "${APP_PATH}"
cat >"${APP_PATH}/info.yaml" <<EOF
instance: phpmyadmin
install_dir: ${INSTALL_DIR}
config_file: ${INSTALL_DIR}/config.inc.php
web_url: http://${HOST_IP}:2600/webapps/phpmyadmin/
expose: none
tags:
  - webapp
  - mysql
EOF

log_ok "${APP_TITLE} ${APP_VERSION} installing successful"
log_info "访问地址：http://${HOST_IP}:2600/webapps/phpmyadmin/（末尾斜杠不要省略，使用已有的 MySQL / MariaDB 账号登录）"
