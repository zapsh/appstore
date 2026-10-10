#!/bin/bash
# MySQL / MariaDB
# APP_FAMILY=mysql|mariadb
# APP_VERSION = 9.0.15  MAJOR_VERSION = 9 MINOR_VERSION = 0
# injected variables: ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION MAJOR_VERSION APP_FAMILY
set -euo pipefail

case "${APP_FAMILY:-}" in
    mysql)   FAMILY="mysql" ;;
    mariadb) FAMILY="mariadb" ;;
    *)
        echo "[mysql-mariadb] cannot determine install family: APP_FAMILY=${APP_FAMILY:-unknown} APP_VERSION=${APP_VERSION:-unknown}"
        echo "[mysql-mariadb] please check whether the version's family is declared in app.yaml's version_meta"
        exit 1
        ;;
esac

echo "[mysql-mariadb] family=${FAMILY} version=${APP_VERSION:-unknown} install.sh -> ${FAMILY}-install.sh"
exec bash "${BASH_SOURCE[0]%/*}/${FAMILY}-install.sh"
