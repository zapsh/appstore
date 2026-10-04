#!/bin/sh
# AppStore 卸载钩子：删除系统级插件目录。
# 环境变量同上（ZAP_PATH / APP_NAME）由应用商店注入。
set -e

DEST="$ZAP_PATH/plugins/$APP_NAME"
rm -rf "$DEST"
echo "已卸载插件 $APP_NAME（已创建的 Composer 项目与全局 composer 不受影响）"
