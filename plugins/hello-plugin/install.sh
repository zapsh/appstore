#!/bin/sh
# AppStore 安装钩子：把插件目录落到 $ZAP_PATH/plugins/<name>。
# 由 zapexec 以 root 执行（系统级插件）。环境变量由应用商店注入：
#   ZAP_PATH   面板安装根（如 /usr/local/zap）
#   APP_NAME   插件名（来自 app.yaml 的 name，等于目录名）
#   PKG_SRC_PATH 仓库里本插件包源码目录
set -e

DEST="$ZAP_PATH/plugins/$APP_NAME"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$PKG_SRC_PATH/." "$DEST/"

# 去掉应用商店专属的编排文件，保持插件目录干净（前端只认 manifest.yaml / main.lua / ui.html）
rm -f "$DEST/app.yaml" "$DEST/install.sh" "$DEST/uninstall.sh"

echo "插件 $APP_NAME 已安装到 $DEST"
