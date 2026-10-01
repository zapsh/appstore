#!/bin/bash
# webapps 应用骨架卸载脚本（zap appstore 调用）
#
# 仅清理本应用写入站点根目录的文件；数据库保留（如需连库一起删，在面板卸载选项中扩展）。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

APP_TITLE="Web 应用骨架"
if [ -z "${SITE_ROOT:-}" ]; then
  log_warn "未注入 SITE_ROOT，跳过文件清理"
  exit 0
fi

rm -f "${SITE_ROOT}/index.php" "${SITE_ROOT}/config.php"
log_ok "${APP_TITLE} 已清理骨架文件（数据库保留）"
