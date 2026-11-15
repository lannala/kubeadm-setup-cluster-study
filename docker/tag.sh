#!/bin/bash
# ============================================================================
#  批量给本地 Docker 镜像打 tag 并推送到内网私有仓库
#
#  用法:
#     ./tag.sh [-k] [-e 关键字] [-r 仓库地址] [-p 端口]
#
#      -k, --keep       推送后保留本地打好的 tag（默认推送完就删除，节省磁盘）
#      -e, --exclude    排除名称/标签中含该关键字的镜像（默认 2.14.4，传 '' 关闭）
#      -r, --registry   手动指定仓库地址（默认自动探测本机 IP）
#      -p, --port       仓库端口（默认 5000）
#      -n, --dry-run    只打印将要执行的命令，不实际打 tag / 推送
#      -h, --help       帮助
#
#  环境变量:
#     REGISTRY / REGISTRY_PORT / EXCLUDE / KEEP_LOCAL=1
#
#  相比原脚本的改进:
#     1. 不再用 "docker images | wc -l" 推算行数再按序号 awk 取镜像（多一行表头
#        就要靠 i<num 的巧合），直接用 --format 取 repo:tag 并逐行遍历;
#     2. 自动探测本机 IP，不再写死 ens33 网卡;
#     3. 推送失败不再静默跳过，最后统一汇总并以非 0 退出;
#     4. 只删除本次新打出来、带仓库前缀的 tag，绝不会误删本地原始镜像。
# ============================================================================
set -o pipefail

REGISTRY="${REGISTRY:-}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
EXCLUDE="${EXCLUDE-2.14.4}"
KEEP_LOCAL="${KEEP_LOCAL:-0}"
DRY_RUN=0

C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_END=$'\033[0m'
[[ -t 1 ]] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_END=''; }

info() { echo -e "${C_YELLOW}[INFO]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
err()  { echo -e "${C_RED}[FAIL]${C_END} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<EOF
用法: $(basename "$0") [-k] [-e 关键字] [-r 仓库地址] [-p 端口] [-n]

  -k, --keep       推送后保留本地打好的 tag（默认推送完就删除）
  -e, --exclude    排除名称/标签中含该关键字的镜像（默认 ${EXCLUDE:-无}）
  -r, --registry   手动指定仓库地址（默认自动探测本机 IP）
  -p, --port       仓库端口（默认 ${REGISTRY_PORT}）
  -n, --dry-run    只打印将要执行的命令，不实际打 tag / 推送
  -h, --help       帮助
EOF
}

# 兼容三种取 IP 的方式，都失败则要求手动指定
detect_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
    [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n $ip ]] || ip=$(ip -4 addr show scope global 2>/dev/null \
        | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
    printf '%s' "$ip"
}

# ------------------------------- 参数解析 -----------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--keep)     KEEP_LOCAL=1; shift ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -e|--exclude)  [[ $# -ge 2 ]] || die "-e 需要一个关键字参数"; EXCLUDE="$2"; shift 2 ;;
        -r|--registry) [[ $# -ge 2 ]] || die "-r 需要一个仓库地址"; REGISTRY="$2"; shift 2 ;;
        -p|--port)     [[ $# -ge 2 ]] || die "-p 需要一个端口号"; REGISTRY_PORT="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             err "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ------------------------------- 环境检查 -----------------------------------
have docker || die "未检测到 docker 命令"
# 加超时：docker 守护进程无响应时 info 可能长时间挂起
timeout 10 docker info >/dev/null 2>&1 || die "docker 守护进程不可用（需要 root 或加入 docker 组）"

if [[ -z $REGISTRY ]]; then
    ip=$(detect_ip)
    [[ -n $ip ]] || die "无法自动探测本机 IP，请用 -r 指定仓库地址"
    REGISTRY="${ip}:${REGISTRY_PORT}"
fi

info "目标仓库: ${REGISTRY}"
[[ -n $EXCLUDE ]] && info "排除关键字: ${EXCLUDE}"

# ------------------------------- 收集镜像 -----------------------------------
# 只取 repo:tag，过滤 <none>，按关键字排除后去重排序
mapfile -t images < <(
    timeout 20 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -v '^<none>:<none>$' \
    | grep -v ':<none>$' \
    | { if [[ -n $EXCLUDE ]]; then grep -vF -- "$EXCLUDE" || true; else cat; fi; } \
    | sort -u
)

[[ ${#images[@]} -gt 0 ]] || die "没有可推送的镜像（排除关键字: ${EXCLUDE:-无}）"

info "共 ${#images[@]} 个镜像待处理"

# ------------------------------- 打 tag 并推送 -------------------------------
total=0; success=0; failed=0; skipped=0
failed_list=()

for image in "${images[@]}"; do
    total=$((total + 1))

    # 已经是本仓库路径的镜像说明之前推过，跳过避免自我覆盖
    if [[ $image == "${REGISTRY}"/* ]]; then
        info "跳过已带仓库前缀的镜像: ${image}"
        skipped=$((skipped + 1))
        continue
    fi

    target="${REGISTRY}/data/${image}"

    if (( DRY_RUN )); then
        echo "docker tag ${image} ${target}"
        echo "docker push ${target}"
        (( KEEP_LOCAL )) || echo "docker rmi -f ${target}"
        continue
    fi

    if ! docker tag "$image" "$target"; then
        err "打 tag 失败: ${image}"
        failed=$((failed + 1)); failed_list+=("$image")
        continue
    fi

    if ! docker push "$target"; then
        err "推送失败: ${target}"
        failed=$((failed + 1)); failed_list+=("$image")
        # 推送失败的 tag 也清掉，避免污染本地镜像列表
        docker rmi -f "$target" >/dev/null 2>&1 || true
        continue
    fi

    ok "已推送: ${target}"
    success=$((success + 1))

    if (( ! KEEP_LOCAL )); then
        docker rmi -f "$target" >/dev/null 2>&1 || err "清理本地 tag 失败: ${target}"
    fi
done

# ------------------------------- 结果汇总 -----------------------------------
echo
echo "==================== 推送结果 ===================="
echo "  镜像总数 : ${total}"
echo "  成功     : ${success}"
echo "  跳过     : ${skipped}"
echo "  失败     : ${failed}"
if (( failed > 0 )); then
    echo "  失败列表 :"
    printf '    - %s\n' "${failed_list[@]}"
    echo "================================================="
    exit 1
fi
echo "================================================="
(( DRY_RUN )) && info "dry-run 模式，未实际执行"
exit 0
