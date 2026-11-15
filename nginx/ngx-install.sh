#!/bin/bash
# ============================================================================
#  nginx 源码编译安装脚本
#
#  用法:
#     ./ngx_install.sh                 # 交互输入版本号
#     NGX_VERSION=<版本> ./ngx_install.sh
#
#  可用环境变量:
#     NGX_VERSION                      # 需要编译的 nginx 版本（不填则交互输入）
#     NGX_PREFIX=/usr/local/nginx      # 安装目录
#
#  相比原脚本的改进:
#     1. 原脚本用 "find|wc -l" 得到的是数量，却和路径字符串比较，
#        条件永远成立，mv 时报 “same file” 或把文件挪走；这里直接定位文件;
#     2. 依赖分批安装，某一组失败不再中断整个流程（gperftools-devel 在部分
#        软件源里并不存在，原脚本一行装不完就全失败）;
#     3. 先建 nginx 用户再 configure，避免装完启动时报 “user nginx not found”;
#     4. make 失败原本只打印一句错误就继续，导致最后还提示“启动成功”;
#        现在任一步失败立即退出并给出日志位置;
#     5. 根据系统里实际存在的开发库自动裁剪模块（gd-devel/libxslt-devel/
#        perl-devel/gperftools-devel），缺库时降级编译而不是整次失败;
#     6. 已安装时不再重复编译，可选择直接启动; 启动前先 nginx -t 校验配置。
# ============================================================================
set -o pipefail

NGX_VERSION="${NGX_VERSION:-}"
NGX_PREFIX="${NGX_PREFIX:-/usr/local/nginx}"
SRC_DIR="${SRC_DIR:-/data}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/data}"
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

show_info() {
    local pid=""
    [[ -r "${NGX_PREFIX}/logs/nginx.pid" ]] && pid=$(head -n1 "${NGX_PREFIX}/logs/nginx.pid" 2>/dev/null)

    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
        echo -e "${C_GREEN}nginx 正在运行  NGINX_PID: ${pid}${C_END}"
    else
        echo -e "${C_RED}nginx 未运行${C_END}"
    fi

    echo
    echo "--- 监听端口 ---"
    if have ss; then
        ss -lntp 2>/dev/null | grep -F nginx || echo "未找到 nginx 监听端口"
    elif have netstat; then
        netstat -lntp 2>/dev/null | grep -F nginx || echo "未找到 nginx 监听端口"
    fi

    echo
    echo "--- 进程 ---"
    if have pgrep; then
        pgrep -a nginx || true
    else
        ps -ef 2>/dev/null | grep -F nginx | grep -v grep || true
    fi

    echo
    echo "--- 版本 ---"
    "${NGX_PREFIX}/sbin/nginx" -V 2>&1 | head -n 2
    return 0
}

# -------------------------------- 依赖安装 -----------------------------------
install_deps() {
    yum install -y wget make gcc gcc-c++ autoconf || err "基础编译工具安装失败，请检查网络或软件源"

    # 这几组分开装：任意一组在源里缺失都不会拖垮整体
    yum install -y pcre pcre-devel zlib zlib-devel openssl openssl-devel \
        || err "pcre/zlib/openssl 开发库安装失败"

    yum install -y gd gd-devel libxslt libxslt-devel libxml2 libxml2-devel \
        perl-devel perl-ExtUtils-Embed \
        || err "gd/libxslt/perl 开发库安装失败（相关模块将被跳过）"

    yum install -y gperftools-devel || info "gperftools-devel 不可用，将不编译 google_perftools 模块"

    yum install -y git vim net-tools lrzsz tree tcl telnet ntpdate \
        || info "部分常用工具安装失败，不影响 nginx 编译"

    have ntpdate && ntpdate ntp1.aliyun.com >/dev/null 2>&1 || true
    have timedatectl && timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1 || true
}

# -------------------------------- 源码准备 -----------------------------------
prepare_source() {
    local tarball url

    tarball=$(find_one "nginx-${NGX_VERSION}.tar.gz" f) || true
    if [[ -n $tarball ]]; then
        info "使用本地安装包: ${tarball}"
    else
        mkdir -p "$DOWNLOAD_DIR" || die "无法创建 ${DOWNLOAD_DIR}"
        tarball="${DOWNLOAD_DIR}/nginx-${NGX_VERSION}.tar.gz"
        url="https://nginx.org/download/nginx-${NGX_VERSION}.tar.gz"
        info "本地无安装包，开始下载: ${url}"
        if have wget; then
            wget -q --show-progress -O "$tarball" "$url" || { rm -f "$tarball"; die "下载失败，版本 ${NGX_VERSION} 可能不存在"; }
        elif have curl; then
            curl -fsSL -o "$tarball" "$url" || { rm -f "$tarball"; die "下载失败，版本 ${NGX_VERSION} 可能不存在"; }
        else
            die "系统缺少 wget / curl"
        fi
    fi

    tar -tzf "$tarball" >/dev/null 2>&1 || die "安装包损坏: ${tarball}"

    mkdir -p "$SRC_DIR"
    info "解压 $(basename "$tarball") -> ${SRC_DIR}"
    tar -xzf "$tarball" -C "$SRC_DIR" || die "解压失败"

    SRC_DIR="${SRC_DIR}/nginx-${NGX_VERSION}"
    [[ -d $SRC_DIR ]] || die "解压后未找到目录 ${SRC_DIR}"
}

# -------------------------------- 编译安装 -----------------------------------
build_and_install() {
    local flags=() jobs

    # 基础参数（与原脚本保持一致）
    flags+=(--prefix="$NGX_PREFIX" --user=nginx --group=nginx
        --with-compat --with-debug --with-file-aio --with-threads
        --with-http_addition_module --with-http_auth_request_module
        --with-http_dav_module --with-http_degradation_module
        --with-http_flv_module --with-http_gunzip_module
        --with-http_gzip_static_module --with-http_mp4_module
        --with-http_random_index_module --with-http_realip_module
        --with-http_secure_link_module --with-http_slice_module
        --with-http_ssl_module --with-http_stub_status_module
        --with-http_sub_module --with-http_v2_module
        --with-mail=dynamic --with-mail_ssl_module
        --with-pcre --with-pcre-jit
        --with-stream=dynamic --with-stream_ssl_module
        --with-stream_ssl_preread_module
        --with-ld-opt=-Wl,-z,relro
        --with-cc-opt='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches -m64 -mtune=generic'
    )

    # 依赖库存在才编相应模块，避免 configure 直接失败
    if rpm_has gd-devel; then
        flags+=(--with-http_image_filter_module=dynamic)
    else
        info "缺少 gd-devel，跳过 http_image_filter 模块"
    fi

    if rpm_has libxslt-devel; then
        flags+=(--with-http_xslt_module=dynamic)
    else
        info "缺少 libxslt-devel，跳过 http_xslt 模块"
    fi

    if rpm_has perl-devel; then
        flags+=(--with-http_perl_module=dynamic)
    else
        info "缺少 perl-devel，跳过 http_perl 模块"
    fi

    if rpm_has gperftools-devel; then
        flags+=(--with-google_perftools_module)
    else
        info "缺少 gperftools-devel，跳过 google_perftools 模块"
    fi

    cd "$SRC_DIR" || die "无法进入源码目录 ${SRC_DIR}"

    jobs=$(nproc 2>/dev/null || echo 2)
    info "开始 configure..."
    ./configure "${flags[@]}" || die "configure 失败，详见 ${SRC_DIR}/objs/autoconf.err"

    info "开始编译（make -j${jobs}），耗时较长请耐心等待..."
    make -j"$jobs" || die "make 失败"
    make install || die "make install 失败"

    ok "编译安装完成: ${NGX_PREFIX}"
}

# -------------------------------- 启动服务 -----------------------------------
start_nginx() {
    local pid

    [[ -x "${NGX_PREFIX}/sbin/nginx" ]] || die "未找到 ${NGX_PREFIX}/sbin/nginx"

    if [[ -r "${NGX_PREFIX}/logs/nginx.pid" ]]; then
        pid=$(head -n1 "${NGX_PREFIX}/logs/nginx.pid" 2>/dev/null)
        if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
            ok "nginx 已在运行  NGINX_PID: ${pid}"
            show_info
            return 0
        fi
    fi

    "${NGX_PREFIX}/sbin/nginx" -t >/dev/null 2>&1 || {
        "${NGX_PREFIX}/sbin/nginx" -t
        die "配置校验失败，未启动"
    }

    info "启动 nginx..."
    "${NGX_PREFIX}/sbin/nginx" || die "nginx 启动失败"

    pid=$(head -n1 "${NGX_PREFIX}/logs/nginx.pid" 2>/dev/null)
    ok "nginx 已启动  NGINX_PID: ${pid:-未知}"
    show_info
}

# ---------------------------------- 入口 -------------------------------------
ensure_user() {
    if id -u nginx >/dev/null 2>&1; then
        ok "系统用户 nginx 已存在"
    else
        useradd -s /sbin/nologin -M nginx || die "创建 nginx 用户失败"
        ok "已创建系统用户 nginx"
    fi
}

prompt_version() {
    if [[ -z $NGX_VERSION ]]; then
        [[ -t 0 ]] || die "非交互环境请用 NGX_VERSION=<版本> 指定 nginx 版本"
        read -r -p "$(printf '%b' "${C_YELLOW}请输入要安装的 nginx 版本: ${C_END}")" NGX_VERSION
    fi
    [[ $NGX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "版本号格式不正确: ${NGX_VERSION}（应为主.次.修订）"
}

do_install() {
    require_root
    prompt_version

    info "准备安装 nginx ${NGX_VERSION} -> ${NGX_PREFIX}"

    install_deps
    ensure_user
    prepare_source
    build_and_install
    start_nginx
}

already_installed() {
    [[ -x "${NGX_PREFIX}/sbin/nginx" ]]
}

main() {
    local answer

    if already_installed; then
        err "检测到 nginx 已安装: ${NGX_PREFIX}"
        echo
        show_info
        echo
        read -r -p "$(printf '%b' "${C_YELLOW}是否直接启动它？(y/N): ${C_END}")" answer
        case "${answer:-n}" in
            [Yy]*) require_root; start_nginx ;;
            *)     info "已退出，未做任何修改" ;;
        esac
        return 0
    fi

    do_install
}

main "$@"
