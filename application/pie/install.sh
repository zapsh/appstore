#!/bin/bash
# PIE 安装脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
# 可选（options）：
#   PIE_PHAR_MIRROR select —— github（官方 latest stable，默认）/ zapsh（中国镜像）
#
# 说明：
#   * PIE 是单文件 phar，安装到 ${APPS_DIR}/pie/pie.phar，并注册全局命令 /usr/local/bin/pie。
#   * PIE 自身需要 PHP 8.1+ 运行；脚本优先用 PATH 上的 php（若 >= 8.1），否则在
#     ${APPS_DIR} 下查找 php-8*/php81 等 8.1+ 实例，写进包装脚本，确保 pie 始终以兼容的
#     PHP 运行（与目标实例无关——目标实例由 php_ext 的 --with-php-config 指定）。
#   * 下载源：官方走 GitHub latest stable；镜像走 pkg_mirror 的 /pie/pie.phar。
#   * PIE 官方未发布独立 checksum 文件，改用 gh attestation 校验（需 gh 且联网）；
#     脚本在环境具备时尽力校验，否则仅告警提示，不阻断安装。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 定位一个 PHP 8.1+ 来运行 PIE ────────────────────────
PHP_BIN=""
php_ge() {
    # 传入 php 路径，输出版本代号 MAJOR*100+MINOR，[0-9]+ 之外给 0
    "$1" -r 'echo PHP_MAJOR_VERSION * 100 + PHP_MINOR_VERSION;' 2>/dev/null || echo 0
}
if command -v php >/dev/null 2>&1; then
    if [ "$(php_ge "$(command -v php)")" -ge 801 ]; then
        PHP_BIN="$(command -v php)"
    fi
fi
if [ -z "${PHP_BIN}" ] && [ -n "${APPS_DIR:-}" ]; then
    for cand in "${APPS_DIR}"/php-8*/bin/php "${APPS_DIR}"/php81/bin/php; do
        [ -x "${cand}" ] || continue
        if [ "$(php_ge "${cand}")" -ge 801 ]; then
            PHP_BIN="${cand}"
            break
        fi
    done
fi
if [ -z "${PHP_BIN}" ]; then
    log_error "未找到 PHP 8.1+：PIE 自身需要 PHP 8.1+ 运行。请先在应用商店安装 PHP 8.1+ 并设为全局默认 PHP（或在 ${APPS_DIR} 下安装 php-81 实例）后再安装 PIE。"
    exit 1
fi
log_info "用于运行 PIE 的 PHP: $("${PHP_BIN}" -v | head -n1)"

# ── 安装位置 ─────────────────────────────────────────────
PIE_DIR="${APPS_DIR}/pie"
PIE_PHAR="${PIE_DIR}/pie.phar"
ensure_dir "${PIE_DIR}"

# ── 下载源 ───────────────────────────────────────────────
if [ -n "${PIE_PHAR_URL:-}" ]; then
    PHAR_URL="${PIE_PHAR_URL}"
    SRC_NAME="指定源（PIE_PHAR_URL）"
elif [ "${PIE_PHAR_MIRROR:-github}" = "zapsh" ]; then
    PHAR_URL="$(pkg_mirror | sed 's|mirrors\.zap\.cn|mirrors.zap.sh|')/pie/pie.phar"
    SRC_NAME="zap.sh 中国镜像"
else
    PHAR_URL="https://github.com/php/pie/releases/latest/download/pie.phar"
    SRC_NAME="github.com（官方 latest stable）"
fi
log_info "从 ${SRC_NAME} 下载 PIE: ${PHAR_URL}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
download_file "${PHAR_URL}" "${TMP}/pie.phar"
if [ ! -s "${TMP}/pie.phar" ]; then
    log_error "PIE phar 下载失败（文件为空）"
    exit 1
fi

# ── 尽力校验（官方未发布独立 checksum，仅 gh attestation 可用时校验）──
if command -v gh >/dev/null 2>&1; then
    if gh attestation verify --owner php "${TMP}/pie.phar" >/dev/null 2>&1; then
        log_ok "gh attestation 校验通过"
    else
        log_warn "gh attestation 校验未通过或不可用，继续安装（请确认下载源可信）"
    fi
else
    log_warn "未安装 gh，跳过 attestation 校验（请确认下载源可信）"
fi

install -m 0755 "${TMP}/pie.phar" "${PIE_PHAR}"
log_info "已安装: ${PIE_PHAR}"

# ── 注册全局命令（包装脚本，固定用上面的 PHP 8.1+ 运行 phar）──
cat > /usr/local/bin/pie <<EOF
#!/bin/bash
exec "${PHP_BIN}" "${PIE_PHAR}" "\$@"
EOF
chmod +x /usr/local/bin/pie
log_info "已注册全局命令 /usr/local/bin/pie"

# ── 验证可执行 ───────────────────────────────────────────
VERSION_LINE="$(pie --version --no-ansi 2>&1 | head -n1 || true)"
log_info "版本: ${VERSION_LINE}"

# ── 登记实例信息（apps/<category>/<name>/info.yaml）────────
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
install_dir: ${PIE_DIR}
global_bin: /usr/local/bin/pie
phar: ${PIE_PHAR}
php_bin: ${PHP_BIN}
version: ${VERSION_LINE}
EOF

log_info "PIE 安装成功: ${VERSION_LINE}"
