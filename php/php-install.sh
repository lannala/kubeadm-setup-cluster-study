#!/bin/bash
# ============================================================================
#  PHP + libzip + php-fpm 源码编译安装脚本
#
#  用法:
#     ./php_install.sh                          # 交互输入版本号
#     PHP_VERSION=<版本> ./php_install.sh
#
#  可用环境变量:
#     PHP_VERSION               # PHP 版本（不填则交互输入）
#     LIBZIP_VERSION            # libzip 版本（不填则交互输入；系统自带 >=0.11 时会跳过）
#     FORCE=1                   # 已安装时仍然重新编译
#
#  相比原脚本的改进:
#     1. ./configure 的返回值原来完全没判断，configure 失败照样继续 make，
#        最后报“Make Failed”，排查方向被带偏; 现在每一步失败都精确定位;
#     2. 依赖安装里写了不存在的包（如 libssl-devel），yum 会整行失败导致
#        一条依赖都没装上; 改为分组安装、单组失败不影响其他组，并去掉错包名;
#     3. 不再往 /etc/ld.so.conf 反复追加（每跑一次多一份），改用
#        /etc/ld.so.conf.d/php.conf;
#     4. 新旧版本的编译参数分开处理：新版 PHP 已移除 --with-gd/
#        --with-freetype-dir/--with-xmlrpc 等参数，原脚本在新版本上会 configure 失败;
#     5. www.conf / php.ini 只在不存在时生成，重复执行不会覆盖你改过的配置;
#     6. PATH 写入 /etc/profile.d/php.sh（幂等），不再往 ~/.bashrc 追加展开后的 PATH;
#     7. 装完轮询 php-fpm 是否真的起来，失败时给出日志位置，而不是直接宣称成功。
# ============================================================================
set -o pipefail

PHP_VERSION="${PHP_VERSION:-}"
LIBZIP_VERSION="${LIBZIP_VERSION:-}"
FORCE="${FORCE:-0}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/data}"
SRC_DIR="${SRC_DIR:-/data}"
SEARCH_DIRS=(/root /data /tmp /opt /usr/local /usr/src "$PWD")

C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_END=$'\033[0m'
[[ -t 1 ]] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_END=''; }

info() { echo -e "${C_YELLOW}[INFO]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
err()  { echo -e "${C_RED}[FAIL]${C_END} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行本脚本"; }

find_one() {
    local pattern="$1" type="$2" dir found
    for dir in "${SEARCH_DIRS[@]}"; do
        [[ -d $dir ]] || continue
        found=$(find "$dir" -maxdepth 4 -name "$pattern" -type "$type" -print -quit 2>/dev/null)
        [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
    done
    found=$(find / -xdev -name "$pattern" -type "$type" -print -quit 2>/dev/null)
    [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
    return 1
}

rpm_has() { rpm -q "$1" >/dev/null 2>&1; }

# --------------------------------- 版本 --------------------------------------
php_major() { printf '%s' "${PHP_VERSION%%.*}"; }
PHP_PREFIX=""
PHP_SRC=""

set_paths() {
    PHP_PREFIX="/usr/local/php$(php_major)"
    PHP_CONF_DIR="${PHP_PREFIX}/etc"
    FPM_CONF="${PHP_CONF_DIR}/php-fpm.conf"
    FPM_POOL="${PHP_CONF_DIR}/php-fpm.d/www.conf"
    PHP_SRC="${SRC_DIR}/php-${PHP_VERSION}"
}

# --------------------------------- 依赖 --------------------------------------
install_deps() {
    info "安装编译依赖（分组安装，单组失败不影响后续）..."

    yum install -y wget make gcc gcc-c++ autoconf pkgconfig re2c bc \
        || err "基础编译工具安装失败，请检查网络或软件源"

    yum install -y pcre pcre-devel zlib zlib-devel bzip2-devel \
        openssl openssl-devel libcurl-devel libicu-devel \
        glibc glibc-devel glib2 glib2-devel \
        libxml2 libxml2-devel libxslt libxslt-devel \
        || err "常用开发库安装失败（PHP 可能缺少部分扩展）"

    yum install -y libjpeg libjpeg-devel libpng libpng-devel \
        freetype freetype-devel libwebp-devel libXpm-devel gd gd-devel \
        || err "图像处理库安装失败（GD 相关扩展会被跳过）"

    yum install -y libsqlite3x-devel gmp-devel oniguruma oniguruma-devel \
        libmcrypt-devel libmhash-devel aspell-devel \
        || info "部分扩展库在源里不存在（EPEL 未启用时较常见），不影响主流程"

    yum install -y net-tools lrzsz tree tcl telnet vim ntpdate git \
        || info "常用工具安装失败，不影响 PHP 编译"

    have ntpdate && ntpdate ntp1.aliyun.com >/dev/null 2>&1 || true
    have timedatectl && timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1 || true

    # 关键依赖缺失时提前提示，避免 configure 阶段才发现
    local miss=()
    have gcc || miss+=(gcc)
    rpm_has pcre-devel || miss+=(pcre-devel)
    rpm_has libxml2-devel || miss+=(libxml2-devel)
    rpm_has openssl-devel || miss+=(openssl-devel)
    ((${#miss[@]})) && err "以下关键依赖缺失: ${miss[*]}，configure 很可能失败"
}

# --------------------------------- libzip ------------------------------------
# 用 sort -V 比较版本，不依赖 bc
version_ge() {
    [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]
}

libzip_ok() {
    have pkg-config || return 1
    pkg-config --exists libzip 2>/dev/null || return 1
    local ver
    ver=$(pkg-config --modversion libzip 2>/dev/null)
    [[ -n $ver ]] || return 1
    version_ge "0.11" "$ver"
}

install_libzip() {
    local tarball url

    if [[ -z $LIBZIP_VERSION ]]; then
        [[ -t 0 ]] || die "非交互环境请用 LIBZIP_VERSION=<版本> 指定 libzip 版本"
        read -r -p "$(printf '%b' "${C_YELLOW}请输入要安装的 libzip 版本: ${C_END}")" LIBZIP_VERSION
        [[ -n $LIBZIP_VERSION ]] || die "libzip 版本号不能为空"
    fi

    info "安装 libzip ${LIBZIP_VERSION} ..."
    tarball=$(find_one "libzip-${LIBZIP_VERSION}.tar.gz" f) || true

    if [[ -z $tarball ]]; then
        mkdir -p "$DOWNLOAD_DIR"
        tarball="${DOWNLOAD_DIR}/libzip-${LIBZIP_VERSION}.tar.gz"
        url="https://libzip.org/download/libzip-${LIBZIP_VERSION}.tar.gz"
        info "下载: ${url}"
        if have wget; then
            wget -q --show-progress -O "$tarball" "$url" || { rm -f "$tarball"; die "libzip 下载失败"; }
        else
            curl -fsSL -o "$tarball" "$url" || { rm -f "$tarball"; die "libzip 下载失败"; }
        fi
    fi

    tar -tzf "$tarball" >/dev/null 2>&1 || die "libzip 安装包损坏: ${tarball}"
    tar -xzf "$tarball" -C "$SRC_DIR" || die "解压 libzip 失败"

    (
        cd "${SRC_DIR}/libzip-${LIBZIP_VERSION}" || exit 1
        ./configure --prefix=/usr/local || die "libzip configure 失败"
        make -j"$(nproc 2>/dev/null || echo 2)" || die "libzip make 失败"
        make install || die "libzip make install 失败"
    ) || exit 1

    # 只写一次，不再往 /etc/ld.so.conf 里反复追加
    mkdir -p /etc/ld.so.conf.d
    printf '/usr/local/lib\n/usr/local/lib64\n' > /etc/ld.so.conf.d/php-libzip.conf
    ldconfig

    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    # 某些版本的 zipconf.h 不随 make install 落到 include 目录
    if [[ ! -f /usr/local/include/zipconf.h && -f /usr/local/lib/libzip/include/zipconf.h ]]; then
        cp /usr/local/lib/libzip/include/zipconf.h /usr/local/include/zipconf.h
    fi

    ok "libzip 安装完成"
}

ensure_libzip() {
    if libzip_ok; then
        ok "系统已满足 libzip 要求（$(pkg-config --modversion libzip)），跳过编译"
        return 0
    fi
    install_libzip
}

# --------------------------------- 源码准备 ----------------------------------
prepare_php_source() {
    local tarball url

    tarball=$(find_one "php-${PHP_VERSION}.tar.gz" f) || true
    if [[ -n $tarball ]]; then
        info "使用本地安装包: ${tarball}"
    else
        mkdir -p "$DOWNLOAD_DIR"
        tarball="${DOWNLOAD_DIR}/php-${PHP_VERSION}.tar.gz"
        url="https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz"
        info "本地无安装包，开始下载: ${url}"
        if have wget; then
            wget -q --show-progress -O "$tarball" "$url" || { rm -f "$tarball"; die "下载失败，版本 ${PHP_VERSION} 可能不存在"; }
        else
            curl -fsSL -o "$tarball" "$url" || { rm -f "$tarball"; die "下载失败，版本 ${PHP_VERSION} 可能不存在"; }
        fi
    fi

    tar -tzf "$tarball" >/dev/null 2>&1 || die "PHP 安装包损坏: ${tarball}"

    if [[ ! -d $PHP_SRC ]]; then
        info "解压 $(basename "$tarball") -> ${SRC_DIR}"
        tar -xzf "$tarball" -C "$SRC_DIR" || die "解压 PHP 失败"
    fi
    [[ -d $PHP_SRC ]] || die "解压后未找到源码目录 ${PHP_SRC}"
}

# --------------------------------- 编译配置 ----------------------------------
build_php_flags() {
    local major
    major=$(php_major)

    PHP_CONFIGURE_FLAGS=(
        --prefix="$PHP_PREFIX"
        --with-config-file-path="$PHP_CONF_DIR"
        --with-iconv --with-zlib --enable-bcmath --enable-shmop
        --enable-fpm --enable-mbstring --enable-ftp
        --with-openssl --enable-pcntl --enable-sockets --enable-soap
        --with-curl --with-gettext
        --with-mysqli --with-pdo-mysql --with-pdo-sqlite
        --enable-intl --enable-zip --enable-sysvsem
        --enable-inline-optimization --enable-mbregex
    )

    if (( major >= 8 )); then
        # 新版 PHP：GD 改成 --enable-gd + 独立的 --with-jpeg/--with-freetype，
        # xmlrpc 已从核心移除，不再传旧参数
        PHP_CONFIGURE_FLAGS+=(--enable-gd --with-jpeg --with-freetype --with-webp)
    else
        PHP_CONFIGURE_FLAGS+=(--with-gd
            --with-jpeg-dir=/usr/include
            --with-png-dir=/usr/include
            --with-xpm-dir=/usr/include
            --with-freetype-dir=/usr/include/freetype2
            --with-xmlrpc
        )
        (( major >= 7 )) && PHP_CONFIGURE_FLAGS+=(--with-webp-dir=/usr/include)
    fi
}

build_php() {
    local jobs

    build_php_flags
    cd "$PHP_SRC" || die "无法进入源码目录 ${PHP_SRC}"

    info "开始 configure（prefix=${PHP_PREFIX}）..."
    ./configure "${PHP_CONFIGURE_FLAGS[@]}" || die "configure 失败，详见 ${PHP_SRC}/config.log"

    jobs=$(nproc 2>/dev/null || echo 2)
    info "开始编译（make -j${jobs}），耗时较长请耐心等待..."
    make -j"$jobs" || die "make 失败"
    make install || die "make install 失败"

    ok "PHP 编译安装完成: ${PHP_PREFIX}"
}

# --------------------------------- 配置阶段 ----------------------------------
ensure_php_user() {
    if id -u php >/dev/null 2>&1; then
        ok "系统用户 php 已存在"
    else
        useradd -s /sbin/nologin -M php || die "创建 php 用户失败"
        ok "已创建系统用户 php"
    fi
}

configure_php() {
    # PATH：写在 profile.d 里，对 root 和后续登录都生效，且可重复执行
    cat > /etc/profile.d/php.sh <<EOF
# 由 php_install.sh 生成
export PATH=\$PATH:${PHP_PREFIX}/bin
EOF
    chmod 644 /etc/profile.d/php.sh
    export PATH="${PATH}:${PHP_PREFIX}/bin"

    # php.ini：已存在就不覆盖，避免冲掉线上调优
    if [[ ! -f ${PHP_CONF_DIR}/php.ini ]]; then
        if [[ -f "${PHP_SRC}/php.ini-production" ]]; then
            cp "${PHP_SRC}/php.ini-production" "${PHP_CONF_DIR}/php.ini"
            ok "已生成 ${PHP_CONF_DIR}/php.ini"
        else
            err "未找到 php.ini-production，跳过"
        fi
    else
        info "已存在 php.ini，保留原配置"
    fi

    # php-fpm.conf
    if [[ ! -f $FPM_CONF ]]; then
        cp "${PHP_CONF_DIR}/php-fpm.conf.default" "$FPM_CONF" || die "生成 php-fpm.conf 失败"
        ok "已生成 ${FPM_CONF}"
    else
        info "已存在 php-fpm.conf，保留原配置"
    fi

    # pool 配置：只在首次生成时改写，重复执行不会覆盖自定义配置
    if [[ ! -f $FPM_POOL ]]; then
        cp "${PHP_CONF_DIR}/php-fpm.d/www.conf.default" "$FPM_POOL" || die "生成 www.conf 失败"
        sed -i 's/^user = nobody/user = php/' "$FPM_POOL"
        sed -i 's/^group = nobody/group = php/' "$FPM_POOL"
        sed -i 's|^;slowlog = .*|slowlog = log/$pool.log.slow|' "$FPM_POOL"
        sed -i 's/^;listen.mode = 0660/listen.mode = 0660/' "$FPM_POOL"
        ok "已生成 ${FPM_POOL}（user/group 改为 php）"
    else
        info "已存在 www.conf，保留原配置"
    fi

    mkdir -p "${PHP_PREFIX}/var/run" "${PHP_PREFIX}/var/log"

    # 命令软链，方便直接使用 php / php-fpm
    local bin
    for bin in php php-fpm; do
        if [[ -x "${PHP_PREFIX}/bin/${bin}" || -x "${PHP_PREFIX}/sbin/${bin}" ]]; then
            local src="${PHP_PREFIX}/bin/${bin}"
            [[ -x $src ]] || src="${PHP_PREFIX}/sbin/${bin}"
            ln -sf "$src" "/usr/local/bin/${bin}"
        fi
    done
}

ensure_php_fpm_unit() {
    local unit=/usr/lib/systemd/system/php-fpm.service

    if [[ -f $unit ]]; then
        ok "systemd 单元已存在: ${unit}"
    elif [[ -f "${PHP_SRC}/sapi/fpm/php-fpm.service" ]]; then
        cp "${PHP_SRC}/sapi/fpm/php-fpm.service" "$unit" || die "复制 php-fpm.service 失败"
        ok "已复制官方 systemd 单元"
    else
        info "源码未提供 service 文件，生成默认单元"
        cat > "$unit" <<EOF
[Unit]
Description=PHP FastCGI Process Manager
After=network.target

[Service]
Type=simple
ExecStart=${PHP_PREFIX}/sbin/php-fpm --nodaemonize --fpm-config ${FPM_CONF}
ExecReload=/bin/kill -USR2 \$MAINPID
KillMode=mixed
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload || die "systemctl daemon-reload 失败"
    systemctl enable php-fpm >/dev/null 2>&1 || true
}

start_php_fpm() {
    local i pid

    info "启动 php-fpm ..."
    systemctl restart php-fpm || {
        systemctl status php-fpm --no-pager -l 2>/dev/null
        tail -n 20 "${PHP_PREFIX}/var/log/php-fpm.log" 2>/dev/null
        die "php-fpm 启动失败"
    }

    for i in $(seq 1 20); do
        # CentOS 7 的 systemd 219 不支持 systemctl show --value，用 cut 兼容
        pid=$(systemctl show -p MainPID php-fpm 2>/dev/null | cut -d= -f2)
        if [[ -n $pid && $pid != "0" ]] && kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if [[ -z $pid || $pid == "0" ]]; then
        tail -n 20 "${PHP_PREFIX}/var/log/php-fpm.log" 2>/dev/null
        die "php-fpm 未启动成功，请查看 ${PHP_PREFIX}/var/log/php-fpm.log"
    fi

    ok "php-fpm 已启动  PID: ${pid}"
}

show_info() {
    echo
    echo "==================== 安装信息 ===================="
    echo "  PHP 版本  : $(php -v 2>/dev/null | head -n1)"
    echo "  安装目录  : ${PHP_PREFIX}"
    echo "  配置文件  : ${PHP_CONF_DIR}/php.ini"
    echo "  FPM 配置  : ${FPM_CONF}"
    echo "  FPM 池    : ${FPM_POOL}"
    echo "  FPM 端口  : $(grep -E '^listen *=' "$FPM_POOL" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' ')"
    echo "================================================="
    echo

    echo "--- 监听端口 ---"
    if have ss; then
        ss -lntp 2>/dev/null | grep -F php-fpm || echo "未找到 php-fpm 监听端口"
    elif have netstat; then
        netstat -lntp 2>/dev/null | grep -F php-fpm || echo "未找到 php-fpm 监听端口"
    fi

    echo
    echo "--- 进程 ---"
    if have pgrep; then
        pgrep -a php-fpm || echo "无 php-fpm 进程"
    else
        ps -ef 2>/dev/null | grep -F php-fpm | grep -v grep || echo "无 php-fpm 进程"
    fi
    return 0
}

# ---------------------------------- 入口 -------------------------------------
prompt_version() {
    if [[ -z $PHP_VERSION ]]; then
        [[ -t 0 ]] || die "非交互环境请用 PHP_VERSION=<版本> 指定版本"
        read -r -p "$(printf '%b' "${C_YELLOW}请输入要安装的 PHP 版本: ${C_END}")" PHP_VERSION
    fi
    [[ $PHP_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "版本号格式不正确: ${PHP_VERSION}（应为主.次.修订）"
    (( $(php_major) >= 7 )) || info "警告：所选版本较旧，编译参数可能不兼容"
}

do_install() {
    local skip_build=0

    require_root
    prompt_version
    set_paths
    mkdir -p "$SRC_DIR" "$DOWNLOAD_DIR"

    info "准备安装 PHP ${PHP_VERSION} -> ${PHP_PREFIX}"

    install_deps
    ensure_libzip
    ensure_php_user

    if [[ -x ${PHP_PREFIX}/bin/php && $FORCE != 1 ]]; then
        ok "检测到 ${PHP_PREFIX} 已安装，跳过编译（如需重编请加 FORCE=1）"
        skip_build=1
    fi

    if (( ! skip_build )); then
        prepare_php_source
        build_php
    fi

    configure_php
    ensure_php_fpm_unit
    start_php_fpm
    show_info
}

main() {
    if [[ ! -t 0 && -z $PHP_VERSION ]]; then
        die "非交互环境下请用 PHP_VERSION=x.y.z 指定版本"
    fi
    do_install
}

main "$@"
