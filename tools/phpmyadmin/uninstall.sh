#!/bin/bash
# phpMyAdmin 卸载脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR APP_PATH APP_VERSION
#                                  MAJOR_VERSION MINOR_VERSION
#
# 安全策略（核心：绝不误删其它目录）
#   1. 安装目录一律以 info.yaml 登记的 install_dir 为准，软链仅作回退；
#   2. 目标必须是 APPS_DIR（/usr/local/apps）的**直接子目录**；
#   3. 空值 / 根路径 / APPS_DIR 自身 / 越界路径，一律拒绝删除；
#   4. 删除前再做一次状态复核，任一环节不满足立即中止。
#
# 用到的通用函数 normalize_dir / yaml_value / assert_under_apps_dir
# 均来自 ${ZAP_PATH}/scripts/zap/bash_utils.sh，其它应用包可直接复用。
#
# 说明：仅删除程序目录与软链，不触碰数据库数据。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"
assert_root || exit 1

APP_TITLE="phpMyAdmin"
LINK_DIR="${APPS_DIR}/phpmyadmin"
INFO_FILE="${APP_PATH}/info.yaml"

# ── 主流程 ──────────────────────────────────────────────────

# 安装目录：info.yaml 登记优先，软链指向次之（通用函数，见 bash_utils.sh）
INSTALL_DIR="$(resolve_install_dir "${INFO_FILE}" "${LINK_DIR}")"

if [ -z "${INSTALL_DIR}" ]; then
    log_error "未能确定安装目录（info.yaml 缺失且软链不存在），中止卸载"
    exit 1
fi

log_info "准备卸载 ${APP_TITLE}（安装目录 ${INSTALL_DIR}）"

# 目录已不在：只清理残留软链后正常结束（幂等）
if [ ! -d "${INSTALL_DIR}" ] && [ ! -L "${INSTALL_DIR}" ]; then
    log_warn "安装目录不存在（可能已被清理）：${INSTALL_DIR}"
    if [ -L "${LINK_DIR}" ]; then
        rm -f "${LINK_DIR}"
        log_ok "已移除失效软链：${LINK_DIR}"
    fi
    log_ok "${APP_TITLE} uninstalling successful"
    exit 0
fi

# 删除前的安全校验：必须位于 APPS_DIR 之下且是其直接子目录
assert_under_apps_dir "${INSTALL_DIR}" "${APPS_DIR}" || exit 1

# 移除软链
if [ -L "${LINK_DIR}" ]; then
    rm -f "${LINK_DIR}"
    log_ok "已移除软链：${LINK_DIR}"
fi

# 删除前最后一道校验
[ -d "${INSTALL_DIR}" ] || {
    log_error "目录状态已变化，中止删除：${INSTALL_DIR}"
    exit 1
}
rm -rf "${INSTALL_DIR}"
log_ok "已删除安装目录：${INSTALL_DIR}"

log_ok "${APP_TITLE} uninstalling successful"
