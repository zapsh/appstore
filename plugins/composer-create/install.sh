#!/bin/sh
# AppStore 安装钩子：把插件目录落到 $ZAP_PATH/plugins/<name>。
# 由 zapexec 以 root 执行（系统级插件）。环境变量由应用商店注入：
#   ZAP_PATH      面板安装根（如 /usr/local/zap）
#   APP_NAME      插件名（来自 app.yaml 的 name，等于目录名）
#   PKG_SRC_PATH  仓库里本插件包源码目录
set -e

# 落盘根目录：插件统一装到系统级 $ZAP_PATH/plugins（由调用方注入 PLUGIN_BASE）。
PLUGIN_BASE="${PLUGIN_BASE:-$ZAP_PATH/plugins}"
DEST="$PLUGIN_BASE/$APP_NAME"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$PKG_SRC_PATH/." "$DEST/"

# 去掉应用商店专属的编排文件，保持插件目录干净（前端只认 manifest.yaml / main.lua）
rm -f "$DEST/app.yaml" "$DEST/install.sh" "$DEST/uninstall.sh"
# 插件对所有用户只读可见（含站点账号 scope=site 读取），统一放开读权限
chmod -R a+rX "$DEST"

# ── 依赖检测（app.yaml: deps: [composer]）─────────────────────────────
# 本插件运行时依赖 composer（且 composer 需 PHP 支撑）。安装钩子只做检测、不自动安装：
# 缺失时提示管理员去应用商店安装「Composer」应用（application/composer），再回来装本插件。
# 不自动联网安装，避免污染系统、与 AppStore 的版本管理脱节。

if ! command -v php >/dev/null 2>&1; then
  echo "依赖检测失败：未检测到 PHP（composer 运行所需）。"
  echo "请先在应用商店安装 PHP（≥ 8.1），再安装本插件。"
  exit 1
fi
echo "依赖检测：PHP 已就绪 —— $(php -v 2>/dev/null | head -n1)"

if command -v composer >/dev/null 2>&1 || [ -x /usr/local/bin/composer ]; then
  echo "依赖检测：composer 已就绪 —— $(composer --version 2>/dev/null | head -n1 \
        || /usr/local/bin/composer --version 2>/dev/null | head -n1)"
else
  echo "依赖检测失败：未检测到 composer。"
  echo "请先在应用商店安装「Composer」应用（application/composer），安装完成后再安装本插件。"
  exit 1
fi

echo "依赖检测通过：composer 可用。"
echo "插件 $APP_NAME 已安装到 $DEST"
