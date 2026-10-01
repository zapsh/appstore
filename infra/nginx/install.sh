#!/bin/bash
#=============================================================================
# Nginx 常规编译安装脚本(zap appstore 调用,root 执行)
#
# 特性:
#   * 依赖源码(zlib / pcre2 / openssl)全部编译进 nginx,运行时仅依赖 glibc;
#   * OpenSSL 一律走源码捆绑编译(默认 3.5.6,可用 OPENSSL_VERSION 覆盖),
#     不依赖系统 libssl 版本;
#   * 覆盖常规模块:http ssl/v2/realip/addition/sub/dav/flv/mp4/gunzip/
#     gzip_static/auth_request/random_index/secure_link/slice/stub_status,
#     stream(含 ssl/ssl_preread/realip/slice)、threads、file-aio;
#   * 默认具备请求限速(http_limit_req)与并发限制(http_limit_conn):两者自 0.7.x
#     起就是 nginx 默认模块(只有 --without- 反向开关),脚本会剔除任何关掉它们的
#     参数,站点「安全」页的限速 / 并发能力始终可用;
#   * 默认支持 IPv6:1.11.5 起默认编译(1.31.x 上 --with-ipv6 已废弃,传了只打
#     告警),仅旧版本才显式补 --with-ipv6;
#   * 兼容历史变量 MODULES / EXTRA_CONFIG(安装选项已移除,环境变量注入仍生效);
#   * 修复 systemd 模板硬编码路径:按实际安装目录生成 nginx.service;
#   * 登记 info.yaml(svc_name=nginx),Web 端「已安装」可启停/查看状态。
#
# 依赖环境变量(由 zapexec 注入):ZAP_PATH ZAPCTL APPS_DIR PKG_PATH APP_PATH
#   APP_ID APP_NAME APP_VERSION BUILD_PATH CPU_NUM [MAJOR_VERSION MINOR_VERSION]
#
# 可覆盖(环境变量):
#   OPENSSL_VERSION= 捆绑编译的 OpenSSL 源码版本  默认 3.5.6
#   OPENSSL_SRC_DIR= 已有 openssl 源码树路径(优先使用,跳过下载)
#   ZLIB_VERSION   / PCRE2_VERSION              默认 1.3.1 / 10.48
#   MODSEC_LIB_TARBALL / MODSEC_CONNECTOR_TARBALL / MODSEC_CRS_TARBALL
#        = 下载源 modsecurity/ 下的实际包名(默认见下方常量,只填文件名)
#   NGINX_MIRROR   = 镜像 base                  默认取配置的下载源(见 bash_utils::pkg_mirror)
#=============================================================================
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 可配置常量 ────────────────────────────────────────────────────────────
NGINX_MIRROR="${NGINX_MIRROR:-$(pkg_mirror)}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
PCRE2_VERSION="${PCRE2_VERSION:-10.48}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"
# ModSecurity(WAF,安装选项 MODSECURITY=true 时启用)
MODSEC_VERSION="${MODSEC_VERSION:-3.0.16}"
MODSEC_CONNECTOR_VERSION="${MODSEC_CONNECTOR_VERSION:-1.0.4}"
MODSEC_CRS_VERSION="${MODSEC_CRS_VERSION:-4.29.0}"
MODSEC_PREFIX="${MODSEC_PREFIX:-/usr/local/modsecurity}"
# 规则与主配置落面板自有的 nginx 目录(与四层转发的 zap-stream.conf 同级):
# 重装 / 升级 nginx 都不会把规则带走
MODSEC_WAF_CONF="/etc/zap/nginx/modsecurity"
case "$(echo "${MODSECURITY:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) WAF_ENABLED=1 ;;
    *) WAF_ENABLED=0 ;;
esac

INSTALL_PATH="${APPS_DIR}/nginx"
NGINX_SRC="nginx-${APP_VERSION}"
ZLIB_SRC="zlib-${ZLIB_VERSION}"
PCRE2_SRC="pcre2-${PCRE2_VERSION}"
OPENSSL_SRC="openssl-${OPENSSL_VERSION}"
# ModSecurity:下载源 modsecurity/ 下的固定包名(镜像命名不统一时用环境变量覆盖)
MODSEC_LIB_PKG="${MODSEC_LIB_TARBALL:-modsecurity-v${MODSEC_VERSION}.tar.gz}"
MODSEC_CONN_PKG="${MODSEC_CONNECTOR_TARBALL:-ModSecurity-nginx-v${MODSEC_CONNECTOR_VERSION}.tar.gz}"
MODSEC_CRS_PKG="${MODSEC_CRS_TARBALL:-coreruleset-${MODSEC_CRS_VERSION}-minimal.tar.gz}"

# ── 前置:用户 / 目录 / 首次系统依赖 ─────────────────────────────────────
prepare_install_env www

# 编译目标目录需为 zapexec 按本次运行注入的专属路径(runs/<run_id>/build,
# run_id 动态,故按前缀模式校验);异常时拒绝清理,避免误删
if [[ "${BUILD_PATH}" != "${ZAP_PATH}/data/appstore/runs/"*"/build" ]]; then
    log_error "BUILD_PATH 异常(${BUILD_PATH}),拒绝清理"
    exit 1
fi
rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}" "${APP_PATH}"
cd "${PKG_PATH}"

# ── 下载依赖源码(失败即退出) ─────────────────────────────────────────────
log_info "下载/校验依赖源码 ..."
if [ ! -f "${NGINX_SRC}.tar.gz" ]; then
    log_info "download nginx-${APP_VERSION}"
    fetch_file "${NGINX_MIRROR}/nginx/${NGINX_SRC}.tar.gz" "${NGINX_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${ZLIB_SRC}.tar.gz" ]; then
    log_info "download ${ZLIB_SRC}"
    fetch_file "${NGINX_MIRROR}/zlib/${ZLIB_SRC}.tar.gz" "${ZLIB_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${PCRE2_SRC}.tar.gz" ]; then
    log_info "download ${PCRE2_SRC}"
    fetch_file "${NGINX_MIRROR}/pcre2/${PCRE2_SRC}.tar.gz" "${PCRE2_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${OPENSSL_SRC}.tar.gz" ]; then
    log_info "download ${OPENSSL_SRC}"
    fetch_file "${NGINX_MIRROR}/openssl/${OPENSSL_SRC}.tar.gz" "${OPENSSL_SRC}.tar.gz" || exit 1
fi

# ── 解压 nginx / zlib / pcre2 ─────────────────────────────────────────────
log_info "解压源码包 ..."
tar -xzf "${ZLIB_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${NGINX_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${PCRE2_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${OPENSSL_SRC}.tar.gz" -C "${BUILD_PATH}"

# ── 清理旧的安装残留 ───────────────────────────────────────────────────
# 新布局:直接装到 ${APPS_DIR}/nginx(无版本号)。兼容旧版「版本化目录 + 软链」
# 残留,升级时一并清掉,避免 appstore 扫到重复的 nginx 记录。
if [ -d "${INSTALL_PATH}" ]; then
    log_warn "检测到已存在 ${INSTALL_PATH},备份 conf 后重新安装"
    if [ -d "${INSTALL_PATH}/conf" ]; then
        ensure_dir /root/zap_bak/nginx
        cp -Rf "${INSTALL_PATH}/conf" "/root/zap_bak/nginx/conf.$(date +%Y%m%d%H%M%S)" || true
    fi
    rm -rf "${INSTALL_PATH}"
fi
# 旧版遗留:nginx-<version> 真实目录(曾被 ${APPS_DIR}/nginx 软链指向过)
if [ -e "${APPS_DIR}/nginx-${APP_VERSION}" ] && [ "${APPS_DIR}/nginx-${APP_VERSION}" != "${INSTALL_PATH}" ]; then
    log_warn "清理旧版版本化目录 ${APPS_DIR}/nginx-${APP_VERSION}"
    rm -rf "${APPS_DIR}/nginx-${APP_VERSION}"
fi

# ── ModSecurity 构建依赖(按发行版取包名) ──────────────────────────────────
# 复用 bash_utils 的 pkg_manager / pkg_install_any:apt / dnf / yum / apk / zypper
# 全覆盖,不像只认 apt 的写法那样在非 deb 系上默认"假定已具备"。
# 装不上只告警、不中止:缺头文件会在 libmodsecurity 的 configure 阶段暴露,
# 不该因为某个发行版改了包名就让整次 nginx 安装失败(与 install_system_deps 同一取向)。
install_modsec_deps() {
    local pm common="" p rc=0
    pm="$(pkg_manager)" || {
        log_warn "未识别到包管理器(${OS_NAME:-unknown}),跳过 ModSecurity 构建依赖安装"
        return 1
    }
    case "${pm}" in
    apt)
        apt-get update -qq >/dev/null 2>&1 || true
        common="libtool autoconf automake g++ make pkg-config flex bison libxml2-dev libyajl-dev"
        ;;
    dnf | yum)
        common="libtool autoconf automake gcc-c++ make pkgconfig flex bison libxml2-devel yajl-devel"
        ;;
    apk)
        common="build-base autoconf automake libtool flex bison pkgconf libxml2-dev yajl-dev"
        ;;
    zypper)
        common="libtool autoconf automake gcc-c++ make pkg-config flex bison libxml2-devel yajl-devel"
        ;;
    esac

    log_info "${pm} 安装 ModSecurity 构建依赖 ..."
    # 先批量,失败再逐项补装(个别包缺失忽略)—— 与 install_system_deps 同一套路
    case "${pm}" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${common} >/dev/null 2>&1 ;;
    apk) apk add --no-cache ${common} >/dev/null 2>&1 ;;
    *) "${pm}" install -y ${common} >/dev/null 2>&1 ;;
    esac || {
        log_warn "批量安装失败,逐项补装 ..."
        for p in ${common}; do
            pkg_install_any "${pm}" "${p}" || rc=1
        done
    }

    # 版本间最容易改名的几个:逐个给候选,装上任意一个即可
    #   pcre : modsecurity 3.x 只认 pcre2(pcre3 没有 pcre2.h → 编译期 fatal error),
    #          故 pcre2 优先;pcre3 仅作老系统的退路
    #   curl : deb 系三个实现包(openssl/gnutls/通用)名字不一样
    #   geoip: 可选依赖(GeoIP 支持),老包在新系统上已被移除 → 装不上不算失败
    case "${pm}" in
    apt)
        pkg_install_any "${pm}" libpcre2-dev libpcre3-dev || rc=1
        pkg_install_any "${pm}" libcurl4-openssl-dev libcurl4-gnutls-dev libcurl-dev || rc=1
        pkg_install_any "${pm}" libgeoip-dev libmaxminddb-dev || true
        ;;
    dnf | yum)
        pkg_install_any "${pm}" pcre2-devel pcre-devel || rc=1
        pkg_install_any "${pm}" libcurl-devel || rc=1
        pkg_install_any "${pm}" GeoIP-devel libmaxminddb-devel || true
        ;;
    apk)
        pkg_install_any "${pm}" pcre2-dev pcre-dev || rc=1
        pkg_install_any "${pm}" curl-dev || rc=1
        ;;
    zypper)
        pkg_install_any "${pm}" pcre2-devel pcre-devel || rc=1
        pkg_install_any "${pm}" libcurl-devel || rc=1
        ;;
    esac

    if [ "${rc}" -eq 0 ]; then
        log_ok "ModSecurity 构建依赖就绪"
    else
        log_warn "部分构建依赖未装上,若 libmodsecurity 编译报缺头文件/库请手动补装"
    fi
    return "${rc}"
}

# ── pcre2:libmodsecurity 的硬依赖 ────────────────────────────────────────
# modsecurity 3.x 一律 #include <pcre2.h>,pcre3 开发包里没有这个头文件,
# 于是编译 transaction.cc 时直接 fatal error。系统开发包优先;系统里没有
# (离线源 / 老发行版)就用 build 里那份 pcre2 源码编一份 —— 它正是 nginx
# --with-pcre 要用的源码树,两边版本天然一致。--disable-shared + --with-pic
# 让它静态链进 libmodsecurity.so,运行时不额外依赖系统的 libpcre2。
# 注意:结果经全局变量返回,**不要**写成 OPT="$(modsec_pcre2_option)" ——
# log_info 打的是 stdout,命令替换会把日志连同时间戳一起吞进变量,
# 于是 configure 收到 "[2026-09-26 ..." 当 build system type,直接 config.sub 报错。
modsec_pcre2_option() {   # 设置 MODSEC_PCRE2_OPT(系统已有 pcre2 时为空);失败返回 1
    MODSEC_PCRE2_OPT=""
    if [ -f /usr/include/pcre2.h ] || [ -f /usr/local/include/pcre2.h ] \
        || pkg-config --exists libpcre2-8 2>/dev/null; then
        return 0
    fi
    local src="${BUILD_PATH}/${PCRE2_SRC}" stage="${BUILD_PATH}/pcre2-stage"
    log_info "系统缺 pcre2 头文件,用 ${PCRE2_SRC} 源码编译一份给 libmodsecurity ..."
    if [ ! -f "${stage}/include/pcre2.h" ]; then
        ( cd "${src}" &&
            ./configure --prefix="${stage}" --disable-shared --with-pic >/dev/null 2>&1 &&
            make -j "${CPU_NUM:-$(cpu_count)}" >/dev/null 2>&1 &&
            make install >/dev/null 2>&1 ) || {
            log_error "pcre2 源码编译失败,libmodsecurity 缺 pcre2.h 无法继续"
            return 1
        }
    fi
    MODSEC_PCRE2_OPT="--with-pcre2=${stage}"
    return 0
}

# ── ModSecurity(WAF,可选):规则引擎 + nginx 连接器 ───────────────────────
# 动态模块只能在编译时加入:nginx 必须带 --with-compat,否则模块签名不匹配、
# load_module 会被拒。已装好的 nginx 无法后期加装,所以这是唯一的时机。
if [ "${WAF_ENABLED}" = "1" ]; then
    log_info "安装选项:编译 ModSecurity(WAF) 支持 ..."
    # 1) 构建依赖:按发行版装(apt / dnf / yum / apk / zypper),装不全只告警
    install_modsec_deps || true
    # 2) libmodsecurity(规则引擎):与 pcre2 一样,从下载源按固定包名直接取,不走 GitHub
    cd "${PKG_PATH}"
    if [ ! -f "${MODSEC_LIB_PKG}" ]; then
        log_info "download ${MODSEC_LIB_PKG}"
        fetch_file "${NGINX_MIRROR}/modsecurity/${MODSEC_LIB_PKG}" "${MODSEC_LIB_PKG}" || {
            log_error "libmodsecurity 源码下载失败,中止(取消该选项可继续安装纯 nginx)"
            exit 1
        }
    fi
    # libmodsecurity 强制依赖 pcre2:先落实(系统包 → 源码兜底),拿不到就别浪费
    # 几分钟编译,直接中止
    if ! modsec_pcre2_option; then
        log_error "libmodsecurity 需要 pcre2,请安装 libpcre2-dev(deb)/pcre2-devel(rpm)"
        exit 1
    fi
    # 顶层目录名随包而异(libmodsecurity-vX / ModSecurity-vX …),从包里读出来,不猜。
    # 不能用 `tar -tzf x | head -1`:包内条目 6000+/500KB,head 读一行就退出,tar 接着
    # 写管道必吃 SIGPIPE,开着 pipefail 时整条管道判 141,set -e 于是把安装直接干掉。
    # 改用 sed(不提前退出,让 tar 把话说完),失败也留一句能看懂的话。
    MODSEC_SRC="$(tar -tzf "${MODSEC_LIB_PKG}" | sed -n '1{s|/.*||;p;}')"
    if [ -z "${MODSEC_SRC}" ]; then
        log_error "从 ${MODSEC_LIB_PKG} 读不出顶层目录名(包损坏?)"
        exit 1
    fi
    tar -xzf "${MODSEC_LIB_PKG}" -C "${BUILD_PATH}"
    (
        cd "${BUILD_PATH}/${MODSEC_SRC}" &&
            ./build.sh &&
            ./configure --prefix="${MODSEC_PREFIX}" --without-lmdb ${MODSEC_PCRE2_OPT} &&
            make -j "${CPU_NUM:-$(cpu_count)}" &&
            make install
    ) || {
        log_error "libmodsecurity 编译失败,中止"
        exit 1
    }
    # nginx 启动时靠 ldconfig 找 libmodsecurity.so.3
    echo "${MODSEC_PREFIX}/lib" >/etc/ld.so.conf.d/zap-modsecurity.conf
    if [ -d "${MODSEC_PREFIX}/lib64" ]; then
        echo "${MODSEC_PREFIX}/lib64" >>/etc/ld.so.conf.d/zap-modsecurity.conf
    fi
    ldconfig || true
    # soname 要写全:have_lib 是按 soname 精确/通配匹配的,只写 libmodsecurity
    # 匹配不上 libmodsecurity.so.3(缓存里没有叫这个名字的条目),它的文件系统兜底
    # 也只扫默认目录、不含 ${MODSEC_PREFIX}/lib → 库明明在也会被判成没装。
    # 再补一道文件检查:容器里 ldconfig 未必生效,库是自己刚装的,路径是确定的。
    if ! have_lib 'libmodsecurity.so.*' \
        && ! ls "${MODSEC_PREFIX}"/lib/libmodsecurity.so* >/dev/null 2>&1; then
        log_error "libmodsecurity 未装到 ${MODSEC_PREFIX}/lib,中止"
        exit 1
    fi
    # 3) ModSecurity-nginx 连接器(动态模块源码)
    if [ ! -f "${MODSEC_CONN_PKG}" ]; then
        log_info "download ${MODSEC_CONN_PKG}"
        fetch_file "${NGINX_MIRROR}/modsecurity/${MODSEC_CONN_PKG}" "${MODSEC_CONN_PKG}" || {
            log_error "ModSecurity-nginx 连接器下载失败,中止"
            exit 1
        }
    fi
    MODSEC_CONNECTOR_DIR="${BUILD_PATH}/ModSecurity-nginx"
    mkdir -p "${MODSEC_CONNECTOR_DIR}"
    tar -xzf "${MODSEC_CONN_PKG}" -C "${MODSEC_CONNECTOR_DIR}" --strip-components=1
    log_ok "libmodsecurity ${MODSEC_VERSION} 与连接器就绪"
fi

# ── configure:常规模块 + 依赖 ─────────────────────────────────────────────
log_info "开始编译 nginx-${APP_VERSION}(OpenSSL ${OPENSSL_VERSION}) ..."
cd "${BUILD_PATH}/${NGINX_SRC}"

configure_args=(
    --user=www
    --group=www
    --prefix="${INSTALL_PATH}"
    --pid-path=/var/run/nginx.pid
    --error-log-path=/var/log/nginx/error.log
    --http-log-path=/var/log/nginx/access.log
    # http 常规模块
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module
    --with-http_addition_module
    --with-http_sub_module
    --with-http_dav_module
    --with-http_flv_module
    --with-http_mp4_module
    --with-http_gunzip_module
    --with-http_gzip_static_module
    --with-http_auth_request_module
    --with-http_random_index_module
    --with-http_secure_link_module
    --with-http_slice_module
    --with-http_stub_status_module
    # 常规流媒体 / 基础
    --with-threads
    --with-file-aio
    # stream(TCP/UDP 反代)
    --with-stream
    --with-stream_ssl_module
    --with-stream_ssl_preread_module
    --with-stream_realip_module
    # 依赖(源码树编译)
    --with-pcre="${BUILD_PATH}/${PCRE2_SRC}"
    --with-zlib="${BUILD_PATH}/${ZLIB_SRC}"
    --with-openssl="${BUILD_PATH}/${OPENSSL_SRC}"
    --with-openssl-opt=no-async
)

# 历史安装选项(MODULES / EXTRA_CONFIG,表单已移除,环境变量注入仍兼容)
if [ -n "${EXTRA_CONFIG:-}" ]; then
    read -r -a extra_args <<< "${EXTRA_CONFIG}"
    configure_args+=("${extra_args[@]}")
fi
if [ -n "${MODULES:-}" ]; then
    read -r -a module_args <<< "${MODULES}"
    configure_args+=("${module_args[@]}")
fi

# ── 能力保障:请求限速 / 并发限制 / IPv6 ────────────────────────────────
# limit_req / limit_conn 是 nginx 默认模块,只能 --without-* 关掉;站点「安全」
# 页的请求限速与并发限制依赖它们,故剔除任何反向开关。
kept_args=()
for arg in "${configure_args[@]}"; do
    case "${arg}" in
        --without-http_limit_req_module|--without-http_limit_conn_module)
            log_warn "忽略 ${arg}:站点限速 / 并发限制依赖该模块,已强制保留" ;;
        *) kept_args+=("${arg}") ;;
    esac
done
configure_args=("${kept_args[@]}")

# IPv6:旧版本(仍支持该开关且未废弃)显式开启,新版靠默认编译,避免 deprecated 告警
if grep -Eq '^[[:space:]]*--with-ipv6\)' auto/options \
    && ! grep -A2 -E '^[[:space:]]*--with-ipv6\)' auto/options | grep -q 'deprecated'; then
    configure_args+=(--with-ipv6)
    log_info "显式开启 IPv6(--with-ipv6)"
else
    log_info "IPv6:由 nginx 默认编译支持(无需 --with-ipv6)"
fi
if [ "${WAF_ENABLED}" = "1" ]; then
    # --with-compat 是动态模块的前提(模块签名匹配),缺了它 load_module 会直接被拒
    configure_args+=(--with-compat --add-dynamic-module="${MODSEC_CONNECTOR_DIR}")
fi

log_info "configure ..."
./configure "${configure_args[@]}"
log_ok "configure 完成,开始 make(并行 ${CPU_NUM:-auto})"
make -j "${CPU_NUM:-$(cpu_count)}"
make install
if [ ! -x "${INSTALL_PATH}/sbin/nginx" ]; then
    log_error "make install 未产出 nginx 二进制,安装失败"
    exit 1
fi
log_ok "nginx 编译安装完成: ${INSTALL_PATH}"

# ── 配置目录 / 默认站点 / dhparam ────────────────────────────────────────
ensure_dir "${INSTALL_PATH}/conf/conf.d" "${INSTALL_PATH}/conf/sites-enabled" /var/log/nginx

if [ ! -f "${INSTALL_PATH}/conf/dhparam.pem" ]; then
    log_info "生成 dhparam.pem(2048,可能需要几秒)..."
    openssl dhparam -out "${INSTALL_PATH}/conf/dhparam.pem" 2048 || true
fi

cp -f "${ZAP_PATH}/scripts/zap/conf/nginx.conf" "${INSTALL_PATH}/conf/nginx.conf"
# 默认站点不再由安装脚本下发:面板把它托管在
# /etc/zap/webservers/nginx/sites-enabled/00-default.conf(stub_status 状态页也挂在
# 那儿)。这里再放一份 default.conf,两份都写 listen 80 default_server →
# nginx -t 直接 [emerg] duplicate default server,安装完起不来。
# 空目录无妨:nginx.conf 里的 include sites-enabled/*.conf 是通配,匹配不到不报错。
# 确保模板引用的 mime.types 存在(make install 通常已生成)
if [ ! -f "${INSTALL_PATH}/conf/mime.types" ] && [ -f "${BUILD_PATH}/${NGINX_SRC}/conf/mime.types" ]; then
    cp -f "${BUILD_PATH}/${NGINX_SRC}/conf/mime.types" "${INSTALL_PATH}/conf/mime.types"
fi

# ── ModSecurity:部署 OWASP CRS 并启用(默认只记录不拦截) ────────────────
if [ "${WAF_ENABLED}" = "1" ]; then
    log_info "部署 OWASP CRS 规则集 ..."
    ensure_dir "${MODSEC_WAF_CONF}"
    cd "${PKG_PATH}"
    if [ ! -f "${MODSEC_CRS_PKG}" ]; then
        log_info "download ${MODSEC_CRS_PKG}"
        fetch_file "${NGINX_MIRROR}/modsecurity/${MODSEC_CRS_PKG}" "${MODSEC_CRS_PKG}" || {
            log_error "OWASP CRS 下载失败,中止"
            exit 1
        }
    fi
    ensure_dir "${MODSEC_WAF_CONF}/rules"
    tar -xzf "${MODSEC_CRS_PKG}" -C "${MODSEC_WAF_CONF}" --strip-components=1
    if [ ! -f "${MODSEC_WAF_CONF}/crs-setup.conf" ] && [ -f "${MODSEC_WAF_CONF}/crs-setup.conf.example" ]; then
        cp -f "${MODSEC_WAF_CONF}/crs-setup.conf.example" "${MODSEC_WAF_CONF}/crs-setup.conf"
    fi

    # 主配置:DetectionOnly —— 装完先看审计日志,确认没误杀业务再改 On
    # Include 写成条件式:一个缺失的文件就能让 nginx -t 直接失败,不值得赌
    {
        echo "# zap 生成:ModSecurity 主配置(OWASP CRS ${MODSEC_CRS_VERSION})"
        echo "SecRuleEngine DetectionOnly"
        echo "SecRequestBodyAccess On"
        echo "SecAuditEngine RelevantOnly"
        echo 'SecAuditLogRelevantStatus "^(?:5|4(?!04))"'
        echo "SecAuditLogParts ABIJDEFHZ"
        echo "SecAuditLogType Serial"
        echo "SecAuditLog /var/log/modsec_audit.log"
        if [ -f "${MODSEC_WAF_CONF}/crs-setup.conf" ]; then
            echo "Include ${MODSEC_WAF_CONF}/crs-setup.conf"
        fi
        if [ -d "${MODSEC_WAF_CONF}/rules" ]; then
            echo "Include ${MODSEC_WAF_CONF}/rules/*.conf"
        fi
    } >"${MODSEC_WAF_CONF}/modsecurity.conf"

    # http 上下文指令单独成文件(主配置已 include conf.d/*.conf),不动模板
    cat >"${INSTALL_PATH}/conf/conf.d/modsecurity.conf" <<EOF
# zap 生成:WAF 启用(http 上下文)
modsecurity on;
modsecurity_rules_file ${MODSEC_WAF_CONF}/modsecurity.conf;
EOF

    # load_module 必须在 nginx.conf 最外层顶部
    if ! grep -q "ngx_http_modsecurity_module.so" "${INSTALL_PATH}/conf/nginx.conf"; then
        sed -i "1i load_module modules/ngx_http_modsecurity_module.so;" "${INSTALL_PATH}/conf/nginx.conf"
    fi

    # 兜底:WAF 只要让 nginx 起不来就撤掉它 —— nginx 本体必须可用
    if ! "${INSTALL_PATH}/sbin/nginx" -t >/dev/null 2>&1; then
        log_error "WAF 配置未通过 nginx -t,已移除 WAF 配置(nginx 仍可用):"
        "${INSTALL_PATH}/sbin/nginx" -t || true
        rm -f "${INSTALL_PATH}/conf/conf.d/modsecurity.conf"
        sed -i "/ngx_http_modsecurity_module.so/d" "${INSTALL_PATH}/conf/nginx.conf"
    else
        log_ok "WAF 就绪:模块已加载,引擎 DetectionOnly(审计日志 /var/log/modsec_audit.log)"
    fi
fi

# ── 安装目录即 ${APPS_DIR}/nginx(无版本号,固定路径) ───────────────────
# 不再创建 /usr/local/apps/nginx 软链:旧版用「版本化目录 + 软链」会导致 appstore
# 把软链与真实目录扫成两条 nginx 记录。本版直接装到固定路径,仅此一条。
log_ok "nginx 安装目录: ${INSTALL_PATH}"

# ── 服务(修正模板中的硬编码路径,按实际安装目录生成) ────────────────────
# 说明:若先配置过站点需额外测试 nginx -t;此处直接写精确路径。
# 启动失败时把"真实原因"逐行打进日志 —— 光一句 start failed 没法排查。
# 用 <<< 喂给 read 而不是管道:管道开着 pipefail 会引来 SIGPIPE(141)。
nginx_diag() {   # nginx_diag <标题> <命令...>
    local title="$1" out line
    shift
    out="$("$@" 2>&1)" || true
    log_error "${title}"
    while IFS= read -r line; do
        [ -n "${line}" ] && log_error "    ${line}"
    done <<<"${out}"
}

SVC_CMD=""
if command -v systemctl >/dev/null 2>&1; then
    log_info "生成 systemd 服务 nginx.service(路径: ${INSTALL_PATH})"
    sed "s|/usr/local/apps/nginx|${INSTALL_PATH}|g" \
        "${ZAP_PATH}/scripts/systemd/nginx.service" > /etc/systemd/system/nginx.service
    chmod 644 /etc/systemd/system/nginx.service
    systemctl daemon-reload
    systemctl enable nginx.service >/dev/null 2>&1 || true
    if ! systemctl start nginx.service; then
        log_error "systemctl start nginx 失败。下面是三项自检输出(按此顺序看):"
        nginx_diag "① 配置自检(nginx -t):" "${INSTALL_PATH}/sbin/nginx" -t
        nginx_diag "② systemd 状态:" systemctl status nginx.service --no-pager -n 0
        nginx_diag "③ 最近 15 行日志:" journalctl -u nginx.service --no-pager -n 15
    fi
    SVC_CMD="systemctl"
else
    log_warn "未检测到 systemd,尝试 service nginx start"
    if command -v service >/dev/null 2>&1; then
        if ! service nginx start; then
            log_error "service nginx start 失败:"
            nginx_diag "配置自检(nginx -t):" "${INSTALL_PATH}/sbin/nginx" -t
        fi
        SVC_CMD="service"
    fi
fi
sleep 1

# ── 更新 zap 应用表(面板展示状态/可启停依赖 info.yaml) ──────────────────
# info.yaml 写入 APP_PATH(apps/<category>/<name>/),供 zapexec 探测与启停
cat > "${APP_PATH}/info.yaml" <<'YAML'
svc_name: nginx
instance: nginx
install_dir: __INSTALL_PATH__
version: ${APP_VERSION}
config_file: __INSTALL_PATH__/conf/nginx.conf
config_files:
  - path: __INSTALL_PATH__/conf/nginx.conf
    label: nginx.conf
  - path: __INSTALL_PATH__/conf/fastcgi.conf
    label: fastcgi.conf
  - path: __INSTALL_PATH__/conf/mime.types
    label: mime.types
pid_file: /var/run/nginx.pid
log_files:
  - /var/log/nginx/error.log
  - /var/log/nginx/access.log
expose: tcp:80
tags:
  - webserver
YAML
sed -i "s|__INSTALL_PATH__|${INSTALL_PATH}|g" "${APP_PATH}/info.yaml"

log_ok "nginx-${APP_VERSION} 安装完成(${INSTALL_PATH}),命令: ${SVC_CMD:-无} start/stop/restart"
if [ -n "${SVC_CMD}" ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$(systemctl is-active nginx.service)" != "active" ]; then
        log_warn "nginx 服务当前未运行:请看上方「三项自检」输出;也可手动执行"
        log_warn "    ${INSTALL_PATH}/sbin/nginx -t"
        log_warn "    systemctl status nginx.service"
    fi
fi
