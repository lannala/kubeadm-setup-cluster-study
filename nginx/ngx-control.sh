#!/bin/bash
# ============================================================================
#  nginx 管理脚本（启动 / 停止 / 重启 / 状态 / 平滑升级 / 卸载）
#
#  用法:
#     ./ngx_control.sh start|stop|restart|status
#     ./ngx_control.sh reload        # 平滑重载配置（不中断连接）
#     ./ngx_control.sh test          # 校验配置
#     ./ngx_control.sh update        # 编译新版本并平滑升级
#     ./ngx_control.sh remove        # 卸载
#
#  可用环境变量:
#     NGX_HOME=/usr/local/nginx      # nginx 安装目录
#     NGX_CONF=/usr/local/nginx/conf/nginx.conf
#
#  相比原脚本的改进:
#     1. 进程判断改为读 pid 文件 + kill -0 校验，读不到再退回 pgrep，
#        不再用 "ps|grep nginx|egrep -cv grep|$$" 这种连自己进程都算不准的方式;
#     2. stop 使用 nginx -s quit（等价于原 kill），并轮询确认进程真的退出，
#        原脚本 kill 完立刻打印 stopped，紧接着 restart 常因端口未释放而失败;
#     3. restart 先等旧进程退出再启动，不会再出现 “Address already in use”;
#     4. update 里修掉了两个致命问题：configure 参数被整段引号包成单个参数、
#        以及 USR2/WINCH/QUIT 三步之间没有任何等待; 新增新二进制自检、
#        旧二进制备份、失败自动回滚;
#     5. netstat 换 ss（netstat 在 CentOS 8+/新系统已移除），没有 ss 再退回 netstat;
#     6. remove 在删除前把 conf 打包备份，且 /usr/local/nginx 与 /etc/nginx
#        都会清理（原脚本用 elif，只会删一个）。
# ============================================================================
set -o pipefail

NGX_HOME="${NGX_HOME:-/usr/local/nginx}"
NGX_BIN="${NGX_HOME}/sbin/nginx"
NGX_PID="${NGX_HOME}/logs/nginx.pid"
NGX_CONF="${NGX_CONF:-${NGX_HOME}/conf/nginx.conf}"
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

ensure_installed() {
    [[ -x $NGX_BIN ]] || die "未找到 ${NGX_BIN}，请先执行 ngx_install.sh 安装"
}

# --------------------------------- 进程判断 ----------------------------------
master_pid() {
    local pid=""
    if [[ -r $NGX_PID ]]; then
        pid=$(head -n1 "$NGX_PID" 2>/dev/null)
    fi
    if [[ -z $pid ]] && have pgrep; then
        pid=$(pgrep -xo nginx 2>/dev/null)
    fi
    printf '%s' "$pid"
}

running() {
    local pid
    pid=$(master_pid)
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

wait_running() {
    local i
    for i in $(seq 1 20); do
        running && return 0
        sleep 0.5
    done
    return 1
}

wait_stopped() {
    local i
    for i in $(seq 1 30); do
        running || return 0
        sleep 0.5
    done
    return 1
}

# -------------------------------- 信息展示 -----------------------------------
show_info() {
    local pid
    pid=$(master_pid)

    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
        echo -e "${C_GREEN}nginx 正在运行  NGINX_PID: ${pid}${C_END}"
    else
        echo -e "${C_RED}nginx 未运行${C_END}"
        return 1
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
        pgrep -a nginx
    else
        ps -ef 2>/dev/null | grep -F nginx | grep -v grep
    fi
    return 0
}

# --------------------------------- 启停操作 ----------------------------------
ngx_start() {
    require_root
    ensure_installed

    if running; then
        err "nginx 已在运行，重复启动无效  NGINX_PID: $(master_pid)"
        show_info
        return 1
    fi

    "$NGX_BIN" -t >/dev/null 2>&1 || {
        "$NGX_BIN" -t
        die "配置校验失败，未启动（详见上方输出）"
    }

    info "启动 nginx..."
    "$NGX_BIN" || die "nginx 启动失败"

    if wait_running; then
        ok "nginx 已启动  NGINX_PID: $(master_pid)"
        show_info
    else
        tail -n 20 "${NGX_HOME}/logs/error.log" 2>/dev/null
        die "nginx 启动后进程未存活，请查看 ${NGX_HOME}/logs/error.log"
    fi
}

ngx_stop() {
    local answer pid

    require_root
    ensure_installed

    if ! running; then
        err "nginx 未运行，无需停止"
        return 1
    fi

    pid=$(master_pid)
    read -r -p "$(printf '%b' "${C_RED}警告：即将关闭 nginx（PID ${pid}），确认继续？(y/N): ${C_END}")" answer
    case "${answer:-n}" in
        [Yy]*) ;;
        *)
            info "已取消，nginx 继续运行  NGINX_PID: ${pid}"
            show_info
            return 0
            ;;
    esac

    info "正在平滑退出 nginx (PID ${pid}) ..."
    # 优先用 nginx 自身的信号接口，失败再直接给 master 发 QUIT
    "$NGX_BIN" -s quit >/dev/null 2>&1 || kill -QUIT "$pid" 2>/dev/null || true

    if wait_stopped; then
        ok "nginx 已停止"
    else
        err "nginx 未在超时时间内退出，请手动检查 PID ${pid}"
        return 1
    fi
}

ngx_reload() {
    require_root
    ensure_installed

    running || die "nginx 未运行，无法重载配置（请先 start）"

    "$NGX_BIN" -t >/dev/null 2>&1 || {
        "$NGX_BIN" -t
        die "配置校验失败，未重载"
    }

    "$NGX_BIN" -s reload || die "重载失败"
    ok "配置已平滑重载  NGINX_PID: $(master_pid)"
}

ngx_restart() {
    require_root
    ensure_installed

    if running; then
        info "重启：先停止旧进程..."
        "$NGX_BIN" -s quit >/dev/null 2>&1 || kill -QUIT "$(master_pid)" 2>/dev/null || true
        wait_stopped || die "旧进程未能退出，重启中止"
    fi

    ngx_start
}

ngx_test() {
    ensure_installed
    "$NGX_BIN" -t
}

# -------------------------------- 平滑升级 -----------------------------------
# nginx -V 输出里的 configure 参数带有单引号（如 --with-cc-opt='-O2 ...'），
# 必须交给 eval 重新解析，直接 $args 会被拆错
ngx_update() {
    local answer ver src args add_module new_pid old_pid bak f

    require_root
    ensure_installed
    running || die "nginx 未运行，无法平滑升级（请先 start）"

    read -r -p "$(printf '%b' "${C_YELLOW}平滑升级仅适用于编译安装，确认继续？(y/N): ${C_END}")" answer
    case "${answer:-n}" in
        [Yy]*) ;;
        *) info "已取消"; return 0 ;;
    esac

    read -r -p "$(printf '%b' "${C_YELLOW}请输入新版本号（源码目录名里的版本号）：${C_END}")" ver
    [[ -n $ver ]] || die "版本号不能为空"

    src=$(find_one "nginx-${ver}" d) || die "未找到源码目录 nginx-${ver}（请先解压到 /data 等常见目录）"
    info "源码目录: ${src}"

    args=$("$NGX_BIN" -V 2>&1 | sed -n 's/.*configure arguments: //p')
    [[ -n $args ]] || die "无法从 ${NGX_BIN} -V 获取编译参数"
    info "沿用原有编译参数: ${args}"

    read -r -p "$(printf '%b' "${C_YELLOW}需要额外添加的模块（可留空): ${C_END}")" add_module

    # 只允许 --with-xxx / --without-xxx 形式的参数，避免误执行任意命令
    for f in $add_module; do
        [[ $f =~ ^--(with|without)-[A-Za-z0-9_./=:+-]+$ ]] || die "非法模块参数: ${f}"
    done

    (
        cd "$src" || exit 1
        # shellcheck disable=SC2086
        eval ./configure $args $add_module
    ) || die "configure 失败（可查看 ${src}/objs/autoconf.err）"

    info "编译中..."
    ( cd "$src" && make -j"$(nproc 2>/dev/null || echo 2)" ) || die "make 失败"

    local stamp modules_bak=""
    stamp=$(date +%Y%m%d_%H%M%S)

    # 动态模块要跟二进制同版本，替换前先备份旧模块目录，失败时整体回滚
    if [[ -d "${NGX_HOME}/modules" ]]; then
        modules_bak="${NGX_HOME}/modules.bak.${stamp}"
        cp -a "${NGX_HOME}/modules" "$modules_bak" || die "备份动态模块失败"
    fi
    if compgen -G "$src/objs/*.so" >/dev/null 2>&1; then
        mkdir -p "${NGX_HOME}/modules"
        cp -f "$src"/objs/*.so "${NGX_HOME}/modules/" || die "复制动态模块失败"
        info "已同步动态模块到 ${NGX_HOME}/modules"
    fi

    bak="${NGX_BIN}.bak.${stamp}"
    cp -a "$NGX_BIN" "$bak" || die "备份旧二进制失败"
    info "旧二进制已备份: ${bak}"

    old_pid=$(master_pid)
    mv -f "$src/objs/nginx" "$NGX_BIN" || die "替换二进制失败"

    # 预检只是保险，动态模块版本不一致时会告警，最终以 USR2 后新 master 是否存活为准
    if ! "$NGX_BIN" -t >/dev/null 2>&1; then
        err "新二进制配置预检未通过，仍尝试平滑升级（失败会自动回滚）"
    fi
    info "已替换 ${NGX_BIN}，开始平滑升级（旧 PID ${old_pid}）"

    kill -USR2 "$old_pid" || die "发送 USR2 信号失败"

    # 等新 master 起来（pid 文件会被新进程重写，旧 master 写 pid.oldbin）
    for i in $(seq 1 40); do
        sleep 0.5
        new_pid=$(cat "$NGX_PID" 2>/dev/null)
        [[ -n $new_pid && $new_pid != "$old_pid" ]] && break
    done

    if [[ -z $new_pid || $new_pid == "$old_pid" ]] || ! kill -0 "$new_pid" 2>/dev/null; then
        cp -a "$bak" "$NGX_BIN"
        [[ -n $modules_bak ]] && rm -rf "${NGX_HOME}/modules" && mv "$modules_bak" "${NGX_HOME}/modules"
        die "新版本未能启动，已回滚二进制与模块（旧版本仍在服务）"
    fi

    ok "新 master 已启动  NGINX_PID: ${new_pid}"

    # 关掉旧 worker，再退出旧 master
    if [[ -s "${NGX_PID}.oldbin" ]]; then
        kill -WINCH "$(cat "${NGX_PID}.oldbin")" 2>/dev/null || true
        sleep 2
        kill -QUIT "$(cat "${NGX_PID}.oldbin")" 2>/dev/null || true
        sleep 1
    fi

    if [[ -e "${NGX_PID}.oldbin" ]]; then
        sleep 2
        [[ -e "${NGX_PID}.oldbin" ]] && rm -f "${NGX_PID}.oldbin"
    fi

    ok "平滑升级完成，当前版本: $("$NGX_BIN" -v 2>&1)"
    show_info
}

# ---------------------------------- 卸载 -------------------------------------
ngx_remove() {
    local answer backup

    require_root

    read -r -p "$(printf '%b' "${C_YELLOW}警告：即将卸载 nginx 并删除程序目录，确认？(y/N): ${C_END}")" answer
    case "${answer:-n}" in
        [Yy]*) ;;
        *)
            info "已取消"
            return 0
            ;;
    esac

    if running; then
        info "先停止 nginx..."
        "$NGX_BIN" -s quit >/dev/null 2>&1 || kill -QUIT "$(master_pid)" 2>/dev/null || true
        wait_stopped || die "nginx 无法停止，卸载中止"
    fi

    # 删除前备份配置，避免误删线上 conf
    if [[ -d "${NGX_HOME}/conf" ]]; then
        backup="/root/nginx-conf-$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$backup" -C "$NGX_HOME" conf 2>/dev/null && info "配置已备份: ${backup}"
    fi

    local removed=0
    for d in "$NGX_HOME" /etc/nginx; do
        # 只删绝对路径且确实存在，避免变量为空时误删
        if [[ -n $d && $d == /* && -d $d ]]; then
            rm -rf "$d" && info "已删除 ${d}"
            removed=1
        fi
    done

    if (( removed )); then
        ok "nginx 已卸载"
    else
        err "未找到 nginx 安装目录，无需卸载"
        return 1
    fi
}

# ---------------------------------- 入口 -------------------------------------
usage() {
    cat <<EOF
用法: $(basename "$0") {start|stop|reload|restart|status|test|update|remove}

  start     启动 nginx
  stop      停止 nginx（需确认）
  reload    平滑重载配置
  restart   重启（先等旧进程退出）
  status    查看 PID / 端口 / 进程
  test      校验 nginx.conf
  update    编译新版本并平滑升级
  remove    卸载（删除前自动备份 conf）
EOF
}

main() {
    case "${1:-}" in
        start)   ngx_start ;;
        stop)    ngx_stop ;;
        reload)  ngx_reload ;;
        restart) ngx_restart ;;
        status)  ensure_installed; show_info ;;
        test)    ngx_test ;;
        update)  ngx_update ;;
        remove)  ngx_remove ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
