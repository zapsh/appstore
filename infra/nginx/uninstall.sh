#!/bin/bash
# Nginx 卸载脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：APPS_DIR APP_VERSION
set -euo pipefail

INSTALL_PATH="${APPS_DIR}/nginx"

echo "uninstall nginx ${APP_VERSION}"

# ── 停止并禁用服务 ─────────────────────────────────────────
systemctl stop nginx.service 2>/dev/null || true
systemctl disable nginx.service 2>/dev/null || true

# ── 备份配置 ───────────────────────────────────────────────
BAK_DIR="/root/zap_bak/nginx"
mkdir -p "${BAK_DIR}"
if [ -d "${INSTALL_PATH}/conf" ]; then
    cp -Rf "${INSTALL_PATH}/conf" "${BAK_DIR}/nginx.conf.$(date +%Y%m%d%H%M%S)"
fi

# ── 移除软链 / 旧版版本化目录(新布局不再创建,这里兼容旧安装) ──
if [ -L "${APPS_DIR}/nginx" ]; then
    rm -f "${APPS_DIR}/nginx"
fi
if [ -e "${APPS_DIR}/nginx-${APP_VERSION}" ]; then
    rm -rf "${APPS_DIR}/nginx-${APP_VERSION}"
fi

# ── 删除安装目录（zap 侧随后清理 APP_PATH 元数据目录） ─────
if [ -d "${INSTALL_PATH}" ]; then
    echo "Removing ${INSTALL_PATH}..."
    rm -rf "${INSTALL_PATH}"
    echo "Removing done."
fi

# ── 移除服务文件 ───────────────────────────────────────────
rm -f /etc/systemd/system/nginx.service
systemctl daemon-reload 2>/dev/null || true

echo "nginx uninstall successful"
