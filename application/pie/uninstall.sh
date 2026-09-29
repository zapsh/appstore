#!/bin/bash
# PIE 卸载脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR APP_PATH
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

PIE_DIR="${APPS_DIR}/pie"

# 删全局命令（可能是符号链接或包装脚本）
if [ -L /usr/local/bin/pie ] || [ -f /usr/local/bin/pie ]; then
    rm -f /usr/local/bin/pie
    log_info "已删除全局命令 /usr/local/bin/pie"
fi

# 删安装目录
if [ -d "${PIE_DIR}" ]; then
    rm -rf "${PIE_DIR}"
    log_info "已删除 ${PIE_DIR}"
fi

# 删实例信息
if [ -d "${APP_PATH}" ]; then
    rm -rf "${APP_PATH}"
    log_info "已删除实例信息 ${APP_PATH}"
fi

log_info "PIE 卸载完成"
