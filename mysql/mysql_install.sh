#!/bin/bash
# ============================================================================
#  MySQL 一键安装脚本（5.7.44 / 8.0.11 / 8.0.23）
#
#  用法:
#     ./mysql_install.sh                 # 交互菜单
#     ./mysql_install.sh install         # 安装（每次都会询问装哪个版本）
#     ./mysql_install.sh start|stop|restart|status
#
#  说明:
#     1. 每次执行 install 都会让你选择 5.7.44 / 8.0.11 / 8.0.23，不会默认静默装某个版本;
#     2. 非交互场景（CI/批量）可用 MYSQL_VERSION=5.7.44|8.0.11|8.0.23 指定;
#     3. 已安装同版本时只做补装（配置、服务、启动），不重复解压;
#     4. 已安装其他版本且数据目录非空时拒绝替换二进制，避免直接毁掉现有库;
#     5. 安装目录 /usr/local/mysql，数据目录 /data/db/mysql/data，
#        配置 /etc/my.cnf，服务名 mysql（systemd）。
#
#  可用环境变量:
#     MYSQL_VERSION=5.7.44|8.0.11|8.0.23   非交互指定版本
#     MYSQL_ROOT_PASSWORD=xxx       仅提示用，不会自动改密码
#     DATA_ROOT=/data/db/mysql      数据根目录
#     KEEP_MYCNF=1                  保留已有 /etc/my.cnf，不按部署路径重写
#
#  排查“socket 未就绪”:
#     脚本会同时检查 socket 文件、3306 端口和任意 mysql 相关 unix socket，
#     并在失败时打印 systemd/journal/错误日志/动态库/配置路径等诊断信息。
#     常见原因: 已有 /etc/my.cnf 指向别的 datadir/socket（本脚本会自动备份并
#     重写，或用 KEEP_MYCNF=1 保留）、缺少 libaio/libnuma、配置里有当前版本
#     不认识的参数。
# ============================================================================
set -o pipefail

MYSQL_VERSION="${MYSQL_VERSION:-}"
SUPPORTED_VERSIONS="5.7.44 8.0.11 8.0.23"

BASE_DIR="/usr/local/mysql"
DATA_ROOT="${DATA_ROOT:-/data/db/mysql}"
DATA_DIR="${DATA_ROOT}/data"
LOG_DIR="${DATA_ROOT}/logs"
RUN_DIR="${BASE_DIR}/mysqld"
SOCK_FILE="${RUN_DIR}/mysqld.sock"
PID_FILE="${RUN_DIR}/mysqld.pid"
ERR_LOG="${LOG_DIR}/error.log"
CNF_FILE="/etc/my.cnf"
SERVICE_FILE="/usr/lib/systemd/system/mysql.service"
DOWNLOAD_DIR="/usr/local/src"
PROFILE_FILE="/etc/profile.d/mysql.sh"
SEARCH_DIRS=(/root /data /date /tmp /opt /usr/local /usr/src "$PWD")
# 包目录可用 PKG_DIR 追加到搜索优先级最前（如 PKG_DIR=/date ./mysql_install.sh install）
[[ -n ${PKG_DIR:-} ]] && SEARCH_DIRS=("$PKG_DIR" "${SEARCH_DIRS[@]}")
# 归档下载站（8.0.23 等老版本的官方包只在这里，且只有 .tar.xz）
ARCHIVE_BASE="https://downloads.mysql.com/archives/get/p/23/file"

PACKAGE_TARBALL=""

C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_MAGENTA=$'\033[1;35m'; C_END=$'\033[0m'
[[ -t 1 ]] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_MAGENTA=''; C_END=''; }

info() { echo -e "${C_YELLOW}[INFO]${C_END} $*"; }
warn() { echo -e "${C_MAGENTA}[WARN]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
err()  { echo -e "${C_RED}[FAIL]${C_END} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行本脚本"; }

# 常见目录优先，找不到再退回单文件系统全盘查找（自动跳过 /proc、/sys、/dev）
# 用法: find_one <文件名模式> [<模式2> ...] <f|d>   —— 返回第一个名字匹配项
# 用法: find_all <文件名模式> [<模式2> ...] <f|d>   —— 按优先级列出全部匹配项
#   最后一个参数是类型（f=文件 d=目录），其余为按优先级排列的匹配模式。
#   注意 bash 4.2（CentOS 7）不支持 arr[-1] 负数下标，这里用长度取值。
_find_collect() {
    local quit="$1"; shift
    local patterns=("$@") type npat dir found pat hit=0
    npat=${#patterns[@]}
    (( npat >= 2 )) || return 1
    type="${patterns[npat-1]}"
    patterns=("${patterns[@]:0:npat-1}")

    for pat in "${patterns[@]}"; do
        for dir in "${SEARCH_DIRS[@]}"; do
            [[ -d $dir ]] || continue
            if [[ $quit == quit ]]; then
                found=$(find "$dir" -maxdepth 4 -name "$pat" -type "$type" -print -quit 2>/dev/null)
                [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
            else
                found=$(find "$dir" -maxdepth 4 -name "$pat" -type "$type" -print 2>/dev/null)
                [[ -n $found ]] && { printf '%s\n' "$found"; hit=1; }
            fi
        done

        # 全盘兜底只在一次都没命中时执行一次，避免每个模式都扫全盘
        if [[ $hit -eq 0 ]]; then
            if [[ $quit == quit ]]; then
                found=$(find / -xdev -name "$pat" -type "$type" -print -quit 2>/dev/null)
                [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
            else
                found=$(find / -xdev -name "$pat" -type "$type" -print 2>/dev/null)
                [[ -n $found ]] && { printf '%s\n' "$found"; hit=1; }
            fi
        fi
    done
    return $(( 1 - hit ))
}

find_one()  { _find_collect quit "$@"; }
find_all()  { _find_collect all  "$@"; }

# 按文件魔数判断压缩格式，返回 tar 的压缩选项字母（后缀名不可信：
# 下载失败的 404 页面也常被存成 *.tar.gz）。返回空表示让 tar 自行判断。
tar_cflag() {
    local magic
    magic=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        1f8b*)         printf '%s' 'z' ;;   # gzip
        fd377a585a00)  printf '%s' 'J' ;;   # xz
        425a68*)       printf '%s' 'j' ;;   # bzip2
        *)             printf '%s' ''  ;;
    esac
}

# 真正的“是不是可用安装包”以能否列出归档内容为准
tar_test() {
    local t="$1" flag
    [[ -f $t ]] || return 1
    flag=$(tar_cflag "$t")
    tar -t"${flag}f" "$t" >/dev/null 2>&1
}

tar_extract() {
    local t="$1" dest="$2" flag
    flag=$(tar_cflag "$t")
    tar -x"${flag}f" "$t" -C "$dest"
}

tar_extract_pipe() {   # $1=包 $2=目标目录；走管道以便 pv 显示进度
    local t="$1" dest="$2" flag
    flag=$(tar_cflag "$t")
    pv "$t" | tar -x"${flag}f" - -C "$dest"
}

version_mm() { printf '%s' "${MYSQL_VERSION%.*}"; }

# ------------------------------- 版本选择 -----------------------------------
# 每次安装都必须选择版本；交互输入 1/2 或直接输入版本号
select_version() {
    local choice prompt

    if [[ -n $MYSQL_VERSION ]]; then
        case "$MYSQL_VERSION" in
            5.7.44|8.0.11|8.0.23) ;;
            *) die "MYSQL_VERSION 只支持 5.7.44 或 8.0.11 或 8.0.23，当前: ${MYSQL_VERSION}" ;;
        esac
    fi

    # 非交互：必须由环境变量指定，不猜测
    if [[ ! -t 0 ]]; then
        [[ -n $MYSQL_VERSION ]] \
            || die "非交互环境请用 MYSQL_VERSION=5.7.44|8.0.11|8.0.23 指定版本"
        return 0
    fi

    echo
    echo "请选择要安装的 MySQL 版本:"
    echo "  1) 5.7.44"
    echo "  2) 8.0.11"
    echo "  3) 8.0.23"
    prompt="请输入编号或版本号[1/2/3]"
    [[ -n $MYSQL_VERSION ]] && prompt="${prompt}（回车使用 ${MYSQL_VERSION}）"

    while :; do
        read -r -p "$(printf '%b' "${C_YELLOW}${prompt}: ${C_END}")" choice
        case "$choice" in
            "")
                if [[ -n $MYSQL_VERSION ]]; then
                    break
                fi
                err "请输入 1、2 或 3"
                ;;
            1|5.7|5.7.44)  MYSQL_VERSION="5.7.44"; break ;;
            # “8.0”太宽泛（8.0.11/8.0.23 都匹配），不再作为别名，避免点 2 装成 8.0.11
            2|8.0.11)      MYSQL_VERSION="8.0.11"; break ;;
            3|8.0.23)      MYSQL_VERSION="8.0.23"; break ;;
            *) err "无效输入: ${choice}，请输入 1、2 或 3" ;;
        esac
    done
    ok "已选择 MySQL ${MYSQL_VERSION}"
}

# ------------------------------- 状态查询 -----------------------------------
installed_version() {
    local v
    [[ -x "${BASE_DIR}/bin/mysqld" ]] || return 1
    v=$("${BASE_DIR}/bin/mysqld" --version 2>/dev/null | awk '{print $3}' | sed 's/-.*//')
    [[ -n $v ]] && printf '%s' "$v"
}

has_system_tables() { [[ -d "${DATA_DIR}/mysql" ]]; }

service_active() { systemctl is-active --quiet mysql 2>/dev/null; }

# 读取 my.cnf 中某个配置项的值（忽略注释和节名）
cfg_value() {
    local key="$1"
    [[ -f $CNF_FILE ]] || return 1
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { next }
        {
            name = $1
            gsub(/[[:space:]]/, "", name)
            if (name == k) {
                v = $2
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        }' "$CNF_FILE"
}

mysqld_alive() {
    pgrep -x mysqld >/dev/null 2>&1 || service_active
}

port_open() {
    local p="$1"
    if have ss; then
        ss -lnt 2>/dev/null | grep -q ":${p} "
    else
        netstat -lnt 2>/dev/null | grep -q ":${p} "
    fi
}

# 任意 mysql 相关 unix socket 是否存在（应对配置里 socket 路径与脚本预期不一致）
unix_socket_any() {
    if have ss; then
        ss -lx 2>/dev/null | grep -qiE '/[^ ]*mysql[^ ]*\.sock'
    else
        netstat -lx 2>/dev/null | grep -qiE '/[^ ]*mysql[^ ]*\.sock'
    fi
}

# 找出真实在用的 socket 路径
actual_socket() {
    local s=""
    if have ss; then
        s=$(ss -lx 2>/dev/null | grep -oE '/[^ ]*mysql[^ ]*\.sock' | head -n1)
    elif have netstat; then
        s=$(netstat -lx 2>/dev/null | grep -oE '/[^ ]*mysql[^ ]*\.sock' | head -n1)
    fi
    if [[ -z $s ]]; then
        s=$(ls -1 /tmp/mysql.sock /var/lib/mysql/mysql.sock "${RUN_DIR}"/*.sock 2>/dev/null | head -n1)
    fi
    printf '%s' "$s"
}

# 通用二进制常见缺库：8.0 需要 libnuma，5.7/8.0 都需要 libaio
check_binary_libs() {
    local missing
    [[ -x "${BASE_DIR}/bin/mysqld" ]] || return 0
    missing=$(ldd "${BASE_DIR}/bin/mysqld" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')
    if [[ -n $missing ]]; then
        err "mysqld 缺少动态库: ${missing}"
        info "CentOS 7 上一般执行: yum install -y libaio numactl-libs"
        return 1
    fi
    return 0
}

# 配置里出现当前版本不认识的参数时，mysqld 会在启动瞬间退出，
# 这里提前把这类错误捞出来，比只看 error.log 直观
config_check() {
    local out
    [[ -x "${BASE_DIR}/bin/mysqld" ]] || return 0
    out=$("${BASE_DIR}/bin/mysqld" --defaults-file="$CNF_FILE" --user=mysql \
        --verbose --help 2>&1 >/dev/null) || true

    if printf '%s' "$out" | grep -qiE 'unknown (variable|option|parameter|system variable)'; then
        err "配置文件 ${CNF_FILE} 中有当前版本（${MYSQL_VERSION}）不支持的参数:"
        printf '%s\n' "$out" | grep -iE 'unknown (variable|option|parameter|system variable)' | head -n 10
        die "请修正配置后重试；若是别处带来的 my.cnf，可用 KEEP_MYCNF=0 让脚本按部署路径重写"
    fi
}

# 启动失败时把该看的都打出来，避免只报一句 "socket 未就绪"
diagnose_start_failure() {
    local k

    echo
    err "MySQL 诊断信息如下（可直接把这段贴出来排查）:"

    echo "--- systemctl status mysql ---"
    if have systemctl; then
        systemctl status mysql --no-pager -l 2>&1 | head -n 20
    else
        echo "无 systemctl"
    fi

    echo "--- journalctl -u mysql（最近 30 行）---"
    if have journalctl; then
        journalctl -u mysql -n 30 --no-pager 2>/dev/null | tail -n 30
    else
        echo "无 journalctl"
    fi

    echo "--- 错误日志 ${ERR_LOG}（最近 30 行）---"
    if [[ -f $ERR_LOG ]]; then
        tail -n 30 "$ERR_LOG"
    else
        echo "日志文件不存在"
    fi

    echo "--- 进程 ---"
    if have pgrep; then
        pgrep -a mysqld || echo "mysqld 未运行"
    else
        ps -ef 2>/dev/null | grep '[m]ysqld' || echo "mysqld 未运行"
    fi

    echo "--- 端口 / socket ---"
    if have ss; then
        ss -lntp 2>/dev/null | grep -E '3306|mysqld' || echo "3306 未监听"
        ss -lx 2>/dev/null | grep -iE 'mysql.*sock' || echo "未发现 mysql unix socket"
    elif have netstat; then
        netstat -lntp 2>/dev/null | grep -E '3306|mysqld' || echo "3306 未监听"
        netstat -lx 2>/dev/null | grep -iE 'mysql.*sock' || echo "未发现 mysql unix socket"
    else
        echo "无 ss / netstat"
    fi

    echo "--- 目录权限 ---"
    ls -ld "$RUN_DIR" "$DATA_DIR" 2>/dev/null
    ls -l "$RUN_DIR" 2>/dev/null | head -n 5

    echo "--- 动态库 ---"
    if have ldd && [[ -x "${BASE_DIR}/bin/mysqld" ]]; then
        ldd "${BASE_DIR}/bin/mysqld" 2>/dev/null | grep 'not found' || echo "动态库完整"
    else
        echo "跳过（无 ldd 或未安装 mysqld）"
    fi

    echo "--- 配置关键项 ---"
    for k in basedir datadir socket pid-file log_error; do
        printf '  %-10s %s\n' "$k" "$(cfg_value "$k")"
    done

    echo "--- 目录空间 ---"
    df -h "$DATA_ROOT" 2>/dev/null | tail -n 1

    echo
    err "排查提示:"
    err "  1) 若 ss -lx 里的 socket 与上面“配置关键项”的 socket 不一致，说明进程还在用旧配置，"
    err "     执行 systemctl restart mysql 让 ${CNF_FILE} 生效;"
    err "  2) 看错误日志末尾的 [ERROR] 行，比 systemd 的摘要信息更直接;"
    err "  3) 是否缺少 libaio/libnuma（CentOS 7: yum install -y libaio numactl-libs）;"
    err "  4) 配置参数是否与 ${MYSQL_VERSION:-当前版本} 匹配;"
    err "  5) 3306 是否被系统自带的 mysqld/mariadb 占用。"
}

# ------------------------------- 安装包获取 ---------------------------------
# 8.0.23 属于已下架的归档版本：主站路径（含 .tar.gz）返回 404，
# 官方只在归档站保留 .tar.xz，所以下载候选必须同时覆盖 gz/xz 与主站/归档站。
download_package() {
    local mm url out name
    mm=$(version_mm)

    { have wget || have curl; } || die "系统缺少 wget / curl，无法下载安装包"

    mkdir -p "$DOWNLOAD_DIR" || die "无法创建 ${DOWNLOAD_DIR}"

    local urls=(
        # 主站：当前在架版本
        "https://dev.mysql.com/get/Downloads/MySQL-${mm}/mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.gz"
        "https://dev.mysql.com/get/Downloads/MySQL-${mm}/mysql-${MYSQL_VERSION}-linux-glibc2.17-x86_64.tar.gz"
        "https://cdn.mysql.com/Downloads/MySQL-${mm}/mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.gz"
        "https://cdn.mysql.com/Downloads/MySQL-${mm}/mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.xz"
        # 归档站：下架版本（8.0.23 只有 glibc2.12 的 .tar.xz）
        "${ARCHIVE_BASE}/mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.gz"
        "${ARCHIVE_BASE}/mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.xz"
        "${ARCHIVE_BASE}/mysql-${MYSQL_VERSION}-linux-glibc2.17-x86_64.tar.xz"
    )

    for url in "${urls[@]}"; do
        name=$(basename "$url")
        out="${DOWNLOAD_DIR}/${name}"
        info "尝试下载: ${url}" >&2
        rm -f "$out"
        if have wget; then
            wget -q -O "$out" "$url" || rm -f "$out"
        else
            curl -fsSL -o "$out" "$url" || rm -f "$out"
        fi

        if [[ -s $out ]] && tar_test "$out"; then
            PACKAGE_TARBALL="$out"
            return 0
        fi
        rm -f "$out"
    done

    err "下载失败，请手动准备 mysql-${MYSQL_VERSION}-linux-glibc2.1x-x86_64.tar.gz 或 .tar.xz 放到 /data 或 /root" >&2
    return 1
}

resolve_package() {
    local local_tar list

    [[ -n $PACKAGE_TARBALL ]] && return 0

    # 逐个校验：目录里可能同时存在下载失败留下的假 .tar.gz（404 页面）
    # 和可用的 .tar.xz，名字匹配不代表内容完整，必须 tar -t 通过才算数。
    # 这里用临时文件而不是进程替换 <(...)，避免 sh/dash 或文本被改动后报错。
    list=$(mktemp /tmp/mysql_pkg_list.XXXXXX 2>/dev/null) || list="/tmp/mysql_pkg_list.$$"

    find_all \
        "mysql-${MYSQL_VERSION}-linux-glibc2.1*-x86_64.tar.gz" \
        "mysql-${MYSQL_VERSION}-linux-glibc2.1*-x86_64.tar.xz" \
        "mysql-${MYSQL_VERSION}-*.tar.gz" \
        "mysql-${MYSQL_VERSION}-*.tar.xz" \
        f | awk '!seen[$0]++' > "$list"

    while IFS= read -r local_tar; do
        [[ -n $local_tar ]] || continue
        if tar_test "$local_tar"; then
            PACKAGE_TARBALL="$local_tar"
            rm -f "$list"
            ok "使用本地安装包: ${PACKAGE_TARBALL}"
            return 0
        fi
        warn "本地安装包损坏（多半是下载失败的残留），跳过: ${local_tar}"
    done < "$list"

    rm -f "$list"
    info "本地未找到可用的 MySQL ${MYSQL_VERSION} 安装包，开始下载..."
    download_package || return 1
    ok "下载完成: ${PACKAGE_TARBALL}"
}

# ------------------------------- 二进制部署 ---------------------------------
backup_base_dir() {
    local bak
    [[ -e $BASE_DIR ]] || return 0
    bak="${BASE_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$BASE_DIR" "$bak" || die "备份 ${BASE_DIR} 失败"
    info "已备份原安装目录: ${bak}"
}

install_binaries() {
    local iv src

    if iv=$(installed_version); then
        if [[ $iv == "$MYSQL_VERSION" ]]; then
            ok "已安装相同版本 ${iv}，跳过解压"
            return 0
        fi

        if has_system_tables; then
            die "已安装 ${iv}，与目标版本 ${MYSQL_VERSION} 不一致，且 ${DATA_DIR} 已有数据。
       直接替换二进制会导致数据不可用，请先备份数据或手动升级（本脚本不做跨版本原地升级）。"
        fi

        info "已安装 ${iv} 但数据目录为空，准备替换为 ${MYSQL_VERSION}"
        if service_active; then
            info "先停止正在运行的 mysql 服务..."
            systemctl stop mysql >/dev/null 2>&1 || true
        fi
        backup_base_dir
    elif [[ -d $BASE_DIR ]]; then
        # 目录存在但没有可用的 mysqld，视为残装
        backup_base_dir
    fi

    resolve_package || die "获取 MySQL ${MYSQL_VERSION} 安装包失败"

    extract_tarball "$PACKAGE_TARBALL" || die "解压失败"

    src=$(find_one \
        "mysql-${MYSQL_VERSION}-linux-glibc2.1*-x86_64" \
        "mysql-${MYSQL_VERSION}-*-x86_64" \
        d) || true
    [[ -n $src ]] || die "解压后未找到 mysql-${MYSQL_VERSION}-* 目录"

    info "重命名 ${src} -> ${BASE_DIR}"
    mv "$src" "$BASE_DIR" || die "移动目录失败: ${src}"
    ok "MySQL ${MYSQL_VERSION} 二进制部署完成"
}

extract_tarball() {
    local tarball="$1"

    # 注意：这里不再按后缀判格式，tar_test 已用魔数确认包可用，
    # 解压同样按魔数取压缩参数，避免“后缀是 .gz 实际是 xz/HTML”踩坑。
    tar_test "$tarball" || die "安装包损坏或格式不支持: ${tarball}"

    if have yum && ! have pv; then
        info "安装 pv（用于显示解压进度）..."
        yum install -y pv >/dev/null 2>&1 || true
    fi

    info "解压 $(basename "$tarball") -> /usr/local"
    if have pv; then
        tar_extract_pipe "$tarball" /usr/local
    else
        tar_extract "$tarball" /usr/local
    fi
}

# ------------------------------- 依赖与用户 ---------------------------------
install_deps() {
    have yum || return 0
    # 5.7/8.0 的通用二进制都依赖 libaio；8.0 还依赖 libnuma；
    # xz 用于解压 8.0.23 这类只提供 .tar.xz 的归档包
    yum install -y libaio numactl-libs xz >/dev/null 2>&1 \
        || info "libaio/numactl-libs/xz 安装失败，若启动时报缺少动态库或无法解压 .tar.xz 请手动安装"
}

ensure_user() {
    if id -u mysql >/dev/null 2>&1; then
        ok "系统用户 mysql 已存在"
    else
        useradd -s /sbin/nologin -M mysql || die "创建 mysql 用户失败"
        ok "已创建系统用户 mysql"
    fi
}

ensure_dirs() {
    local p
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" || die "创建数据目录失败"

    for p in "$DATA_ROOT" "$BASE_DIR"; do
        if [[ $(stat -c '%U:%G' "$p") != "mysql:mysql" ]]; then
            chown -R mysql:mysql "$p" || die "修改属主失败: ${p}"
        fi
    done
    ok "数据目录 / 安装目录属主已就绪"
}

# ------------------------------- 配置文件 -----------------------------------
write_config() {
    {
        cat <<EOF
# MySQL Configuration File
# mysql_install.sh: mysql_version=${MYSQL_VERSION}
# 兼容 5.7.44 / 8.0.11 / 8.0.23，由 mysql_install.sh 生成

# Client Section
[client]
port   = 3306
socket = ${SOCK_FILE}

# Server Section
[mysqld]
user       = mysql
pid-file   = ${PID_FILE}
socket     = ${SOCK_FILE}
port       = 3306
basedir    = ${BASE_DIR}
datadir    = ${DATA_DIR}
tmpdir     = /tmp
skip-external-locking
explicit_defaults_for_timestamp = true
default_authentication_plugin   = mysql_native_password
log_bin_trust_function_creators = 1
EOF
        if [[ $MYSQL_VERSION == 8.0.* ]]; then
            # 8.0 默认会额外监听 33060（X Protocol），实验室环境一般用不到
            printf '%s\n' 'mysqlx = 0'
        fi
        cat <<EOF

# 服务端字符集
character-set-server = utf8mb4
collation-server     = utf8mb4_general_ci

# 连接数配置
max_connections = 1000

# 超时配置
wait_timeout        = 600
interactive_timeout = 600

# Connection Settings
key_buffer_size     = 16M
max_allowed_packet  = 32M
thread_stack        = 192K
thread_cache_size   = 50

# InnoDB Settings
innodb_file_per_table          = 1
innodb_buffer_pool_size        = 256M
innodb_flush_log_at_trx_commit = 2
innodb_lock_wait_timeout       = 50

# Logging Settings
log_error = ${ERR_LOG}
slow_query_log                = 1
slow_query_log_file           = ${LOG_DIR}/slow-query.log
long_query_time               = 1
log_queries_not_using_indexes = 1

# mysqldump Settings
[mysqldump]
quick
quote-names
max_allowed_packet = 16M

# MySQL Client Settings
[mysql]
no-auto-rehash

# MyISAM Settings
[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer  = 2M
write_buffer = 2M

# mysqlhotcopy Settings
[mysqlhotcopy]
interactive-timeout
EOF
    } > "$CNF_FILE"
}

ensure_config() {
    local cfg_ver cfg_sock cfg_data cfg_base bak

    if [[ -f $CNF_FILE ]]; then
        cfg_ver=$(sed -n 's|^# mysql_install.sh: mysql_version=||p' "$CNF_FILE" | head -n1)

        if [[ -n $cfg_ver ]]; then
            if [[ $cfg_ver != "$MYSQL_VERSION" ]]; then
                info "配置由 ${cfg_ver} 生成，按 ${MYSQL_VERSION} 调整版本相关项"
                if [[ $MYSQL_VERSION == 8.0.* ]]; then
                    if grep -qE '^[#[:space:]]*mysqlx' "$CNF_FILE"; then
                        sed -i -E 's|^[#[:space:]]*mysqlx.*|mysqlx = 0|' "$CNF_FILE"
                    else
                        sed -i '/^\[mysqld\]/a mysqlx = 0' "$CNF_FILE"
                    fi
                else
                    # 5.7 不认识 mysqlx，切换回来时注释掉
                    sed -i -E 's|^[[:space:]]*mysqlx[[:space:]]*=.*|# mysqlx 仅 8.0 使用|' "$CNF_FILE"
                fi
                sed -i -E "s|^# mysql_install.sh: mysql_version=.*|# mysql_install.sh: mysql_version=${MYSQL_VERSION}|" "$CNF_FILE"
                ok "配置已按 ${MYSQL_VERSION} 调整"
            else
                ok "已存在 ${CNF_FILE}，保留原配置"
            fi
            return 0
        fi

        # 走到这里说明 /etc/my.cnf 不是本脚本生成的（比如 MariaDB/发行版残留），
        # 它的 datadir/socket 很可能和本次部署不一致，这正是 socket 找不到的主因
        cfg_sock=$(cfg_value socket)
        cfg_data=$(cfg_value datadir)
        cfg_base=$(cfg_value basedir)

        if [[ ${KEEP_MYCNF:-0} == 1 ]]; then
            info "KEEP_MYCNF=1，保留已有 ${CNF_FILE}"
            info "注意：脚本按 socket=${SOCK_FILE}、datadir=${DATA_DIR} 检查，若配置不同需自行对齐"
            return 0
        fi

        if { [[ -n $cfg_sock && $cfg_sock != "$SOCK_FILE" ]]; } \
            || { [[ -n $cfg_data && $cfg_data != "$DATA_DIR" ]]; } \
            || { [[ -n $cfg_base && $cfg_base != "$BASE_DIR" ]]; }; then
            info "已有 ${CNF_FILE} 与本次部署路径不一致:"
            info "  socket : ${cfg_sock:-未配置}   期望 ${SOCK_FILE}"
            info "  datadir: ${cfg_data:-未配置}   期望 ${DATA_DIR}"
            info "  basedir: ${cfg_base:-未配置}   期望 ${BASE_DIR}"

            bak="${CNF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
            cp -a "$CNF_FILE" "$bak" && info "原配置已备份: ${bak}"
            write_config || die "生成 ${CNF_FILE} 失败"
            ok "已按本次部署路径重写 ${CNF_FILE}（如要保留原配置请用 KEEP_MYCNF=1）"
            return 0
        fi

        ok "已存在 ${CNF_FILE}，路径与本次部署一致，保留原配置"
        return 0
    fi

    info "生成配置文件 ${CNF_FILE}"
    write_config || die "生成 ${CNF_FILE} 失败"
    ok "配置文件已生成"
}

# ------------------------------- 初始化数据 ---------------------------------
init_datadir() {
    if has_system_tables; then
        ok "数据目录已初始化，跳过"
        return 0
    fi

    if [[ -n $(ls -A "$DATA_DIR" 2>/dev/null) ]]; then
        die "数据目录 ${DATA_DIR} 非空但缺少系统表，请先清理后重试"
    fi

    check_binary_libs || die "缺少动态库，mysqld 无法运行"
    config_check

    info "初始化数据目录（首次启动的临时密码会写入错误日志）..."
    if ! "${BASE_DIR}/bin/mysqld" --defaults-file="$CNF_FILE" --user=mysql --initialize; then
        err "mysqld --initialize 失败，错误日志末尾:"
        tail -n 30 "$ERR_LOG" 2>/dev/null
        die "初始化失败，请查看 ${ERR_LOG}"
    fi
    ok "数据目录初始化完成"
}

# ------------------------------- systemd 单元 -------------------------------
ensure_service() {
    if [[ ! -f $SERVICE_FILE ]]; then
        info "生成 systemd 单元 ${SERVICE_FILE}"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MySQL Server ${MYSQL_VERSION}
Documentation=man:mysqld(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mysql
Group=mysql
ExecStart=${BASE_DIR}/bin/mysqld --defaults-file=${CNF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=65535
Restart=on-failure
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
    else
        ok "systemd 单元已存在，跳过"
    fi

    systemctl daemon-reload || die "systemctl daemon-reload 失败"
    systemctl enable mysql >/dev/null 2>&1 || true
}

# ------------------------------- 启停与检查 ---------------------------------
wait_for_mysql() {
    local i sock

    for ((i = 0; i < 90; i++)); do
        # 进程都没了就立刻失败，不用等满超时
        mysqld_alive || return 1

        # 三种就绪信号任一满足即可：配置里的 socket、3306 端口、任意 mysql socket
        if [[ -S $SOCK_FILE ]] || port_open 3306 || unix_socket_any; then
            sock=$(actual_socket)
            if [[ -n $sock && $sock != "$SOCK_FILE" ]]; then
                info "实际 socket 为 ${sock}（配置里是 ${SOCK_FILE}），后续按实际路径处理"
                SOCK_FILE="$sock"
            fi
            return 0
        fi
        sleep 1
    done
    return 1
}

# 3306 被别的 mysqld/mariadb 占用时，我们的 mysqld 会启动失败，socket 自然也不会出现
check_port_conflict() {
    port_open 3306 || return 0
    service_active && return 0

    err "3306 端口已被占用，可能是系统自带的 mysql/mariadb 正在运行:"
    if have ss; then
        ss -lntp 2>/dev/null | grep ':3306 '
    elif have netstat; then
        netstat -lntp 2>/dev/null | grep ':3306 '
    fi
    die "请先停止占用 3306 的服务（如 systemctl stop mysqld / systemctl stop mariadb）后重试"
}

start_mysql() {
    local sock

    [[ -x "${BASE_DIR}/bin/mysqld" ]] || die "未检测到 ${BASE_DIR}/bin/mysqld，请先执行 install"

    check_binary_libs || die "缺少动态库，mysqld 无法启动"
    config_check

    if service_active; then
        sock=$(actual_socket)
        # 只有“配置里的 socket 确实存在”才算按当前配置跑起来了；
        # 否则很可能是上一次用旧配置启动的进程，必须重启才会加载新配置
        if [[ -S $SOCK_FILE ]] && { [[ -z $sock ]] || [[ $sock == "$SOCK_FILE" ]]; }; then
            ok "MySQL 已在运行（socket: ${SOCK_FILE}）"
            return 0
        fi
        info "运行中的 MySQL 与当前配置不一致（实际 socket: ${sock:-无}，配置: ${SOCK_FILE}）"
        info "重启服务以加载 ${CNF_FILE} ..."
        if ! systemctl restart mysql; then
            diagnose_start_failure
            die "MySQL 重启失败"
        fi
    else
        check_port_conflict
        info "启动 MySQL 服务..."
        if ! systemctl start mysql; then
            diagnose_start_failure
            die "MySQL 启动失败"
        fi
    fi

    if wait_for_mysql; then
        ok "MySQL 已启动"
    else
        diagnose_start_failure
        die "MySQL 在超时时间内未就绪"
    fi
}

stop_mysql() {
    if ! service_active; then
        info "MySQL 未运行，无需停止"
        return 0
    fi
    info "停止 MySQL 服务..."
    systemctl stop mysql || die "停止失败"
    ok "MySQL 已停止"
}

show_status() {
    local iv
    iv=$(installed_version) || iv="未安装"
    echo "安装版本: ${iv}"
    echo "目标版本: ${MYSQL_VERSION:-未选择（install 时会询问）}"
    echo "配置文件: ${CNF_FILE}"
    echo "  basedir : $(cfg_value basedir 2>/dev/null)"
    echo "  datadir : $(cfg_value datadir 2>/dev/null)"
    echo "  socket  : $(cfg_value socket 2>/dev/null)"
    echo
    systemctl status mysql --no-pager -l 2>/dev/null || true
    echo
    echo "--- 监听端口 ---"
    if have ss; then
        ss -lntp 2>/dev/null | grep -E 'mysqld|:3306' || echo "未监听 3306"
    elif have netstat; then
        netstat -lntp 2>/dev/null | grep -E 'mysqld|:3306' || echo "未监听 3306"
    fi
    echo
    echo "--- Unix socket ---"
    if have ss; then
        ss -lx 2>/dev/null | grep -iE 'mysql.*sock' || echo "无 mysql socket"
    elif have netstat; then
        netstat -lx 2>/dev/null | grep -iE 'mysql.*sock' || echo "无 mysql socket"
    fi
    echo
    echo "--- 数据目录 ---"
    if [[ -d $DATA_DIR ]]; then
        du -sh "$DATA_DIR" 2>/dev/null
    else
        echo "数据目录不存在: ${DATA_DIR}"
    fi
    return 0
}

# ------------------------------- 安装后提示 ---------------------------------
get_temp_password() {
    local line
    [[ -f $ERR_LOG ]] || return 1
    line=$(grep 'temporary password' "$ERR_LOG" 2>/dev/null | tail -n 1) || return 1
    [[ -n $line ]] || return 1
    line=${line##*: }
    printf '%s' "$line"
}

ensure_path_env() {
    local line="export PATH=\$PATH:${BASE_DIR}/bin"

    case ":${PATH}:" in
        *":${BASE_DIR}/bin:"*) ;;
        *) export PATH="${PATH}:${BASE_DIR}/bin" ;;
    esac

    if [[ ! -f $PROFILE_FILE ]] || ! grep -qF "$line" "$PROFILE_FILE" 2>/dev/null; then
        {
            echo '# MySQL 客户端路径'
            echo "$line"
        } > "$PROFILE_FILE"
        chmod 644 "$PROFILE_FILE"
        info "已把 ${BASE_DIR}/bin 写入 ${PROFILE_FILE}"
    fi
}

report_install() {
    local pass iv
    iv=$(installed_version) || iv="$MYSQL_VERSION"
    pass=$(get_temp_password) || pass=""

    echo
    echo "==================== 安装信息 ===================="
    echo "  安装版本  : ${iv}"
    echo "  安装目录  : ${BASE_DIR}"
    echo "  数据目录  : ${DATA_DIR}"
    echo "  日志目录  : ${LOG_DIR}"
    echo "  配置文件  : ${CNF_FILE}"
    echo "  Socket    : ${SOCK_FILE}"
    echo "  监听端口  : 3306"
    if [[ -n $pass ]]; then
        echo -e "  临时密码  : ${C_YELLOW}${pass}${C_END}"
        echo "  登录后请立即修改密码:"
        echo "     ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourNewPass';"
    else
        echo "  临时密码  : 未获取到（数据目录此前已初始化，请使用已有密码）"
    fi
    if [[ $iv == 8.0.* ]]; then
        echo "  8.0 提示  : 已设置 default_authentication_plugin=mysql_native_password，"
        echo "              兼容 5.7 客户端；后续新建用户默认使用该插件。"
    fi
    echo "================================================="
    echo
    echo "连接示例:"
    echo "  ${BASE_DIR}/bin/mysql -uroot -p"
    echo "  ${BASE_DIR}/bin/mysql -uroot -p -S ${SOCK_FILE}"
}

# ------------------------------- 主流程 -------------------------------------
do_install() {
    require_root
    select_version

    info "开始安装 MySQL ${MYSQL_VERSION}（basedir=${BASE_DIR}）"

    install_deps
    install_binaries
    ensure_user
    ensure_dirs
    ensure_config
    init_datadir
    ensure_service
    start_mysql
    ensure_path_env
    report_install
}

usage() {
    cat <<EOF
用法: $(basename "$0") [install|start|stop|restart|status|diagnose]

  install   安装 MySQL（每次都会询问：5.7.44 / 8.0.11 / 8.0.23）
  start     启动服务
  stop      停止服务
  restart   重启服务
  status    查看版本与运行状态
  diagnose  打印配置/端口/socket/日志/动态库等诊断信息
  不带参数  进入交互菜单

非交互指定版本:
  MYSQL_VERSION=5.7.44 $(basename "$0") install
  MYSQL_VERSION=8.0.11 $(basename "$0") install
  MYSQL_VERSION=8.0.23 $(basename "$0") install

启动后 socket 未就绪时:
  1) 先执行 $(basename "$0") diagnose 收集信息;
  2) 重点看错误日志末尾的 [ERROR] 行;
  3) 若 /etc/my.cnf 是别处带来的（指向 /var/lib/mysql 等），
     重新执行 install 会自动备份并重写；要保留原配置则加 KEEP_MYCNF=1。
EOF
}

interactive_menu() {
    local an
    echo "请选择要执行的操作:"
    echo "  1) install   安装 MySQL（会询问版本）"
    echo "  2) start     启动服务"
    echo "  3) stop      停止服务"
    echo "  4) restart   重启服务"
    echo "  5) status    查看状态"
    echo "  6) diagnose  诊断（socket/端口/日志）"
    read -r -p "$(printf '%b' "${C_YELLOW}请输入编号或操作名: ${C_END}")" an

    case "$an" in
        1|install)  do_install ;;
        2|start)    require_root; start_mysql ;;
        3|stop)     require_root; stop_mysql ;;
        4|restart)  require_root; stop_mysql; start_mysql ;;
        5|status)   show_status ;;
        6|diagnose) diagnose_start_failure ;;
        *)          err "请输入正确的选项"; exit 1 ;;
    esac
}

main() {
    case "${1:-}" in
        install)  do_install ;;
        start)    require_root; start_mysql ;;
        stop)     require_root; stop_mysql ;;
        restart)  require_root; stop_mysql; start_mysql ;;
        status)   show_status ;;
        diagnose) diagnose_start_failure ;;
        -h|--help|help) usage ;;
        "")       interactive_menu ;;
        *)        err "未知操作: $1"; echo; usage; exit 1 ;;
    esac
}

main "$@"
