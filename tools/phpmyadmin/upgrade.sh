#!/bin/bash
# phpMyAdmin 升级脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR APP_PATH BUILD_PATH ZAP_DATA_PATH
#                                  APP_VERSION MAJOR_VERSION MINOR_VERSION APP_OLD_VERSION
# 选项（app.yaml options.upgrade）：
#   PHP_VERSION   升级后使用的 PHP（auto = 由 zapd 在每次请求时自动选择）
#
# 策略：保留 config.inc.php（blowfish_secret 与服务器设置），替换程序文件；
#       /usr/local/apps/phpmyadmin 软链切换到新版本目录，访问入口保持不变。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="phpMyAdmin"
VERSION="${APP_VERSION:-}"
[ -n "${VERSION}" ] || { log_error "缺少 APP_VERSION，无法升级"; exit 1; }
S_VERSION="${MAJOR_VERSION:-}.${MINOR_VERSION:-}"
[ "${S_VERSION}" != "." ] || { log_error "无法解析版本：APP_VERSION=${VERSION}"; exit 1; }

OLD_VERSION="${APP_OLD_VERSION:-未知}"

INSTALL_DIR="${APPS_DIR}/phpmyadmin-${S_VERSION}"
LINK_DIR="${APPS_DIR}/phpmyadmin"
LOG_DIR="${ZAP_DATA_PATH}/logs"

log_info "准备升级 ${APP_TITLE}：${OLD_VERSION} -> ${VERSION}"

# ── 定位旧安装目录与配置 ────────────────────────────────────
OLD_DIR=""
INFO_FILE="${APP_PATH}/info.yaml"
if [ -f "${INFO_FILE}" ]; then
    OLD_DIR="$(grep -m1 '^install_dir:' "${INFO_FILE}" 2>/dev/null | sed 's/^install_dir:[[:space:]]*//' || true)"
fi
[ -n "${OLD_DIR}" ] || OLD_DIR="${LINK_DIR}"

# 旧配置（blowfish_secret / 数据库地址）必须沿用，否则已登录会话与cookie 全部失效
OLD_CONF=""
if [ -f "${OLD_DIR}/config.inc.php" ]; then
    OLD_CONF="${OLD_DIR}/config.inc.php"
elif [ -f "${LINK_DIR}/config.inc.php" ]; then
    OLD_CONF="${LINK_DIR}/config.inc.php"
fi

# ── 下载并解压新版本 ────────────────────────────────────────
ARCHIVE="phpMyAdmin-${VERSION}-all-languages.tar.gz"
URL="https://files.phpmyadmin.net/phpMyAdmin/${VERSION}/${ARCHIVE}"

rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"
download_file "${URL}" "${BUILD_PATH}/${ARCHIVE}"
extract_archive "${BUILD_PATH}/${ARCHIVE}" "${BUILD_PATH}" || {
    log_error "解压失败：${ARCHIVE}"
    exit 1
}

SRC_DIR="${BUILD_PATH}/phpMyAdmin-${VERSION}-all-languages"
if [ ! -d "${SRC_DIR}" ]; then
    SRC_DIR="$(find "${BUILD_PATH}" -maxdepth 1 -mindepth 1 -type d | head -n1)"
fi
[ -d "${SRC_DIR}" ] || { log_error "解压结果异常，未找到源码目录"; exit 1; }

# ── 部署新版本 ──────────────────────────────────────────────
rm -rf "${INSTALL_DIR}"
ensure_dir "$(dirname "${INSTALL_DIR}")"
mv "${SRC_DIR}" "${INSTALL_DIR}"
log_ok "程序已部署：${INSTALL_DIR}"

# ── 恢复配置 ────────────────────────────────────────────────
ensure_dir "${INSTALL_DIR}/tmp" "${INSTALL_DIR}/upload" "${INSTALL_DIR}/save"
if [ -n "${OLD_CONF}" ] && [ -f "${OLD_CONF}" ]; then
    cp -f "${OLD_CONF}" "${INSTALL_DIR}/config.inc.php"
    log_ok "已沿用原有 config.inc.php"
else
    SECRET="$(random_password 32 | tr -d '\n')"
    cat >"${INSTALL_DIR}/config.inc.php" <<EOF
<?php
/**
 * phpMyAdmin 配置（由 ZAP 应用商店生成）
 * 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
 */
declare(strict_types=1);

\$cfg['blowfish_secret'] = '${SECRET}';
\$cfg['DefaultLang'] = 'zh_CN';
\$cfg['TempDir'] = '${LINK_DIR}/tmp';
\$cfg['UploadDir'] = '${LINK_DIR}/upload';
\$cfg['SaveDir'] = '${LINK_DIR}/save';

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
EOF
    log_warn "未找到原有配置，已生成默认 config.inc.php"
fi

# ── 切换软链 ────────────────────────────────────────────────
ln -sfn "${INSTALL_DIR}" "${LINK_DIR}"
log_ok "软链已切换：${LINK_DIR} -> ${INSTALL_DIR}"

# ── 运行用户与权限 ──────────────────────────────────────────
RUN_USER="www"
id -u www >/dev/null 2>&1 || RUN_USER="nginx"
id -u "${RUN_USER}" >/dev/null 2>&1 || RUN_USER="$(id -un)"
chown -R "${RUN_USER}" "${INSTALL_DIR}" 2>/dev/null || log_warn "修改属主失败（用户 ${RUN_USER}）"
find "${INSTALL_DIR}" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "${INSTALL_DIR}" -type f -exec chmod 0644 {} + 2>/dev/null || true
chmod 0770 "${INSTALL_DIR}/tmp" "${INSTALL_DIR}/upload" "${INSTALL_DIR}/save" 2>/dev/null || true

# ── 站点配置：缺省保持不动，仅显式指定 PHP 时重建 ───────────
# 访问通道由 zapd 的 /webapps/phpmyadmin/ 提供（面板鉴权 + FastCGI 直连系统 PHP-FPM）：
# 不再生成独立的 Nginx 站点，避免暴露一个未经面板鉴权的数据库入口。
log_info "PHP 通道在每次请求时由 zapd 解析，无需重建站点配置"

# ── 更新登记信息 ────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${HOST_IP}" ] || HOST_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
[ -n "${HOST_IP}" ] || HOST_IP="127.0.0.1"
PORT_SHOW="$(grep -m1 '^port:' "${INFO_FILE}" 2>/dev/null | sed 's/^port:[[:space:]]*//' || true)"
[ -n "${PORT_SHOW}" ] || PORT_SHOW=8888

ensure_dir "${APP_PATH}"
cat >"${INFO_FILE}" <<EOF
instance: phpmyadmin
install_dir: ${INSTALL_DIR}
config_file: ${INSTALL_DIR}/config.inc.php
web_url: http://${HOST_IP}:${PORT_SHOW}
expose: port
port: ${PORT_SHOW}
tags:
  - webapp
  - mysql
EOF

log_ok "${APP_TITLE} ${VERSION} upgrading successful"
log_info "访问地址：http://${HOST_IP}:${PORT_SHOW}"
