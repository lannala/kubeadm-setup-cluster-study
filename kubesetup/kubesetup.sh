#!/usr/bin/env bash
# =============================================================================
#  kubeadm-install.sh —— CentOS 7.9 一键部署 Kubernetes 1.20.11
#  （Docker 运行时 + ipvs 模式 kube-proxy + Flannel CNI + ansible 批量扩容 worker）
#
#  用法： kubesetup [command] [options]      （首装时： bash kubeadm-install.sh ...）
#
#  本脚本会在执行子命令前自动把自己安装为系统命令 /usr/bin/kubesetup（0755），
#  此后像 ls/mv 一样直接使用，且**删除源脚本后不受影响**（命令是自包含的独立副本）：
#      kubesetup status          kubesetup token          kubesetup -h
#      关闭自动生成： --no-install-cmd      单独安装/卸载： kubesetup install / uninstall
#
#  command（缺省 bootstrap）
#    bootstrap     本机作为 master 初始化，再交互输入 worker 列表自动扩容并装 CNI
#    preflight     只检查前置条件，不做任何修改
#    prepare       单节点准备：yum repo / 时间 / 防火墙 / SELinux / swap / sysctl
#                  / ipvs + docker + kubelet（worker 复用同一子命令）
#    init          本机 kubeadm init，生成并保存 join 命令
#    token         单独生成 join 命令（配合 --token-ttl 0 造永不过期 token）
#    completion    只安装 kubectl / kubeadm 命令补全
#    cni           下发 flannel（kube-flannel-all.yml）并等待节点 Ready
#    ingress       下发 ingress-nginx（kube-ingress.yaml，NodePort）并等待就绪
#    scale         交互输入 worker 数量与 IP，通过 ansible 批量准备 + join
#    drain         缩容：驱逐 Pod、停止调度、摘除节点（--drain-node 指定单台）
#    certs         查看控制面证书有效期（kubeadm certs check-expiration）
#    ports         控制面 insecure 端口（10251/10252）开关：查看 / --on / --off。
#                  关闭时 kubectl get cs 显示 Unhealthy 属正常（组件本身是好的）
#    renew         一键续期全部控制面证书并重启组件（CA 除外，不可续）
#    backup        创建 etcd 一致性快照（ETCD_BACKUP_DIR，保留最近 N 份）
#    status        查看节点 / 控制面 / kube-proxy 模式 / 证书状态
#    reset         清理本机集群
#    install       仅把本脚本安装为系统命令 /usr/bin/kubesetup（其它子命令运行前
#                  会自动做这一步，一般无需单独执行）
#    uninstall     删除 /usr/bin/kubesetup 及其补全文件，不影响已装好的集群
#
#  options（环境变量同名可覆盖；亦可写入 /etc/k8s-install.conf 持久化）
#    --k8s-version 1.20.11         K8S_VERSION
#    --service-cidr 10.96.0.0/16   SERVICE_CIDR
#    --pod-cidr 10.244.0.0/16      POD_CIDR，必须与 flannel 清单中 Network 一致
#    --apiserver-ip 10.0.0.10      API 通告地址，缺省自动探测主网卡 IPv4
#    --image-repository REGISTRY   IMAGE_REPOSITORY
#    --cri-socket          一般不用传：留空由 kubeadm 自动探测（推荐）。
#                          仅当机器装了多个运行时、kubeadm 报多个 CRI 时才指定，
#                          例如 unix:///run/containerd/containerd.sock
#    --node-name master1           主机名（含 /etc/hosts 维护）
#    --ssh-user root               ANSIBLE_SSH_USER
#    --ssh-pass '密码'              仅当系统已装 sshpass 时生效；默认不需要它，
#                                  scale 会逐台调 ssh-copy-id 让你手输密码
#    --ssh-key PATH                使用的私钥（缺省 ~/.ssh/id_rsa，不存在会自动生成）
#    --inventory /root/k8s-workers.ini  worker 主机清单输出路径（脚本自己用的）
#    --ansible-hosts /etc/ansible/hosts  同步到的系统清单（受管块，幂等）
#    --no-sync-hosts               不同步 /etc/ansible/hosts
#    --ansible-python PATH         远端 python 路径；留空由 ansible 自动发现
#    --manifest PATH               flannel 清单输出路径（缺省 $HOME/kube-flannel-all.yml）
#    --ingress-manifest PATH       ingress 清单输出路径（缺省 $HOME/kube-ingress.yaml）
#    --keep-backups                保留 /var/backups/kubesetup/<ts>/（默认成功后自动删除）
#    --log-keep N                  只保留最近 N 份日志（缺省 2）
#    --cmd-name kubesetup          生成的系统命令名
#    --cmd-dir /usr/bin            系统命令安装目录
#    --force                       master 已初始化时强制 reset 重建（危险）
#    --insecure-ports              放开 scheduler/controller-manager 的 10251/10252
#    --restart-network             下发 sysctl 后重启 network（会闪断 SSH，慎用）
#    --token-ttl 0                 join token 有效期。本脚本面向学习场景，默认 0
#                                  = 永不过期；要收紧传 --token-ttl 24h / 30m
#    --ttl-forever                 等价于 --token-ttl 0
#    --no-completion               不安装 kubectl / kubeadm 命令补全
#    --no-install-cmd              不把本脚本安装为 /usr/bin/kubesetup 命令
#    -y|--yes   -n|--dry-run   -v|--verbose   -l|--log-file PATH   -h|--help
#
#  token 与补全（学习场景常用）
#    默认即永不过期（TOKEN_TTL=0），随时可再造一个 join 命令：
#      kubesetup token                    # 永不过期（默认）
#      kubesetup token --token-ttl 30m    # 改成 30 分钟
#      kubesetup token --ttl-forever      # 显式声明永不过期
#      kubeadm token list                               # EXPIRES 列 = never 即永不过期
#      kubeadm token delete <token-id>                  # 学完清理，避免遗留可用 token
#    安全提醒：token 是集群入场券，永不过期的一直可用——学习环境随意，
#          若机器可达公网，建议加完节点后 delete，或改用 --token-ttl 24h。
#    补全：kubectl/kubeadm 写入 /etc/profile.d/k8s-completion.sh（系统级，root 与
#          普通用户都生效，worker 节点同样安装）；kubesetup 自身的子命令补全写入
#          /etc/bash_completion.d/kubesetup（纯 bash，无需 bash-completion 包），
#          子命令清单与脚本内 SUBCOMMANDS 数组同源，不会漂移。
#
#  命令安装：每次运行在分派子命令之前把自己装成 /usr/bin/kubesetup（原子 mv + 0755），
#          这样即使本次子命令中途失败也已就位；脚本完全自包含，之后可放心删除本文件：
#              kubesetup <TAB>                    # 列全部子命令
#              kubesetup status / kubesetup token # 与源脚本子命令完全一致
#          关闭： --no-install-cmd   手动： kubesetup install / uninstall
#
#  分步示例（等价于原脚本尾部那段 ansible + “eval $tocken” 的逻辑）：
#    ansible -i /root/k8s-workers.ini workers -m copy \
#      -a "src=./kubeadm-install.sh dest=/usr/bin/kubesetup mode=0755"
#    ansible -i /root/k8s-workers.ini workers -m shell -a "kubesetup prepare -y"
#    ansible -i /root/k8s-workers.ini workers -m shell -a "$(cat ~/kubeadm-join-command.txt)"
#    （scale 子命令自动做这三步，并顺带让 worker 上也有 kubesetup 命令）
#
#  注：/etc/yum.repos.d/Centos-Base.repo 与 kube-flannel-all.yml 正文按要求原样保留。
# =============================================================================

set -Eeuo pipefail
umask 077

# ----------------------------- 1. 可调参数 -----------------------------------
CONF_FILE="${CONF_FILE:-/etc/k8s-install.conf}"
# shellcheck disable=SC1090
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE" || true

K8S_VERSION="${K8S_VERSION:-1.20.11}"                  # 三件套锁定同一版本
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/16}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"                  # 与清单里的 Network 绑定
FLANNEL_NETWORK="${FLANNEL_NETWORK:-}"                 # 空 = 从清单读取（清单是唯一来源）
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
API_ADVERTISE_ADDRESS="${API_ADVERTISE_ADDRESS:-}"     # 空 = 自动探测
# CRI socket：**默认为空**，让 kubeadm 自己按默认流程处理（写 kubelet 配置 → 启动
# kubelet → 自动获得 CRI）。显式指定它会让 kubeadm 在 preflight 阶段就去拨该 socket，
# 而首次 init 前该 socket 必然不存在（kubelet 缺 /var/lib/kubelet/config.yaml 起不来），
# 于是报 [ERROR CRI]；绕过 preflight 又会在拉镜像阶段报 [ERROR ImagePull]。
# 只有在系统里同时装了多个运行时、kubeadm 无法自动判断时，才需要显式传 --cri-socket。
CRI_SOCKET="${CRI_SOCKET:-}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/data/docker_data}"
NTP_SERVER="${NTP_SERVER:-ntp1.aliyun.com}"
DOCKER_REPO_URL="${DOCKER_REPO_URL:-http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo}"

FLANNEL_MANIFEST="${FLANNEL_MANIFEST:-$HOME/kube-flannel-all.yml}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-$HOME/kube-ingress.yaml}"   # ingress-nginx 清单落盘位置
JOIN_FILE="${JOIN_FILE:-$HOME/kubeadm-join-command.txt}"
WORKER_INVENTORY="${WORKER_INVENTORY:-/root/k8s-workers.ini}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/usr/bin/kubesetup}"   # 分发后 worker 上直接用的命令路径
ANSIBLE_SSH_USER="${ANSIBLE_SSH_USER:-root}"
# 是否把 worker 同步进 /etc/ansible/hosts（受管块，幂等）。开着的好处：
# 手工敲 `ansible workers -m ping` 不用带 -i；不想动系统文件就 --no-sync-hosts。
SYNC_ANSIBLE_HOSTS="${SYNC_ANSIBLE_HOSTS:-1}"
ANSIBLE_HOSTS_FILE="${ANSIBLE_HOSTS_FILE:-/etc/ansible/hosts}"
# 远端 python 解释器：留空 = 交给 ansible 自己发现（推荐，兼容 CentOS 7 的 python
# 与 CentOS 8+ 的 python3）。只有自动发现失败时才需要显式指定，例如
#   --ansible-python /usr/bin/python            （CentOS 7）
#   --ansible-python /usr/libexec/platform-python（CentOS 8+）
ANSIBLE_PYTHON_INTERPRETER="${ANSIBLE_PYTHON_INTERPRETER:-}"
# ip -> 实测到的 python 路径（由 probe_remote_pythons 填写，写进清单）
declare -A REMOTE_PY=()
# 可选的 worker root 密码，仅用于「自动分发 SSH 公钥」（经 sshpass）。
# 留空时：交互终端会提示输入一次（不回显、不落盘）；非交互场景则跳过自动分发并给出命令。
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa}"
ANSIBLE_FORKS="${ANSIBLE_FORKS:-5}"
# 所有 ansible 调用统一带这些 ssh 参数：
#  - StrictHostKeyChecking=no  不弹 "continue connecting (yes/no)"
#  - ConnectTimeout=10         节点不通时快速失败，不傻等
#  - BatchMode=yes             禁止交互式密码提示（免密没配好就直接报错退出）
# 用 JSON 形式的 extra-vars：值里带空格时最稳，ansible 2.7 也能正确解析。
ANSIBLE_COMMON=(-e '{"ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"}')
WORKER_HOST_PREFIX="${WORKER_HOST_PREFIX:-worker}"     # worker1 worker2 ...
NODE_NAME="${NODE_NAME:-}"

RESTART_NETWORK="${RESTART_NETWORK:-0}"
ALLOW_INSECURE_PORTS="${ALLOW_INSECURE_PORTS:-0}"
# join token 有效期。kubeadm 语义：--ttl 0 = 永不过期；缺省 24h。
# 本脚本面向学习场景，默认 0（永不过期），方便反复加/删 worker；
# 要收紧时用 --token-ttl 24h（或 30m 等），加完节点也可 kubeadm token delete 清理。
TOKEN_TTL="${TOKEN_TTL:-0}"
INSTALL_COMPLETION="${INSTALL_COMPLETION:-1}"   # 1 = 安装 kubectl/kubeadm 补全
BASH_COMPLETION_PKG="${BASH_COMPLETION_PKG:-bash-completion}"
# 系统命令：每次运行结束把自己原子安装为 /usr/bin/kubesetup（独立副本，删源脚本不影响）。
# 用 --no-install-cmd 关闭；kubesetup install / uninstall 手动管理。
SYS_CMD_NAME="${SYS_CMD_NAME:-kubesetup}"
SYS_CMD_DIR="${SYS_CMD_DIR:-/usr/bin}"
INSTALL_SYS_CMD="${INSTALL_SYS_CMD:-1}"
CMD_COMPLETION_FILE="${CMD_COMPLETION_FILE:-/etc/bash_completion.d/${SYS_CMD_NAME}}"
COMPLETION_PROFILE="${COMPLETION_PROFILE:-/etc/profile.d/k8s-completion.sh}"

# 子命令唯一清单：参数解析白名单、命令补全都由此生成，避免多处漂移。
# 改子命令只需改这一行 + 对应的 case 分支。
SUBCOMMANDS=(bootstrap preflight prepare init token completion cni ingress scale drain ports certs renew backup status reset install uninstall)
# 通用选项：供 kubesetup <TAB> 补全
CMD_OPTIONS=(--k8s-version --service-cidr --pod-cidr --apiserver-ip --image-repository
             --cri-socket --node-name --ssh-user --inventory --manifest --log-file
             --token-ttl --ttl-forever --no-completion --no-install-cmd
             --force --insecure-ports --restart-network --yes --dry-run --verbose --help -h
             --drain-node --backup-dir --backup-keep --on --off --keep-backups --log-keep
             --no-crictl-download --crictl-version)
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
# 运行结束后不留多余文件：备份集中放一个目录、成功即删；旧日志只保留最近 N 份
LOG_KEEP="${LOG_KEEP:-2}"
# crictl 兼容性：kubelet 1.20 的 dockershim 只说 CRI v1alpha2，crictl ≥1.25 只说 v1。
# 检测到不兼容时自动装这个版本到 /usr/local/bin（--no-crictl-download 可关）。
CRICTL_VERSION_COMPAT="${CRICTL_VERSION_COMPAT:-v1.22.0}"
CRICTL_DOWNLOAD="${CRICTL_DOWNLOAD:-1}"
PORTS_MODE="${PORTS_MODE:-status}"   # ports 子命令：status|on|off
# 新增功能相关
DRAIN_NODE="${DRAIN_NODE:-}"                         # drain 单节点：--drain-node worker2
ETCD_BACKUP_DIR="${ETCD_BACKUP_DIR:-/root/etcd-backups}"   # etcd 快照目录
ETCD_BACKUP_KEEP="${ETCD_BACKUP_KEEP:-7}"            # 保留最近 N 份快照
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
FORCE="${FORCE:-0}"

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="${LOG_FILE:-/var/log/kubeadm-install-$(date +%Y%m%d-%H%M%S).log}"

# ----------------------------- 2. 日志与通用工具 ------------------------------
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'
[[ -t 2 ]] || { C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_RST=""; }

_log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s==> %s%s\n' "$C_CYN" "$*" "$C_RST" >&2; _log INFO "$*"; }
ok()   { printf '%s    [ok] %s%s\n' "$C_GRN" "$*" "$C_RST" >&2; _log OK "$*"; }
warn() { printf '%s    [warn] %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; _log WARN "$*"; }
err()  { printf '%s    [err] %s%s\n' "$C_RED" "$*" "$C_RST" >&2; _log ERR "$*"; }
die()  { err "$*"; exit 1; }
debug() { [[ "$VERBOSE" == 1 ]] && printf '    · %s\n' "$*" >&2 || true; }

on_error() {
  local code=$? line=${1:-?} cmd=${2:-}
  err "第 ${line} 行执行失败(exit ${code})： ${cmd}"
  err "完整日志： $LOG_FILE"
  exit "$code"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
# 收尾清理（成功删备份 / 失败保留）。注意 cleanup_backups 定义在后面，trap 用的是运行时解析。
trap 'cleanup_backups' EXIT

# 所有“会改变系统状态”的动作都必须经过下面三个入口，dry-run 才能真正做到零副作用
dry() { printf '%s[dry-run]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; _log DRY "$*"; }

run() {           # 需要看到输出的动作
  if [[ "$DRY_RUN" == 1 ]]; then dry "$*"; return 0; fi
  "$@"
}
quiet() {         # 噪声大的动作（systemctl/modprobe/yum…），输出并入日志
  if [[ "$DRY_RUN" == 1 ]]; then dry "$*"; return 0; fi
  "$@" >>"$LOG_FILE" 2>&1
}
write_file() {    # $1=目标路径 [$2=八进制权限]；stdin=内容。脚本 umask 077，
                  # 系统级需被其他用户/组件读取的文件必须显式给权限
  local f=$1 mode=${2:-}
  if [[ "$DRY_RUN" == 1 ]]; then dry "写文件 $f${mode:+ (chmod $mode)}"; return 0; fi
  cat >"$f"
  [[ -n "$mode" ]] && chmod "$mode" "$f"
  debug "已写入 $f${mode:+ ($mode)}"
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
# 提示语里“怎么再跑一次”的前缀：以系统命令身份运行时显示 kubesetup，否则显示 bash <脚本路径>
self_invocation() {
  local target="${SYS_CMD_DIR}/${SYS_CMD_NAME}"
  if [[ -e "$target" ]] && [[ "$(readlink -f "$SELF_PATH" 2>/dev/null)" == "$(readlink -f "$target" 2>/dev/null)" ]]; then
    printf '%s\n' "$SYS_CMD_NAME"
  else
    printf 'bash %s\n' "$SELF_PATH"
  fi
}
need_root() {
  is_root && return 0
  [[ "$DRY_RUN" == 1 ]] && { warn "非 root（dry-run 允许，真实执行需 root）"; return 0; }
  die "此操作需要 root： $(self_invocation) ${CMD:-} ..."
}
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "缺少命令： $1"; }
# 子命令判定唯一入口：白名单 = SUBCOMMANDS 数组（补全同源，不会漂移）
is_subcommand() { local s; for s in "${SUBCOMMANDS[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
confirm() {
  [[ "$ASSUME_YES" == 1 || "$DRY_RUN" == 1 ]] && return 0
  [[ -t 0 ]] || { warn "非交互终端且未加 -y，跳过确认： $1"; return 0; }
  local ans
  read -r -p "$1 [y/N] " ans || die "读取输入失败"
  [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
}

_yum_try() {            # 返回安装结果，不 die / 不 warn，供上层决定策略
  if [[ "$DRY_RUN" == 1 ]]; then dry "yum install -y $*"; return 0; fi
  info "yum install $*"
  if yum install -y "$@" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  tail -n 15 "$LOG_FILE" >&2 || true
  return 1
}
yum_install() {         # 必需包：失败即中断
  _yum_try "$@" || die "yum install 失败： $*"
}
yum_install_opt() {     # 可选包：失败只告警（注意不能走 die，否则 || 分支永远到不了）
  _yum_try "$@" || warn "可选包安装失败，已忽略： $*"
}

# 备份统一收进一个"本次运行"目录（不再在 /etc、/root 下散落 *.bak.<ts>）：
#   /var/backups/kubesetup/<时间戳>/etc/fstab 与 /etc/fstab 同构
# 运行成功结束时整目录删除（失败则保留，便于回溯）。--keep-backups 可强制保留。
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/kubesetup}"
BACKUP_RUN_DIR=""
KEEP_BACKUPS="${KEEP_BACKUPS:-0}"

backup_path() {
  local p=$1 dst
  [[ -e "$p" || -L "$p" ]] || return 0
  [[ "$DRY_RUN" == 1 ]] && { dry "备份 $p"; return 0; }
  if [[ -z "$BACKUP_RUN_DIR" ]]; then
    BACKUP_RUN_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    if ! mkdir -p "$BACKUP_RUN_DIR" 2>/dev/null; then
      warn "无法创建 $BACKUP_ROOT，退回到同名 .bak 备份"
      cp -a "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)" && debug "已备份 $p"
      return 0
    fi
  fi
  dst="$BACKUP_RUN_DIR/${p#/}"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  if cp -a "$p" "$dst" 2>/dev/null; then
    debug "已备份 $p -> $dst"
  else
    warn "备份 $p 失败，改用同名 .bak"
    cp -a "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || warn "备份 $p 彻底失败"
  fi
}

# EXIT 收尾：成功则删掉本次备份目录（用户要求"运行完不留多余文件"）；
# 失败保留并提示路径，方便对照原始配置。任何情况下都不动业务文件本身。
cleanup_backups() {
  local rc=$?
  [[ -n "$BACKUP_RUN_DIR" ]] || return 0
  [[ -d "$BACKUP_RUN_DIR" ]] || return 0
  if (( rc == 0 )) && [[ "$KEEP_BACKUPS" != 1 ]]; then
    rm -rf "$BACKUP_RUN_DIR" 2>/dev/null && debug "已清理本次备份： $BACKUP_RUN_DIR"
    # 顺手清掉空的父目录，别留下空壳
    rmdir "$BACKUP_ROOT" 2>/dev/null || true
  elif [[ "$KEEP_BACKUPS" == 1 || $rc -ne 0 ]]; then
    printf '    [info] 原始文件备份保留在： %s（成功后默认会删除，--keep-backups 可保留）\n' "$BACKUP_RUN_DIR" >&2
  fi
  return 0
}

# 旧日志剪枝：默认只保留最近 2 份 kubeadm-install-*.log，避免 /var/log 越攒越多
prune_old_logs() {
  local keep="${LOG_KEEP:-2}" dir base
  [[ "$LOG_FILE" == /dev/null || -z "$LOG_FILE" ]] && return 0
  dir="$(dirname "$LOG_FILE")"
  base="$(basename "$LOG_FILE")"
  [[ "$base" == kubeadm-install-*.log ]] || return 0
  local f
  ls -1t "$dir"/kubeadm-install-*.log 2>/dev/null | tail -n +$(( keep + 1 )) | while read -r f; do
    [[ "$f" == "$LOG_FILE" ]] && continue
    rm -f "$f" 2>/dev/null && debug "清理旧日志： $f"
  done
}

valid_ipv4() {
  local ip=$1 seg
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for seg in $ip; do (( 10#$seg <= 255 )) || return 1; done   # 10# 避免 "08" 被当八进制
  return 0
}
valid_cidr() {
  local c=$1
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local host=${c%/*} mask=${c#*/} seg
  local IFS=.
  for seg in $host; do (( 10#$seg <= 255 )) || return 1; done
  (( 10#$mask <= 32 )) || return 1
  return 0
}

# 探测本机 IPv4。原脚本 `ifconfig | grep -E -A 1 "ens3|eth0" | awk 'NR>1{print $3}'`
# 在多网卡 / 有 inet6 行时会取到空值或错误地址，这里优先用默认路由的出口地址。
detect_ip() {
  local ip=""
  # 用户显式指定过 --apiserver-ip 时优先采用（worker 上该值为空，仍走自动探测）
  if [[ -n "${API_ADVERTISE_ADDRESS:-}" ]] && valid_ipv4 "$API_ADVERTISE_ADDRESS"; then
    printf '%s\n' "$API_ADVERTISE_ADDRESS"; return 0
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)" || true
  [[ -n "$ip" ]] || ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -vE '^(127|169\.254)\.' | head -n1)" || true
  [[ -n "$ip" ]] || ip="$(ifconfig 2>/dev/null | awk '{for(i=1;i<=NF;i++){s=$i; sub(/^inet( addr:)?/,"",s); if(s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && s !~ /^(127|169\.254)\./){print s; exit}}}')" || true
  valid_ipv4 "${ip:-}" || return 1
  printf '%s\n' "$ip"
}

# 需要“探不到就直接失败”的调用点用它（比如 kubeadm init 的通告地址）
detect_ip_or_die() { detect_ip || die "无法自动探测本机 IPv4，请用 --apiserver-ip 指定"; }

# wait_for "描述" 超时秒 命令... ；超时只告警不中断（就绪类等待均可事后人工确认）
wait_for() {
  local desc=$1 timeout=$2; shift 2
  local end=$(( $(date +%s) + timeout ))
  while true; do
    if "$@" >/dev/null 2>&1; then ok "$desc"; return 0; fi
    if (( $(date +%s) >= end )); then warn "$desc 超时（${timeout}s），请手工确认"; return 0; fi
    sleep 5
  done
}

require_cidr_match() {
  [[ "$POD_CIDR" == "${FLANNEL_NETWORK:-$POD_CIDR}" ]] && return 0
  die "POD_CIDR=$POD_CIDR 与 flannel 清单中的 Network=${FLANNEL_NETWORK} 不一致，跨节点 Pod 会不通。清单按要求不可改，请传 --pod-cidr ${FLANNEL_NETWORK}"
}

# 从 kube-flannel-all.yml 里读出 Network 字段，避免手写两份网段。
# 内嵌清单未修改，其 Network 恒为下面的 EMBEDDED_FLANNEL_NETWORK，文件不存在时按它校验。
EMBEDDED_FLANNEL_NETWORK="10.244.0.0/16"
flannel_network_from_manifest() {
  local f=$1 n=""
  if [[ -f "$f" ]]; then
    n="$(grep -oE '"Network":[[:space:]]*"[0-9./]+"' "$f" 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')" || true
  fi
  printf '%s\n' "${n:-$EMBEDDED_FLANNEL_NETWORK}"
}

# ----------------------------- 3. 节点级初始化 --------------------------------
# 3.1 yum 仓库
write_yum_repo() {
  need_root
  local repo_dir=/etc/yum.repos.d f moved=0
  local bak="${repo_dir}/back"
  shopt -s nullglob
  for f in "$repo_dir"/*.repo; do
    # 只有真要挪文件时才建 back/，避免没有 repo 可挪时留下空目录
    [[ -e "$f" ]] || continue
    run mkdir -p "$bak"
    run mv -f "$f" "$bak/" && moved=1
  done
  shopt -u nullglob
  (( moved )) && info "原 repo 文件已备份到 $bak"
  info "写入 $repo_dir/Centos-Base.repo"
  # 以下内容按要求原样保留，未做任何修改
  write_file "$repo_dir/Centos-Base.repo" 0644 << 'EOF'
[base]
name=CentOS-7.9.2009 - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-7.9.2009 - Updates - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-7.9.2009 - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[centosplus]
name=CentOS-7.9.2009 - Plus - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/centosplus/$basearch/
failovermethod=priority
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[contrib]
name=CentOS-7.9.2009 - Contrib - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/contrib/$basearch/
failovermethod=priority
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=https://mirrors.aliyun.com/epel-archive/7/$basearch/
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7

[kubernetes] 
name=Kubernetes 
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64 
enabled=1 
gpgcheck=0 
repo_gpgcheck=0 
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
  ok "Centos-Base.repo 已写入（base/updates/extras/epel/kubernetes 均指向阿里云）"
  command -v yum >/dev/null 2>&1 && quiet yum makecache fast || warn "yum makecache 失败（网络受限？），仍继续尝试安装"
}

# 3.2 时间 / 防火墙 / SELinux / swap / 内核参数 / IPVS
prepare_os() {
  need_root

  info "时区与时间同步"
  yum_install_opt ntpdate
  run timedatectl set-timezone Asia/Shanghai
  command -v ntpdate >/dev/null 2>&1 && \
    { quiet ntpdate "$NTP_SERVER" || warn "ntpdate $NTP_SERVER 失败，已跳过（离线或源不可达）"; }
  # ntpdate 只校时一次，长期漂移交给 chronyd —— 证书与 etcd 对时钟非常敏感
  yum_install_opt chrony
  quiet systemctl enable --now chronyd || warn "chronyd 启动失败，已跳过"

  info "关闭防火墙"
  quiet systemctl stop firewalld   || true
  quiet systemctl disable firewalld || true

  info "关闭 SELinux"
  if [[ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]]; then
    run sed -i 's/^SELINUX=enforcing/SELINUX=disabled/; s/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
    quiet setenforce 0 || warn "setenforce 0 未生效，重启后由 /etc/selinux/config 生效"
  fi

  info "关闭 swap"
  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]] || \
     grep -vE '^[[:space:]]*#' /etc/fstab | grep -qE '[[:space:]]swap[[:space:]]'; then
    backup_path /etc/fstab
    run sed -ri 's|^([^#].*[[:space:]]swap[[:space:]].*)|#\1|' /etc/fstab
    quiet swapoff -a || warn "swapoff -a 失败，请检查 /etc/fstab"
  fi

  info "内核参数"
  #  k8s 参数写独立文件，sysctl.conf 仅在缺该行时追加。
  write_file /etc/sysctl.d/k8s.conf 0644 <<'KSYSEOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
KSYSEOF
  grep -qE '^[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf 2>/dev/null || \
    run bash -c 'echo "net.ipv4.ip_forward = 1" >>/etc/sysctl.conf'

  quiet modprobe br_netfilter || warn "br_netfilter 加载失败，CNI 桥接网络可能异常"
  # modules-load.d / sysctl.d 由 systemd-modules-load 等组件读取，须对系统可读
  if ! grep -qxF 'br_netfilter' /etc/modules-load.d/k8s.conf 2>/dev/null; then
    printf 'br_netfilter\n' | write_file /etc/modules-load.d/k8s.conf 0644
  fi
  quiet sysctl --system || quiet sysctl -p || warn "sysctl 参数下发失败"
  [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == 1 ]] || warn "ip_forward 仍为 0，Pod 跨节点将不通"

  info "IPVS 与网络工具"
  yum_install ipset ipvsadm bash-completion
  yum_install_opt conntrack-tools
  run mkdir -p /etc/sysconfig/modules
  write_file /etc/sysconfig/modules/ipvs.modules 0755 <<'IPVSEOF'
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
IPVSEOF
  run chmod 755 /etc/sysconfig/modules/ipvs.modules
  run bash /etc/sysconfig/modules/ipvs.modules
  lsmod 2>/dev/null | grep -qE '^ip_vs([[:space:]]|$)' || warn "ip_vs 未加载，kube-proxy ipvs 模式不可用"
  if ! grep -qxF 'nf_conntrack' /etc/modules-load.d/k8s.conf 2>/dev/null; then
    run bash -c 'echo nf_conntrack >>/etc/modules-load.d/k8s.conf'   # 追加：保留上面写入的 br_netfilter
  fi

  if [[ "$RESTART_NETWORK" == 1 ]]; then
    warn "即将重启 network，SSH 可能闪断"
    quiet systemctl restart network || warn "restart network 失败"
  else
    debug "跳过 systemctl restart network（确需重启请加 --restart-network）"
  fi
}

# 3.3 Docker。
docker_install() {
  need_root
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    info "docker 已就绪： $(docker --version 2>/dev/null)"
    return 0
  fi
  yum_install yum-utils
  if ! ls /etc/yum.repos.d/*docker-ce*.repo >/dev/null 2>&1; then
    info "添加 docker-ce 仓库"
    quiet yum-config-manager --add-repo "$DOCKER_REPO_URL" || die "添加 docker-ce repo 失败"
  fi
  yum_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run mkdir -p "$DOCKER_DATA_ROOT"
  local cf=/etc/docker/daemon.json
  run mkdir -p /etc/docker
  [[ -s "$cf" ]] && backup_path "$cf"
  info "写入 $cf（cgroup=systemd, data-root=/data/docker_data, 6 个加速器）"
  write_file "$cf" 0644 <<DEOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "data-root": "${DOCKER_DATA_ROOT}/",
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://docker.1ms.run",
    "https://docker-0.unsee.tech",
    "https://docker.m.daocloud.io",
    "https://mirror.ccs.tencentyun.com",
    "https://registry.cyou"
  ],
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {"max-size": "500m", "max-file": "3"},
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "storage-driver": "overlay2"
}
DEOF

  quiet systemctl daemon-reload
  quiet systemctl enable docker
  run systemctl restart docker || { tail -n 20 "$LOG_FILE" >&2 || true; die "docker 启动失败： journalctl -u docker"; }
  if [[ "$DRY_RUN" != 1 ]]; then
    docker info 2>/dev/null | grep -E 'Cgroup Driver|Docker Root Dir|Storage Driver' >&2 || die "docker 状态异常"
    docker info 2>/dev/null | grep -qi 'Cgroup Driver:[[:space:]]*systemd' || \
      die "docker cgroup 驱动非 systemd，kubelet 无法加入集群（检查 $cf）"
  fi
}

# 3.4 kubeadm / kubelet / kubectl
kubeadm_install() {
  need_root
  local v="$K8S_VERSION" have=""
  local want="v${v}"
  have="$(kubelet --version 2>/dev/null | awk '{print $2}')" || true
  if [[ "$have" == "$want" ]]; then
    info "kubelet 已是 ${want}，跳过安装"
  else
    yum_install "kubelet-${v}" "kubeadm-${v}" "kubectl-${v}"
  fi
  [[ "$DRY_RUN" == 1 ]] && { info "[dry-run] 跳过安装校验与 kubelet 配置"; return 0; }
  kubelet --version >&2 || die "kubelet 安装校验失败"
  command -v kubectl >/dev/null 2>&1 || die "kubectl 安装校验失败"

  local cf=/etc/sysconfig/kubelet
  [[ -f "$cf" ]] && backup_path "$cf"
  # 注意：cgroup 驱动只由 kubeadm 的 KubeletConfiguration.cgroupDriver 单一来源下发
  # （会写进 /var/lib/kubelet/config.yaml，worker 通过 kubelet-config ConfigMap 继承）。
  # 早期版本这里还额外传了 --cgroup-driver，与 kubeadm 的 kubeletExtraArgs 重复下发
  # 同一个 flag，属于无谓的冲突源，已移除。
  local node_ip extra=""
  node_ip="$(detect_ip 2>/dev/null || true)"
  [[ -n "$node_ip" ]] && extra="--node-ip=$node_ip"
  info "写入 $cf： KUBELET_EXTRA_ARGS=\"${extra:-（空，仅用 kubeadm 下发的配置）}\""
  printf 'KUBELET_EXTRA_ARGS="%s"\n' "$extra" | write_file "$cf" 0644
  quiet systemctl daemon-reload
  # 只 enable，**不**在 init 前启动 kubelet。
  # 原因：init 前 kubelet 缺 /var/lib/kubelet/config.yaml，启动即 klog.Fatal 退出；
  # 若在此处反复拉起，会触发 systemd 的启动频率限制（StartLimitBurst），
  # 导致 kubeadm 在 kubelet-start 阶段真正需要启动它时被拒绝。
  # 顺带清掉历史失败计数，避免之前的手工尝试留下 rate-limit。
  quiet systemctl reset-failed kubelet || true
  quiet systemctl enable kubelet || warn "systemctl enable kubelet 失败"
}

# 单机全套准备：worker 复用同一入口，避免 master/worker 配置漂移
node_prepare() {
  write_yum_repo
  prepare_os
  docker_install
  kubeadm_install
  install_shell_completion   # kubectl/kubeadm 已就位，master 与 worker 都装系统级补全
  setup_crictl               # 写 /etc/crictl.yaml，并检查 crictl 版本是否与 dockershim 兼容
  ok "节点准备完成： $(hostname)"
}

# ----------------------------- 3.9 crictl 配置 -------------------------------
# crictl 不带 --runtime-endpoint 时会依次尝试 dockershim / containerd / crio 四个
# socket，全失败就吐一屏 WARN 和 "CRI v1 runtime API is not implemented"，
# 极易被误判成"集群坏了"。这里显式写死唯一 endpoint。
detect_cri_endpoint() {
  if [[ -n "$CRI_SOCKET" ]]; then printf '%s\n' "$CRI_SOCKET"; return 0; fi
  if systemctl is-active --quiet docker 2>/dev/null; then
    printf 'unix:///var/run/dockershim.sock\n'; return 0
  fi
  if systemctl is-active --quiet containerd 2>/dev/null; then
    printf 'unix:///run/containerd/containerd.sock\n'; return 0
  fi
  printf 'unix:///var/run/dockershim.sock\n'
}

setup_crictl() {
  local f=/etc/crictl.yaml ep
  ep="$(detect_cri_endpoint)"
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "写 $f（runtime-endpoint: $ep）"
  else
    [[ -f "$f" ]] && backup_path "$f"
    write_file "$f" 0644 <<YML
runtime-endpoint: ${ep}
image-endpoint: ${ep}
timeout: 10
debug: false
YML
    ok "crictl 配置： $f -> $ep"
  fi

  # 版本兼容性：kubelet 1.20 的 dockershim 只实现 CRI v1alpha2，
  # 而 crictl v1.25+ 只讲 v1，于是报 "CRI v1 runtime API is not implemented"。
  # 注意 crictl 版本形如 v1.25.0，其中 25 是**次版本**，要按第二段判断。
  [[ "$ep" == *dockershim* ]] || return 0
  command -v crictl >/dev/null 2>&1 || return 0
  local ver minor
  ver="$(crictl --version 2>/dev/null | awk '{print $NF}')"
  ver="${ver#v}"
  minor="$(printf '%s' "$ver" | cut -d. -f2)"
  if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 25 )); then
    warn "crictl ${ver:-未知版本} 与 kubelet 1.20 的 dockershim 不兼容（它只说 CRI v1，dockershim 只支持 v1alpha2）"
    warn "  现象： crictl ps / crictl info 报 'CRI v1 runtime API is not implemented'"
    install_compatible_crictl "$minor"
  else
    debug "crictl ${ver:-未安装} 与 dockershim 兼容"
  fi
}

# 下载并安装与本集群兼容的 crictl（默认 v1.22.0，它对 dockershim 仍讲 v1alpha2）。
# 装到 /usr/local/bin/crictl，在 CentOS 7 上 /usr/local/bin 先于 /usr/bin 出现在 PATH，
# 因此会覆盖系统里那个过新的版本；原文件不动，随时可回退。
install_compatible_crictl() {
  local cur_minor=$1 want="${CRICTL_VERSION_COMPAT:-v1.22.0}"
  if [[ "$CRICTL_DOWNLOAD" != 1 ]]; then
    warn "  已按 --no-crictl-download 跳过自动安装。手工修复："
    warn "    curl -L -o /tmp/crictl.tgz https://github.com/kubernetes-sigs/cri-tools/releases/download/${want}/crictl-${want}-linux-amd64.tar.gz"
    warn "    tar -xzf /tmp/crictl.tgz -C /usr/local/bin && rm -f /tmp/crictl.tgz"
    return 0
  fi
  # 已经装过一次兼容版本就不再重复下载
  if [[ -x /usr/local/bin/crictl ]]; then
    local have
    have="$(/usr/local/bin/crictl --version 2>/dev/null | awk '{print $NF}')"
    have="${have#v}"
    if [[ "$(printf '%s' "$have" | cut -d. -f2)" =~ ^[0-9]+$ ]] && \
       (( $(printf '%s' "$have" | cut -d. -f2) < 25 )); then
      ok "/usr/local/bin/crictl 已是兼容版本 $have（当前 PATH 中的可能不是它，检查 PATH 顺序）"
      return 0
    fi
  fi

  local url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${want}/crictl-${want}-linux-amd64.tar.gz"
  local tmpd; tmpd="$(mktemp -d)" || { warn "mktemp 失败，跳过 crictl 安装"; return 0; }
  info "下载兼容版 crictl ${want}（当前版本次版本号 $cur_minor 过新）"
  debug "URL: $url"
  if ! command -v curl >/dev/null 2>&1; then
    warn "  缺少 curl，无法自动下载。请手工执行上面的命令"
    rm -rf "$tmpd"; return 0
  fi
  if ! curl -fsSL --connect-timeout 15 --max-time 180 -o "$tmpd/crictl.tgz" "$url"; then
    warn "  下载失败（GitHub 不可达？）。可用 docker ps 代替，或手工按上面命令安装"
    rm -rf "$tmpd"; return 0
  fi
  if tar -xzf "$tmpd/crictl.tgz" -C "$tmpd" 2>/dev/null && [[ -f "$tmpd/crictl" ]]; then
    if install -m 0755 "$tmpd/crictl" /usr/local/bin/crictl 2>/dev/null; then
      local got; got="$(/usr/local/bin/crictl --version 2>/dev/null | awk '{print $NF}')"
      ok "已安装兼容版 crictl： /usr/local/bin/crictl（${got:-$want}）"
      info "若 crictl 仍报错，说明 PATH 里 /usr/bin 优先： hash -r && type -a crictl"
    else
      warn "  安装到 /usr/local/bin/crictl 失败（权限？）"
    fi
  else
    warn "  解压失败，包可能损坏"
  fi
  rm -rf "$tmpd"
}

# ----------------------------- 4. master 初始化 -------------------------------
# 用 kubeadm Config 文件，让 kube-proxy 真正跑 ipvs、cgroupDriver 与 kubelet 保持一致。
build_kubeadm_config() {   # $1 = apiserver 通告地址
  local ip=$1 f=/etc/kubernetes/kubeadm-init.yaml
  # 只有显式指定 CRI socket 时才写 criSocket；留空则用 nodeRegistration: {}，
  # 让 kubeadm 走默认运行时探测（首次 init 推荐，可避开 preflight 拨不存在的 socket）
  local node_reg="nodeRegistration: {}"
  [[ -n "$CRI_SOCKET" ]] && node_reg="nodeRegistration:
  criSocket: ${CRI_SOCKET}"
  run mkdir -p /etc/kubernetes
  write_file "$f" <<CFGEOF
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ip}
${node_reg}
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
imageRepository: ${IMAGE_REPOSITORY}
controlPlaneEndpoint: "${ip}:6443"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
CFGEOF
  ok "kubeadm 配置： $f（kube-proxy=ipvs, cgroup=systemd, controlPlaneEndpoint=${ip}:6443）"
}

setup_kubeconfig() {
  [[ -f /etc/kubernetes/admin.conf ]] || die "尚未 kubeadm init： /etc/kubernetes/admin.conf 不存在"
  run mkdir -p "$HOME/.kube"
  run cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
  run chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  run chmod 600 "$HOME/.kube/config"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  # 补全改由 install_shell_completion 统一处理（/etc/profile.d 系统级），
  # 这里只保证 KUBECONFIG 生效，避免在 ~/.bashrc 里塞重复的 source 行。
  local rc="$HOME/.bashrc" line='export KUBECONFIG=/etc/kubernetes/admin.conf'
  grep -qxF "$line" "$rc" 2>/dev/null || run bash -c "printf '%s\n' '$line' >>'$rc'"
  ok "kubectl 可用（KUBECONFIG 已写入 ~/.bashrc）"
}

# kubectl / kubeadm 命令补全。
# 做成系统级 /etc/profile.d：root 与普通用户、master 与 worker 登录后都有补全；
# 仅写 ~/.bashrc 的话只有当前用户生效，且 worker 节点享受不到。
install_shell_completion() {
  [[ "$INSTALL_COMPLETION" == 1 ]] || { info "已按 --no-completion 跳过命令补全"; return 0; }
  # 即使 kubectl/kubeadm 还没装，也必须把 profile.d 与 $SYS_CMD_NAME 自身补全装上：
  # profile.d 正文里 kubectl/kubeadm 两段自带 command -v 守卫，写进去是安全的，
  # 等它们装好后下次登录自然生效。早前版本在这里直接 return，导致
  # 「先跑脚本装 k8s、再登录」的场景里 kubesetup 的 TAB 补全永远缺失。
  # bash-completion 框架主文件位置因发行版而异：Debian 系是 /etc/bash_completion，
  # CentOS/RHEL 7+ 只有 /usr/share/bash-completion/bash_completion。
  # （之前只判断 /etc/bash_completion，在 CentOS 7 上即使装了 bash-completion 也会误报缺失）
  local bc_main="" p
  for p in /etc/bash_completion /usr/share/bash-completion/bash_completion; do
    [[ -f "$p" ]] && { bc_main=$p; break; }
  done
  if ! command -v kubectl >/dev/null 2>&1 && ! command -v kubeadm >/dev/null 2>&1; then
    info "kubectl/kubeadm 尚未安装：仍会安装 $SYS_CMD_NAME 的补全；它们的补全待安装后再执行一次 completion"
  elif [[ -z "$bc_main" ]]; then
    yum_install_opt "$BASH_COMPLETION_PKG"
    for p in /etc/bash_completion /usr/share/bash-completion/bash_completion; do
      [[ -f "$p" ]] && { bc_main=$p; break; }
    done
    [[ -n "$bc_main" ]] || warn "未找到 bash-completion 框架，kubectl/kubeadm 补全可能不完整（yum install -y $BASH_COMPLETION_PKG）"
  fi

  # body 用可扩展 heredoc：其中 \$_bc 已转义，避免生成时被展开；
  # 两处路径直接取变量，保证 CMD_COMPLETION_FILE / COMPLETION_PROFILE 被覆盖时加载关系依然自洽
  local f="$COMPLETION_PROFILE" body="
# 由 $(basename "$SELF_PATH") 生成：kubectl / kubeadm / $SYS_CMD_NAME 命令补全
# 先加载 bash-completion 框架（CentOS 7 在 /usr/share/bash-completion 下）
for _bc in /etc/bash_completion /usr/share/bash-completion/bash_completion; do
    [ -f \"\$_bc\" ] && . \"\$_bc\" && break
done
if command -v kubectl >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source <(kubectl completion bash) 2>/dev/null || true
fi
if command -v kubeadm >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source <(kubeadm completion bash) 2>/dev/null || true
fi
# $SYS_CMD_NAME 补全：纯 bash 实现，即使没装 bash-completion 包也能用
[ -r '$CMD_COMPLETION_FILE' ] && . '$CMD_COMPLETION_FILE'
"
  # 想要 k 缩写 + 补全的用户，自行在 ~/.bashrc 追加：
  #   alias k=kubectl; complete -F __start_kubectl k
  info "安装命令补全： $f（kubectl + kubeadm + $SYS_CMD_NAME，系统级）"
  printf '%s\n' "$body" | write_file "$f" 0644
  # 已在的交互 shell 不会自动重读 profile.d，这里同时保证 root 的 ~/.bashrc 也 source 它
  local rc="$HOME/.bashrc" line=". $COMPLETION_PROFILE"
  grep -qxF "$line" "$rc" 2>/dev/null || run bash -c "printf '%s\n' '$line' >>'$rc'"
  # 本命令自己的补全放独立文件：卸载只删一个文件，不会破坏上面的共享脚本
  install_self_completion
  ok "补全已安装；当前会话立即生效： source $f  （或重新登录）"
}

# $SYS_CMD_NAME 的子命令/选项补全 -> /etc/bash_completion.d/<命令名>。
# 两个设计点：
#  1) 纯 bash（只用 COMP_WORDS/COMPREPLY），不依赖 _init_completion，
#     因此即使系统没装 bash-completion 包，靠 profile.d 加载也能补全；
#  2) 子命令与选项在写入时从本脚本的 SUBCOMMANDS / CMD_OPTIONS 展开，
#     补全清单与实际支持范围同源，不会漂移。
install_self_completion() {
  local words="" opts="" s
  for s in "${SUBCOMMANDS[@]}"; do words+=" $s"; done
  for s in "${CMD_OPTIONS[@]}"; do opts+=" $s"; done
  words="${words# }"; opts="${opts# }"
  info "安装 $SYS_CMD_NAME 命令补全： $CMD_COMPLETION_FILE"
  run mkdir -p "$(dirname "$CMD_COMPLETION_FILE")"
  {
    printf '# 由 %s 自动生成，请勿手工编辑（重跑任意子命令会覆盖）\n' "$SYS_CMD_NAME"
    printf '# 纯 bash 实现，无需 bash-completion 包\n'
    printf '_%s_completion() {\n' "$SYS_CMD_NAME"
    printf '    local cur prev cword=%s\n' '${COMP_CWORD}'
    printf '    local subcommands="%s"\n' "$words"
    printf '    local options="%s"\n' "$opts"
    printf '    # 需要带值的选项：其取值位置交给默认（文件）补全\n'
    printf '    local valueopts="--k8s-version --service-cidr --pod-cidr --apiserver-ip --image-repository"\n'
    printf '    valueopts="$valueopts --cri-socket --node-name --ssh-user --inventory --manifest --log-file --token-ttl --drain-node --backup-dir --backup-keep --ingress-manifest"\n'
    printf '    COMPREPLY=()\n'
    printf '    cur="${COMP_WORDS[cword]}"\n'
    printf '    prev="${COMP_WORDS[cword-1]:-}"\n'
    printf '    # 需要取值的选项，其取值位置交给默认（文件）补全\n'
    printf '    case " $valueopts " in *" $prev "*) return 0 ;; esac\n'
    printf '    # 已经输入过子命令 -> 只补选项；否则补 子命令 + 选项\n'
    printf '    local i seen_sub=""\n'
    printf '    for ((i = 1; i < cword; i++)); do\n'
    printf '        case " $subcommands " in *" ${COMP_WORDS[i]} "*) seen_sub=1; break ;; esac\n'
    printf '    done\n'
    printf '    if [[ -n "$seen_sub" ]]; then\n'
    printf '        COMPREPLY=( $(compgen -W "$options" -- "$cur") )\n'
    printf '    else\n'
    printf '        COMPREPLY=( $(compgen -W "$subcommands $options" -- "$cur") )\n'
    printf '    fi\n'
    printf '    return 0\n'
    printf '}\n'
    printf 'complete -F _%s_completion %s 2>/dev/null || true\n' "$SYS_CMD_NAME" "$SYS_CMD_NAME"
  } | write_file "$CMD_COMPLETION_FILE" 0644
}

# 把“正在运行的这份脚本自身”安装为系统命令 /usr/bin/kubesetup。
# 关键前提：本脚本完全自包含（yum repo 正文、flannel 清单都是内联 heredoc，
# 配置读 /etc/k8s-install.conf），所以复制出去就是独立可用的副本，
# 删掉源脚本不影响 kubesetup。
install_system_command() {
  local force=${1:-} target="${SYS_CMD_DIR}/${SYS_CMD_NAME}" src=$SELF_PATH
  [[ "$INSTALL_SYS_CMD" == 1 || "$force" == force ]] || { debug "已按 --no-install-cmd 跳过安装 $target"; return 0; }

  # dry-run 只描述计划，连 root 检查都不必失败（便于普通用户预演）
  [[ "$DRY_RUN" == 1 ]] && { dry "install -m 0755 $src $target"; dry "写补全 $CMD_COMPLETION_FILE"; return 0; }

  # 非 root：自动路径静默跳过（普通用户跑 kubesetup status 不该每次被警告）；
  # 显式 install 子命令则明确报错退出
  if ! is_root; then
    [[ "$force" == force ]] && die "安装 $target 需要 root： sudo $(self_invocation) install"
    debug "非 root，跳过自动安装 $target（需要时： sudo $(self_invocation) install）"
    return 0
  fi
  # 自己就是目标文件时跳过，避免 cp/mv 覆盖正在被 bash 逐块读取的自身脚本
  if [[ -e "$target" ]] && [[ "$(readlink -f "$src")" == "$(readlink -f "$target")" ]]; then
    debug "当前就是以 $target 运行，无需自我覆盖"
    return 0
  fi

  # 先写同目录临时文件再 mv：同文件系统内 mv 是原子的，且新文件的 SELinux 标签
  # 由 /usr/bin 的默认 filecon(bin_t) 决定，不会带上家目录标签导致无法执行
  local tmp="${target}.new.$$"
  if ! cp -p "$src" "$tmp" 2>>"$LOG_FILE"; then
    rm -f "$tmp"; warn "复制失败（$SYS_CMD_DIR 不可写？），跳过命令安装"
    return 0
  fi
  if ! chmod 0755 "$tmp" 2>>"$LOG_FILE" || ! mv -f "$tmp" "$target" 2>>"$LOG_FILE"; then
    rm -f "$tmp"; warn "安装 $target 失败，已回滚"
    return 0
  fi
  hash -r 2>/dev/null || true                 # 清掉本 shell 的命令路径缓存
  # 命令补全独立安装：即使 kubectl/kubeadm 还没装（install_shell_completion 会提前返回），
  # kubesetup 自身的 TAB 补全也要保证存在
  [[ -f "$CMD_COMPLETION_FILE" ]] || install_self_completion
  ok "系统命令已安装： $target（子命令与源脚本一致，含 TAB 补全）"
  info "源脚本可以删除；后续直接用： $SYS_CMD_NAME status / $SYS_CMD_NAME token / $SYS_CMD_NAME -h"
}

uninstall_system_command() {
  local target="${SYS_CMD_DIR}/${SYS_CMD_NAME}"
  need_root
  [[ "$DRY_RUN" == 1 ]] && { dry "rm -f $target $CMD_COMPLETION_FILE"; return 0; }
  if [[ -e "$target" ]]; then
    rm -f "$target" && ok "已删除命令 $target"
  else
    info "$target 不存在，无需卸载"
  fi
  # 补全只占一个独立文件，整体删除即可；共享的 kubectl/kubeadm 补全保持不动
  if [[ -f "$CMD_COMPLETION_FILE" ]]; then
    rm -f "$CMD_COMPLETION_FILE" && ok "已删除补全 $CMD_COMPLETION_FILE"
  fi
  hash -r 2>/dev/null || true
  warn "仅移除 $SYS_CMD_NAME 命令与其补全，已部署的集群、/etc/k8s-install.conf 均不受影响"
}

# 生成（或复用）join 命令，并按 TOKEN_TTL 控制有效期。
# kubeadm 语义：--ttl 默认 24h；--ttl 0 = 永不过期（学习环境方便，见头部说明）。
get_join_command() {   # $1 = new|reuse；stdout 只输出 join 命令本身（日志一律走 stderr）
  local policy=${1:-reuse} ttl_arg=(--ttl "${TOKEN_TTL:-24h}")
  if [[ "$policy" == "reuse" && -s "$JOIN_FILE" ]] && grep -q 'kubeadm join' "$JOIN_FILE"; then
    info "复用已保存的 join 命令： $JOIN_FILE（如需换新 token 请用 token 子命令）"
    cat "$JOIN_FILE"; return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "kubeadm token create ${ttl_arg[*]} --print-join-command >$JOIN_FILE"
    cat "$JOIN_FILE" 2>/dev/null || echo "kubeadm join <apiserver>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
    return 0
  fi
  local out
  if ! out="$(kubeadm token create "${ttl_arg[@]}" --print-join-command 2>>"$LOG_FILE")"; then
    die "生成 join 命令失败（kubeadm token create ${ttl_arg[*]}），详见 $LOG_FILE"
  fi
  printf '%s\n' "$out" >"$JOIN_FILE"
  chmod 600 "$JOIN_FILE"
  case "$TOKEN_TTL" in
    0|0s|never) warn "token 永不过期（--token-ttl 0）：学习环境可用；公网/生产请在加完节点后 kubeadm token delete 掉" ;;
    *)          info "token 有效期： $TOKEN_TTL" ;;
  esac
  verify_token_expiry
  printf '%s\n' "$out"
}

# 用 kubeadm token list 复核刚生成的 token 是否真按预期过期（列表里对应行 EXPIRES 列）
verify_token_expiry() {
  command -v kubeadm >/dev/null 2>&1 || return 0
  local tok line
  tok="$(sed -n 's/.*--token \([^ ]*\).*/\1/p' "$JOIN_FILE" 2>/dev/null | head -n1)"
  [[ -n "$tok" ]] || return 0
  line="$(kubeadm token list 2>/dev/null | grep -F "${tok%%.*}" || true)"
  if [[ -z "$line" ]]; then debug "token list 中未匹配到 ${tok%%.*}，跳过复核"; return 0; fi
  case "$TOKEN_TTL" in
    0|0s|never)
      if grep -qiE 'never' <<<"$line"; then ok "已确认： token 永不过期（EXPIRES=never）"
      else warn "token 未显示为永不过期，实际： $line"; fi ;;
    *)
      info "token 过期信息： $line" ;;
  esac
}

token_cmd() {   # 子命令入口：单独造 token（学习时反复加删 worker 很常用）
  need_root
  setup_kubeconfig
  local cmd; cmd="$(get_join_command new)"
  ok "join 命令： $cmd"
  info "已写入 $JOIN_FILE"
  info "查看现存 token： kubeadm token list   删除： kubeadm token delete <token-id>"
}

# 控制面 insecure 端口（scheduler 10251 / controller-manager 10252）开关。
#
# 背景：kubeadm 1.19+ 在这两个静态 Pod 里默认带 `--port=0`，即**关闭**明文健康端口，
# 这是安全默认。副作用是 `kubectl get cs`（ComponentStatus，已废弃）读到的是该端口，
# 于是显示 controller-manager / scheduler Unhealthy —— 组件本身其实是好的，
# 用 `kubectl get --raw='/readyz?verbose'` 才能看到真实健康状态。
#
# 学习环境想让 `get cs` 全绿时用 `kubesetup ports --on`；生产请保持 off。
CONTROL_MANIFESTS=(/etc/kubernetes/manifests/kube-scheduler.yaml
                   /etc/kubernetes/manifests/kube-controller-manager.yaml)

insecure_ports_enabled() {   # 返回 0 表示两个 manifest 里 --port=0 都已被注释（insecure 开着）
  local f
  for f in "${CONTROL_MANIFESTS[@]}"; do
    [[ -f "$f" ]] || return 1
    grep -qE '^[[:space:]]*- --port=0' "$f" && return 1
  done
  return 0
}

apply_port_mode() {   # $1 = on|off
  local mode=$1 f changed=0
  if [[ "$DRY_RUN" != 1 ]] && ! is_root; then
    die "需要 root： sudo $(self_invocation) ports --$mode"
  fi
  for f in "${CONTROL_MANIFESTS[@]}"; do
    [[ -f "$f" ]] || { warn "未找到 $f"; continue; }
    if [[ "$mode" == on ]]; then
      grep -qE '^[[:space:]]*- --port=0' "$f" || { debug "$(basename "$f") 已是开启状态"; continue; }
      backup_path "$f"
      run sed -i 's|^\([[:space:]]*\)- --port=0|\1#- --port=0|' "$f"
      ok "$(basename "$f")：已注释 --port=0（insecure 端口开启）"
    else
      grep -qE '^[[:space:]]*#- --port=0' "$f" || { debug "$(basename "$f") 已是关闭状态"; continue; }
      backup_path "$f"
      run sed -i 's|^\([[:space:]]*\)#- --port=0|\1- --port=0|' "$f"
      ok "$(basename "$f")：已恢复 --port=0（安全默认）"
    fi
    changed=1
  done
  (( changed )) || { info "无需改动（当前已经是 $( [[ "$mode" == on ]] && echo "开启" || echo "关闭" ) 状态）"; return 0; }
  if [[ "$mode" == on ]]; then
    warn "10251/10252 明文端口对集群内任意 Pod 开放，仅限实验环境；生产请执行 $(self_invocation) ports --off"
  fi
  [[ "$DRY_RUN" == 1 ]] && return 0
  info "等待静态 Pod 重建（约 20 秒）"
  sleep 20
  wait_for "控制面 readyz 通过" 180 kubectl get --raw='/readyz?verbose'
  if kubectl get --raw='/readyz' >/dev/null 2>&1; then
    # 注意：不能用 `[[ ... ]] && ok ...` 作为分支最后一句——mode=off 时它会返回 1
    # 并让整个函数返回非 0，从而触发 ERR trap（实测踩过）。
    if [[ "$mode" == on ]]; then
      ok "现在 kubectl get cs 应全部 Healthy（组件本身一直都是好的）"
    fi
  else
    warn "readyz 仍未通过，检查： kubectl -n kube-system get pods"
  fi
}

ports_cmd() {   # kubesetup ports [--on|--off]
  case "$PORTS_MODE" in
    on)  need_root; apply_port_mode on ;;
    off) need_root; apply_port_mode off ;;
    *)
      if insecure_ports_enabled; then
        ok "insecure 端口：已开启（get cs 会显示 Healthy，但不安全）"
      else
        info "insecure 端口：已关闭（安全默认；此时 kubectl get cs 显示 Unhealthy 属正常）"
        info "想让它全绿： sudo $(self_invocation) ports --on"
      fi
      ;;
  esac
}

# init 阶段：--insecure-ports 时自动切到 on（保持原有行为）
relax_insecure_ports() {
  [[ "$ALLOW_INSECURE_PORTS" == 1 ]] || return 0
  apply_port_mode on
}

# init 前的 CRI 处理。
#
# 重要事实（实测日志证实）：首次 init 之前，kubelet **不可能**提供 dockershim.sock。
# kubelet 启动时要读 /var/lib/kubelet/config.yaml，而该文件正是 kubeadm init 的
# kubelet-start 阶段才写入的；缺它 kubelet 直接 klog.Fatal 退出：
#   F1108 server.go:198] failed to load Kubelet config file /var/lib/kubelet/config.yaml:
#       open /var/lib/kubelet/config.yaml: no such file or directory
# 所以这里**不能**等 socket（会必然超时）。正确做法：
#   1) 确保容器运行时（docker/containerd）在跑；
#   2) socket 暂缺时，仅放宽 preflight 的 CRI 一项，让 kubeadm 走到 kubelet-start
#      写入配置并启动 kubelet——真正的 CRI 校验在随后拉镜像时自然发生。
# init/join 失败时自动附上 kubelet 的失败原因，省去手工翻 journal。
# 用 -o cat 去掉 "Nov 08 15:48:20 host unit[pid]:" 前缀，否则 grep '^F'/'^panic' 会永远匹配不到。
dump_kubelet_log() {
  command -v journalctl >/dev/null 2>&1 || return 0
  err "kubelet 状态： $(systemctl is-active kubelet 2>/dev/null || echo 未运行)"
  err "kubelet 最近日志（-o cat，去掉前缀；首个 F/E 行即原因）："
  journalctl -u kubelet -n 30 --no-pager -o cat 2>/dev/null | sed 's/^/      /' >&2 || true
}

prepare_cri_for_init() {
  INIT_EXTRA_ARGS=()
  # 清掉历史失败计数：init 前 kubelet 必然失败过几次，systemd 可能已触发
  # StartLimitBurst（"start request repeated too quickly"），导致 kubelet-start
  # 阶段真正启动时被拒绝。reset-failed 是幂等的，没有失败也不报错。
  quiet systemctl reset-failed kubelet || true

  # 未指定 CRI socket（默认）：让 kubeadm 自己探测。只确保 Docker 在跑即可，
  # 不检查 socket、也不放宽任何 preflight——kubeadm 会先写 kubelet 配置再启动它。
  if [[ -z "$CRI_SOCKET" ]]; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      ok "Docker 运行中；CRI 由 kubeadm 自动探测"
    else
      warn "Docker 未运行，尝试启动"
      quiet systemctl enable --now docker || true
      systemctl is-active --quiet docker 2>/dev/null || \
        die "Docker 未运行，无法继续。请先： systemctl enable --now docker && systemctl status docker"
    fi
    return 0
  fi

  # 显式指定了 CRI socket：确认对应运行时在跑；socket 暂缺时仅放宽 preflight 的 CRI 一项
  local sock="${CRI_SOCKET#unix://}"
  case "$CRI_SOCKET" in
    *dockershim.sock)
      systemctl is-active --quiet docker 2>/dev/null || {
        warn "Docker 未运行，尝试启动"; quiet systemctl enable --now docker || true; }
      systemctl is-active --quiet docker 2>/dev/null || \
        die "Docker 未运行，dockershim 无法工作。请先： systemctl enable --now docker && systemctl status docker"
      ;;
    *containerd.sock)
      systemctl is-active --quiet containerd 2>/dev/null || \
        quiet systemctl enable --now containerd || true
      ;;
  esac
  if [[ ! -S "$sock" ]]; then
    info "首次 init 前 $sock 尚不存在属正常（kubelet 需等 kubeadm 写入 /var/lib/kubelet/config.yaml）"
    info "本次将仅放宽 preflight 的 CRI 检查，其余检查保持启用"
    INIT_EXTRA_ARGS+=(--ignore-preflight-errors=CRI)
  else
    ok "CRI socket 已就绪： $sock"
  fi
}

master_init() {
  need_root
  # 先做纯配置校验，避免在参数明显错误时才因探测不到 IP 而报出无关错误
  require_cidr_match
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    [[ "$FORCE" == 1 ]] || die "本机已初始化过集群。只补 CNI/worker 请用 cni、scale；要重建请加 --force"
    confirm "--force：将 reset 现有 master 并重建，确认？"
    local keep_yes=$ASSUME_YES; ASSUME_YES=1; reset_local; ASSUME_YES=$keep_yes
  fi

  local ip="${API_ADVERTISE_ADDRESS:-}"
  [[ -n "$ip" ]] || ip="$(detect_ip_or_die)"
  valid_ipv4 "$ip" || die "apiserver 地址非法： $ip"
  info "apiserver-advertise-address=$ip  kubernetes-version=v${K8S_VERSION}  cri=${CRI_SOCKET:-自动}"

  build_kubeadm_config "$ip"

  # 运行时服务就位 + 决定是否放宽 preflight 的 CRI 一项（首次 init 前 socket 必缺，属正常）
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "检查容器运行时（docker/containerd 是否在跑）"
  else
    prepare_cri_for_init
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    dry "kubeadm init --config=/etc/kubernetes/kubeadm-init.yaml --upload-certs ${INIT_EXTRA_ARGS[*]:-}"
    return 0
  fi

  info "kubeadm init 开始（通常 2-5 分钟，过程写入 $LOG_FILE）"
  if ! kubeadm init --config=/etc/kubernetes/kubeadm-init.yaml --upload-certs \
         ${INIT_EXTRA_ARGS[@]+"${INIT_EXTRA_ARGS[@]}"} >>"$LOG_FILE" 2>&1; then
    tail -n 40 "$LOG_FILE" >&2 || true
    dump_kubelet_log
    die "kubeadm init 失败。已附上 kubelet 日志；修复后 kubeadm reset -f 再重试"
  fi
  ok "kubeadm init 完成"

  setup_kubeconfig
  relax_insecure_ports
  wait_for "控制面 readyz 通过" 240 kubectl get --raw='/readyz?verbose'

  info "生成 worker join 命令"
  # 原脚本 `kubeadm tocken create --ttl 0`：tocken 拼写错误导致命令不存在。
  # 语义本身有效（kubeadm：--ttl 0 = 永不过期），这里通过 --token-ttl 显式控制。
  local cmd; cmd="$(get_join_command new)"
  ok "join 命令（$JOIN_FILE）： $cmd"
}

# ----------------------------- 5. CNI（flannel）-------------------------------
apply_cni() {
  need_root
  [[ -f "$FLANNEL_MANIFEST" ]] || write_flannel_manifest
  # 清单落盘后再校验一次网段一致性（清单是 Network 的唯一事实来源）
  FLANNEL_NETWORK="$(flannel_network_from_manifest "$FLANNEL_MANIFEST")"
  require_cidr_match
  grep -q $'\r' "$FLANNEL_MANIFEST" 2>/dev/null && warn "清单含 CRLF，kubectl 可能解析失败（先 dos2unix）"

  if [[ "$DRY_RUN" == 1 ]]; then
    dry "kubectl apply -f $FLANNEL_MANIFEST"
    return 0
  fi
  setup_kubeconfig

  info "kubectl apply -f $FLANNEL_MANIFEST"
  kubectl apply -f "$FLANNEL_MANIFEST" || die "flannel 下发失败"
  # CNI 就绪后 kubelet 才能完成节点注册，这里等待 Ready（替代原脚本的死循环）
  wait_for "flannel Pod 就绪" "$WAIT_TIMEOUT" \
    bash -c "kubectl -n kube-flannel get pods --no-headers 2>/dev/null | grep -qE '1/1[[:space:]]+Running'"
  wait_for "全部节点 Ready" "$WAIT_TIMEOUT" \
    bash -c "! kubectl get nodes --no-headers 2>/dev/null | grep -q 'NotReady'"
  kubectl get nodes -o wide >&2 || true
}

# ----------------------------- 6.1b ingress-nginx 清单落盘 ---------------------
# 清单正文与交付的 kube-ingress.yaml 逐字节一致（含阿里云镜像、NodePort Service），
# 不做任何改写；需要换镜像/端口请改源文件后重新生成脚本。
write_ingress_manifest() {
  info "生成 ingress 清单： $INGRESS_MANIFEST"
  [[ -f "$INGRESS_MANIFEST" ]] && backup_path "$INGRESS_MANIFEST"
  write_file "$INGRESS_MANIFEST" <<'EOF'

apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx

---
# Source: ingress-nginx/templates/controller-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx
  namespace: ingress-nginx
automountServiceAccountToken: true
---
# Source: ingress-nginx/templates/controller-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
---
# Source: ingress-nginx/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
  name: ingress-nginx
rules:
  - apiGroups:
      - ''
    resources:
      - configmaps
      - endpoints
      - nodes
      - pods
      - secrets
    verbs:
      - list
      - watch
  - apiGroups:
      - ''
    resources:
      - nodes
    verbs:
      - get
  - apiGroups:
      - ''
    resources:
      - services
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ''
    resources:
      - events
    verbs:
      - create
      - patch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingressclasses
    verbs:
      - get
      - list
      - watch
---
# Source: ingress-nginx/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
  name: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ingress-nginx
    namespace: ingress-nginx
---
# Source: ingress-nginx/templates/controller-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx
  namespace: ingress-nginx
rules:
  - apiGroups:
      - ''
    resources:
      - namespaces
    verbs:
      - get
  - apiGroups:
      - ''
    resources:
      - configmaps
      - pods
      - secrets
      - endpoints
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ''
    resources:
      - services
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ''
    resources:
      - configmaps
    resourceNames:
      - ingress-controller-leader
    verbs:
      - get
      - update
  - apiGroups:
      - ''
    resources:
      - configmaps
    verbs:
      - create
  - apiGroups:
      - ''
    resources:
      - events
    verbs:
      - create
      - patch
---
# Source: ingress-nginx/templates/controller-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ingress-nginx
    namespace: ingress-nginx
---
# Source: ingress-nginx/templates/controller-service-webhook.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx-controller-admission
  namespace: ingress-nginx
spec:
  type: ClusterIP
  ports:
    - name: https-webhook
      port: 443
      targetPort: webhook
      appProtocol: https
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
---
# Source: ingress-nginx/templates/controller-service.yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: http
      appProtocol: http
    - name: https
      port: 443
      protocol: TCP
      targetPort: https
      appProtocol: https
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
---
# Source: ingress-nginx/templates/controller-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      app.kubernetes.io/instance: ingress-nginx
      app.kubernetes.io/component: controller
  revisionHistoryLimit: 10
  minReadySeconds: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/component: controller
    spec:
      dnsPolicy: ClusterFirst
      containers:
        - name: controller
          #image: k8s.gcr.io/ingress-nginx/controller:v1.0.0@sha256:0851b34f69f69352bf168e6ccf30e1e20714a264ab1ecd1933e4d8c0fc3215c6
          image: registry.cn-beijing.aliyuncs.com/jack_web_images/ops:controller-v1.0.0
          imagePullPolicy: IfNotPresent
          lifecycle:
            preStop:
              exec:
                command:
                  - /wait-shutdown
          args:
            - /nginx-ingress-controller
            - --election-id=ingress-controller-leader
            - --controller-class=k8s.io/ingress-nginx
            - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
            - --validating-webhook=:8443
            - --validating-webhook-certificate=/usr/local/certificates/cert
            - --validating-webhook-key=/usr/local/certificates/key
          securityContext:
            capabilities:
              drop:
                - ALL
              add:
                - NET_BIND_SERVICE
            runAsUser: 101
            allowPrivilegeEscalation: true
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: LD_PRELOAD
              value: /usr/local/lib/libmimalloc.so
          livenessProbe:
            failureThreshold: 5
            httpGet:
              path: /healthz
              port: 10254
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 10
            successThreshold: 1
            timeoutSeconds: 1
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /healthz
              port: 10254
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 10
            successThreshold: 1
            timeoutSeconds: 1
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
            - name: https
              containerPort: 443
              protocol: TCP
            - name: webhook
              containerPort: 8443
              protocol: TCP
          volumeMounts:
            - name: webhook-cert
              mountPath: /usr/local/certificates/
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 90Mi
      nodeSelector:
        kubernetes.io/os: linux
      serviceAccountName: ingress-nginx
      terminationGracePeriodSeconds: 300
      volumes:
        - name: webhook-cert
          secret:
            secretName: ingress-nginx-admission
---
# Source: ingress-nginx/templates/controller-ingressclass.yaml
# We don't support namespaced ingressClass yet
# So a ClusterRole and a ClusterRoleBinding is required
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: controller
  name: nginx
  namespace: ingress-nginx
spec:
  controller: k8s.io/ingress-nginx
---
# Source: ingress-nginx/templates/admission-webhooks/validating-webhook.yaml
# before changing this value, check the required kubernetes version
# https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#prerequisites
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
  name: ingress-nginx-admission
webhooks:
  - name: validate.nginx.ingress.kubernetes.io
    matchPolicy: Equivalent
    rules:
      - apiGroups:
          - networking.k8s.io
        apiVersions:
          - v1
        operations:
          - CREATE
          - UPDATE
        resources:
          - ingresses
    failurePolicy: Fail
    sideEffects: None
    admissionReviewVersions:
      - v1
    clientConfig:
      service:
        namespace: ingress-nginx
        name: ingress-nginx-controller-admission
        path: /networking/v1/ingresses
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingress-nginx-admission
  namespace: ingress-nginx
  annotations:
    helm.sh/hook: pre-install,pre-upgrade,post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ingress-nginx-admission
  annotations:
    helm.sh/hook: pre-install,pre-upgrade,post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
rules:
  - apiGroups:
      - admissionregistration.k8s.io
    resources:
      - validatingwebhookconfigurations
    verbs:
      - get
      - update
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ingress-nginx-admission
  annotations:
    helm.sh/hook: pre-install,pre-upgrade,post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx-admission
subjects:
  - kind: ServiceAccount
    name: ingress-nginx-admission
    namespace: ingress-nginx
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingress-nginx-admission
  namespace: ingress-nginx
  annotations:
    helm.sh/hook: pre-install,pre-upgrade,post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
rules:
  - apiGroups:
      - ''
    resources:
      - secrets
    verbs:
      - get
      - create
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ingress-nginx-admission
  namespace: ingress-nginx
  annotations:
    helm.sh/hook: pre-install,pre-upgrade,post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx-admission
subjects:
  - kind: ServiceAccount
    name: ingress-nginx-admission
    namespace: ingress-nginx
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/job-createSecret.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ingress-nginx-admission-create
  namespace: ingress-nginx
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
spec:
  template:
    metadata:
      name: ingress-nginx-admission-create
      labels:
        helm.sh/chart: ingress-nginx-4.0.1
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/version: 1.0.0
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/component: admission-webhook
    spec:
      containers:
        - name: create
          #image: k8s.gcr.io/ingress-nginx/kube-webhook-certgen:v1.0@sha256:f3b6b39a6062328c095337b4cadcefd1612348fdd5190b1dcbcb9b9e90bd8068
          image: registry.cn-beijing.aliyuncs.com/jack_web_images/ops:kube-webhook-certgen-v1.0
          imagePullPolicy: IfNotPresent
          args:
            - create
            - --host=ingress-nginx-controller-admission,ingress-nginx-controller-admission.$(POD_NAMESPACE).svc
            - --namespace=$(POD_NAMESPACE)
            - --secret-name=ingress-nginx-admission
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      restartPolicy: OnFailure
      serviceAccountName: ingress-nginx-admission
      nodeSelector:
        kubernetes.io/os: linux
      securityContext:
        runAsNonRoot: true
        runAsUser: 2000
---
# Source: ingress-nginx/templates/admission-webhooks/job-patch/job-patchWebhook.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ingress-nginx-admission-patch
  namespace: ingress-nginx
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    helm.sh/chart: ingress-nginx-4.0.1
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/version: 1.0.0
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: admission-webhook
spec:
  template:
    metadata:
      name: ingress-nginx-admission-patch
      labels:
        helm.sh/chart: ingress-nginx-4.0.1
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/version: 1.0.0
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/component: admission-webhook
    spec:
      containers:
        - name: patch
          #image: k8s.gcr.io/ingress-nginx/kube-webhook-certgen:v1.0@sha256:f3b6b39a6062328c095337b4cadcefd1612348fdd5190b1dcbcb9b9e90bd8068
          image: registry.cn-beijing.aliyuncs.com/jack_web_images/ops:kube-webhook-certgen-v1.0
          imagePullPolicy: IfNotPresent
          args:
            - patch
            - --webhook-name=ingress-nginx-admission
            - --namespace=$(POD_NAMESPACE)
            - --patch-mutating=false
            - --secret-name=ingress-nginx-admission
            - --patch-failure-policy=Fail
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      restartPolicy: OnFailure
      serviceAccountName: ingress-nginx-admission
      nodeSelector:
        kubernetes.io/os: linux
      securityContext:
        runAsNonRoot: true
        runAsUser: 2000
EOF
  ok "ingress 清单已写入： $INGRESS_MANIFEST"
}

# 判断是否还有可调度的 worker（控制面默认带 NoSchedule taint，单 master 时
# ingress controller 会一直 Pending，这是很多新手卡住的地方）。
has_schedulable_node() {
  local taints
  taints="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.taints[*].key}{"\n"}{end}' 2>/dev/null)" || return 1
  # 没有 taint 的节点，或 taint 里不含 master/control-plane，即视为可调度
  printf '%s\n' "$taints" | grep -vE '=(.*)(master|control-plane)' | grep -qv '^$'
}

apply_ingress() {
  need_root
  [[ -f "$INGRESS_MANIFEST" ]] || write_ingress_manifest
  grep -q $'\r' "$INGRESS_MANIFEST" 2>/dev/null && warn "清单含 CRLF，kubectl 可能解析失败（先 dos2unix）"

  if [[ "$DRY_RUN" == 1 ]]; then
    dry "kubectl apply -f $INGRESS_MANIFEST"
    dry "等待 ingress-nginx controller 与 admission Job 就绪"
    return 0
  fi
  setup_kubeconfig

  info "kubectl apply -f $INGRESS_MANIFEST"
  kubectl apply -f "$INGRESS_MANIFEST" || die "ingress 下发失败（详见 $LOG_FILE）"

  # 没有可调度节点时只应用、不空等：等 worker 加入后 Deployment 会自动落位
  if ! has_schedulable_node; then
    warn "当前没有可调度节点（控制面带 NoSchedule taint），ingress controller 会保持 Pending"
    warn "  单机学习环境可去掉 taint： kubectl taint nodes --all node-role.kubernetes.io/master-"
    warn "  或先加 worker： $(self_invocation) scale（加完会自动调度，无需重跑本命令）"
    kubectl -n ingress-nginx get pods -o wide >&2 || true
    return 0
  fi

  # controller 起来之前 admission webhook（failurePolicy=Fail）会挡住任何 Ingress 创建
  wait_for "ingress-nginx controller 就绪" "$WAIT_TIMEOUT" \
    bash -c "kubectl -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'"
  wait_for "admission 证书任务完成" 180 \
    bash -c "kubectl -n ingress-nginx get job ingress-nginx-admission-create -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q '^1'"
  kubectl -n ingress-nginx get pods -o wide >&2 || true

  local np
  np="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
  [[ -n "$np" ]] && ok "ingress 入口： http://<节点IP>:${np}"
  ok "ingress-nginx 就绪；IngressClass 已注册（kubectl get ingressclass）"
}

# ----------------------------- 6. worker 扩容（ansible）-----------------------
# 主机清单独立生成（不污染 /etc/ansible/hosts），worker 直接复用本脚本的
#       prepare 子命令，join 用 shell 模块执行落盘的 join 命令。
write_worker_inventory() {   # $@ = worker IP 列表
  local ip idx=1 extra="" interp
  (( $# >= 1 )) || die "worker IP 列表为空"
  {
    echo "# 由 $(basename "$SELF_PATH") 生成，请勿手工编辑"
    echo '[workers]'
    for ip in "$@"; do
      # 优先用 --ansible-python 指定值，否则用逐台探测结果（见 probe_remote_pythons）
      interp="${ANSIBLE_PYTHON_INTERPRETER:-${REMOTE_PY[$ip]:-}}"
      extra=""
      [[ -n "$interp" ]] && extra=" ansible_python_interpreter=${interp}"
      echo "${WORKER_HOST_PREFIX}${idx} ansible_host=${ip} ansible_user=${ANSIBLE_SSH_USER}${extra}"
      idx=$(( idx + 1 ))
    done
  } | write_file "$WORKER_INVENTORY"
  [[ "$DRY_RUN" == 1 ]] || chmod 600 "$WORKER_INVENTORY"
  ok "ansible 清单： $WORKER_INVENTORY（$# 台）"
}

# 把 worker 同步进 /etc/ansible/hosts 的「受管块」里，这样手工敲
# `ansible workers -m ping` 不写 -i 也能用。重跑会整体替换该块，幂等。
# 块外内容（系统自带注释/其它组）原样保留；不想要时用 --no-sync-hosts。
sync_ansible_hosts() {
  [[ "$SYNC_ANSIBLE_HOSTS" == 1 ]] || { debug "已按 --no-sync-hosts 跳过同步 /etc/ansible/hosts"; return 0; }
  local f="$ANSIBLE_HOSTS_FILE"
  local begin="# >>> kubesetup managed block >>>"
  local end="# <<< kubesetup managed block <<<"
  local tmp; tmp="$(mktemp)" || { warn "mktemp 失败，跳过同步"; return 0; }

  run mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || run touch "$f"

  # 先剔除旧块（若存在），保留其余内容
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$f" 2>/dev/null > "$tmp" || true

  {
    printf '%s\n' "$begin"
    printf '# 由 %s 生成，重跑会覆盖本块；你自己的配置请写在块外\n' "$(basename "$SELF_PATH")"
    # 去掉清单自带的注释行，避免块里出现两行重复说明
    grep -v '^[[:space:]]*#' "$WORKER_INVENTORY" 2>/dev/null || true
    printf '%s\n' "$end"
  } >> "$tmp"

  run cp -f "$tmp" "$f"
  run chmod 0644 "$f"
  rm -f "$tmp"
  ok "已同步 worker 到 $f（手工可用： ansible workers -m ping）"
}

read_worker_plan() {   # 设置全局 WORKER_NUM / JOIN_IPS
  local ip
  [[ -t 0 ]] || die "非交互终端无法读取 worker 数量；可直接用： ansible -i $WORKER_INVENTORY workers -m shell -a 'bash $REMOTE_SCRIPT prepare -y'"
  while true; do
    read -r -p "请输入集群 worker 节点数量： " WORKER_NUM || die "读取输入失败"
    [[ "$WORKER_NUM" =~ ^[0-9]+$ ]] && (( WORKER_NUM >= 1 )) || { warn "数量必须是正整数"; continue; }
    break
  done
  read -r -p "请输入全部 worker IP，用空格隔开： " -a JOIN_IPS || die "读取输入失败"
  (( ${#JOIN_IPS[@]} == WORKER_NUM )) || die "IP 数量 ${#JOIN_IPS[@]} 与节点数 ${WORKER_NUM} 不一致"
  for ip in "${JOIN_IPS[@]}"; do valid_ipv4 "$ip" || die "非法 IP： $ip"; done
}

# 确保 master 上有可用的无口令密钥（幂等）
ensure_ssh_key() {
  [[ -f "$SSH_KEY_FILE" ]] && return 0
  info "未找到 SSH 密钥，生成一对无口令密钥： $SSH_KEY_FILE"
  run mkdir -p "$(dirname "$SSH_KEY_FILE")"
  run ssh-keygen -t rsa -b 2048 -N '' -f "$SSH_KEY_FILE" -C "kubesetup@$(hostname)" >/dev/null 2>&1 || \
    warn "ssh-keygen 失败，可手工执行： ssh-keygen -t rsa -N '' -f $SSH_KEY_FILE"
}

# 免密探测：能非交互登录返回 0
ssh_passwordless_ok() {
  run ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "${ANSIBLE_SSH_USER}@$1" true >/dev/null 2>&1
}

# 把公钥分发到 $@ 列出的节点。
#   A) 系统里**已有** sshpass 时：提示输入一次密码，全部节点复用（可选，脚本不会去装它）
#   B) 没有 sshpass（默认场景）：直接逐台调用 ssh-copy-id，由它提示你输入该节点密码
distribute_ssh_key() {
  local pass="$SSH_PASSWORD" ip okn=0
  ensure_ssh_key
  [[ -f "${SSH_KEY_FILE}.pub" ]] || { err "缺少公钥： ${SSH_KEY_FILE}.pub"; return 1; }

  # ---------- A) 已有 sshpass：一次密码，全节点复用（不会自动安装 sshpass） ----------
  if command -v sshpass >/dev/null 2>&1; then
    if [[ -z "$pass" && -t 0 && "$ASSUME_YES" != 1 ]]; then
      read -r -s -p "请输入 worker（${ANSIBLE_SSH_USER}）密码，用于分发公钥（不回显、不保存）： " pass || pass=""
      printf '\n' >&2
    fi
    if [[ -n "$pass" ]]; then
      for ip in "$@"; do
        if run sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
             -i "${SSH_KEY_FILE}.pub" "${ANSIBLE_SSH_USER}@${ip}" >/dev/null 2>&1; then
          ok "公钥已分发 -> $ip"
          okn=$(( okn + 1 ))
        else
          warn "公钥分发失败 -> $ip（密码错误 / 对端禁止 root 登录 / 端口不通）"
        fi
      done
      (( okn == $# )) && return 0
      (( okn > 0 )) && return 1
    fi
  fi

  # ---------- B) 没有 sshpass：ssh-copy-id 自己提示输入密码，无需任何额外依赖 ----------
  if [[ -t 0 || -c /dev/tty ]]; then
    command -v ssh-copy-id >/dev/null 2>&1 || {
      warn "缺少 ssh-copy-id（openssh-clients），可 yum install -y openssh-clients"; return 1; }
    info "接下来逐台执行 ssh-copy-id，每台会提示输入一次 ${ANSIBLE_SSH_USER} 密码："
    for ip in "$@"; do
      printf '  --- %s ---\n' "$ip" >&2
      if run ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
           -i "${SSH_KEY_FILE}.pub" "${ANSIBLE_SSH_USER}@${ip}"; then
        ok "公钥已分发 -> $ip"
        okn=$(( okn + 1 ))
      else
        warn "公钥分发失败 -> $ip（密码错误 / 对端禁止 root 登录 / 端口不通）"
      fi
    done
    (( okn == $# ))
    return
  fi

  warn "当前不是交互终端，无法提示输入密码"
  warn "请手工执行下面的 ssh-copy-id 命令，或安装 sshpass（yum install -y sshpass，需 EPEL）"
  return 1
}

# 免密配置总入口：探测 -> 失败则尝试自动分发 -> 再探测 -> 仍失败则给出可照抄的命令并退出。
# 注意：不能把探测交给 ansible——它会在没密钥时交互式弹 "continue connecting (yes/no)"
# 和密码提示，脚本会卡住（实测过）。
check_ssh_passwordless() {
  local ip bad=()
  ensure_ssh_key
  for ip in "$@"; do
    ssh_passwordless_ok "$ip" || bad+=("$ip")
  done
  if (( ${#bad[@]} == 0 )); then
    ok "SSH 免密正常（$# 台）"; return 0
  fi

  warn "以下节点免密不可用： ${bad[*]}；尝试自动分发公钥"
  if distribute_ssh_key "${bad[@]}"; then
    bad=()
    for ip in "$@"; do
      ssh_passwordless_ok "$ip" || bad+=("$ip")
    done
    if (( ${#bad[@]} == 0 )); then
      ok "SSH 免密已自动配置完成（$# 台）"; return 0
    fi
    warn "分发后仍不可达： ${bad[*]}"
  fi

  err "以下节点 SSH 免密仍不可用： ${bad[*]}"
  err "请手工执行（每条提示输入一次对方 root 密码）："
  for ip in "${bad[@]}"; do
    err "    ssh-copy-id -o StrictHostKeyChecking=no ${ANSIBLE_SSH_USER}@${ip}"
  done
  err "若已装密钥仍失败：检查对端 sshd 的 PermitRootLogin、22 端口、以及是否装了 python"
  die "配好免密后重跑： $(self_invocation) scale"
}

# 探测每台 worker 的 python 路径，填进 REMOTE_PY；有节点缺失则报错退出。
# 为什么必须探测：ansible 2.7 不做解释器自动发现，而 CentOS 8+ 只有 python3——
# 清单里写死 /usr/bin/python 会让 ping 直接失败（就是踩过的坑）。
probe_remote_pythons() {
  local ip py p missing=()
  for ip in "$@"; do
    if [[ -n "$ANSIBLE_PYTHON_INTERPRETER" ]]; then
      REMOTE_PY["$ip"]="$ANSIBLE_PYTHON_INTERPRETER"
      continue
    fi
    py=""
    for p in /usr/bin/python /usr/libexec/platform-python /usr/bin/python3 /usr/local/bin/python3; do
      if run ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
           "${ANSIBLE_SSH_USER}@${ip}" "test -x $p" >/dev/null 2>&1; then
        py=$p; break
      fi
    done
    if [[ -n "$py" ]]; then
      REMOTE_PY["$ip"]=$py
      debug "$ip -> $py"
    else
      missing+=("$ip")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    ok "python 解释器： $(for ip in "$@"; do printf '%s=%s ' "$ip" "${REMOTE_PY[$ip]:-}"; done)"
    return 0
  fi
  err "以下节点找不到可用 python： ${missing[*]}"
  err "ansible 执行模块需要远端 python。请在对应节点安装后重跑："
  err "    CentOS 7 ： yum install -y python"
  err "    CentOS 8+： dnf install -y python3   （或加 --ansible-python /usr/libexec/platform-python）"
  die "装好 python 后重跑： $(self_invocation) scale"
}

scale_workers() {
  need_root
  setup_kubeconfig
  read_worker_plan

  local join_cmd; join_cmd="$(get_join_command reuse)"
  info "$join_cmd"

  command -v ansible >/dev/null 2>&1 || yum_install ansible
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "ansible workers: 分发脚本 -> prepare -> $join_cmd"
    return 0
  fi
  confirm "将对 ${WORKER_NUM} 台 worker 执行 安装 docker/kubelet 并 join 集群，确认？"

  info "SSH 连通性检查"
  # 关键：先用 ssh -o BatchMode=yes 做一次纯免密探测。
  # 若直接交给 ansible，它会在没有密钥时交互式弹 "Are you sure you want to continue connecting"
  # 与密码提示，脚本会卡住；且 ansible 默认校验主机指纹，也会弹 yes/no。
  check_ssh_passwordless "${JOIN_IPS[@]}"

  info "探测远端 python（ansible 执行模块需要）"
  probe_remote_pythons "${JOIN_IPS[@]}"

  write_worker_inventory "${JOIN_IPS[@]}"
  sync_ansible_hosts

  local pingout
  pingout="$(ansible -i "$WORKER_INVENTORY" "${ANSIBLE_COMMON[@]}" workers -m ping -f "$ANSIBLE_FORKS" 2>&1 || true)"
  printf '%s\n' "$pingout" | grep -E '(SUCCESS|UNREACHABLE|FAILED)' >&2 || true
  if printf '%s\n' "$pingout" | grep -qE '(UNREACHABLE|FAILED)'; then
    err "ansible ping 失败，完整输出如下："
    printf '%s\n' "$pingout" | sed 's/^/    /' >&2
    err "常见原因："
    err "  · 远端缺 python —— CentOS 7 是 /usr/bin/python；CentOS 8/Stream 只有 python3，需加 --ansible-python /usr/libexec/platform-python"
    err "  · SSH 端口非 22、root 被 sshd 禁止登录（PermitRootLogin no）"
    err "  · 免密只对 root 生效但清单里用的是别的用户（--ssh-user）"
    err "手工排查（可直接复制）："
    err "    ansible -i $WORKER_INVENTORY workers -m ping -vvv"
    err "    ssh -o BatchMode=yes ${ANSIBLE_SSH_USER}@<IP> 'python -V || python3 -V'"
    die "修好后重跑： $(self_invocation) scale"
  fi

  info "分发本脚本 -> 各 worker:${REMOTE_SCRIPT}"
  ansible -i "$WORKER_INVENTORY" "${ANSIBLE_COMMON[@]}" workers -m copy \
    -a "src=${SELF_PATH} dest=${REMOTE_SCRIPT} mode=0755" -f "$ANSIBLE_FORKS" 2>&1 | tail -n 15 >&2 || \
    die "脚本分发失败"

  info "worker 节点准备（repo / sysctl / docker / kubelet）"
  # CRI socket 留空时不往远端传，让 worker 侧同样走 kubeadm 自动探测
  local cri_arg=""
  [[ -n "$CRI_SOCKET" ]] && cri_arg=" --cri-socket ${CRI_SOCKET}"
  ansible -i "$WORKER_INVENTORY" "${ANSIBLE_COMMON[@]}" workers -m shell \
    -a "bash ${REMOTE_SCRIPT} prepare --k8s-version ${K8S_VERSION} --pod-cidr ${POD_CIDR} --service-cidr ${SERVICE_CIDR}${cri_arg} -y" \
    -f "$ANSIBLE_FORKS" -T 1800 2>&1 | tail -n 30 >&2 || \
    die "worker 准备失败，排查： ansible -i $WORKER_INVENTORY workers -m ping"

  info "worker 加入集群"
  local i=0 failed=0
  for ip in "${JOIN_IPS[@]}"; do
    i=$(( i + 1 ))
    if ansible -i "$WORKER_INVENTORY" "${ANSIBLE_COMMON[@]}" "${WORKER_HOST_PREFIX}${i}" -m shell \
         -a "${join_cmd}${cri_arg}" -T 900 >>"$LOG_FILE" 2>&1; then
      ok "${WORKER_HOST_PREFIX}${i}（$ip）已 join"
    else
      warn "${WORKER_HOST_PREFIX}${i}（$ip）join 失败，详见 $LOG_FILE"
      failed=$(( failed + 1 ))
    fi
  done
  (( failed == 0 )) || warn "${failed} 台 join 失败，可单独重试： $(self_invocation) scale"

  wait_for "全部节点 Ready（期望 $(( WORKER_NUM + 1 )) 个）" "$WAIT_TIMEOUT" \
    bash -c "[ \$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') -ge $(( WORKER_NUM + 1 )) ]"
  kubectl get nodes -o wide >&2 || true
}

# ----------------------------- 6.6 节点缩容（drain）-----------------------------
# 把 worker 上的 Pod 优雅驱逐 -> 把节点置为 SchedulingDisabled -> 从集群摘除。
# 默认逐台执行；--node 指定单台，--yes 免确认。节点摘除后可用 scale 重新加入。
drain_workers() {
  need_root
  setup_kubeconfig

  local targets=() node n
  if [[ -n "${DRAIN_NODE:-}" ]]; then
    targets=("$DRAIN_NODE")
  else
    read -r -p "请输入要摘除的节点名，空格分隔（如 worker2）： " -a targets || die "读取输入失败"
    (( ${#targets[@]} >= 1 )) || die "未输入任何节点"
  fi

  for n in "${targets[@]}"; do
    kubectl get node "$n" >/dev/null 2>&1 || { warn "节点 $n 不在集群中，跳过"; continue; }
    node="$n"
    break
  done
  [[ -n "${node:-}" ]] || die "没有一个节点存在于集群中： ${targets[*]}"

  # 保护控制面：master 是单点，脚本不允许从这里摘
  if kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | grep -qE 'master|control-plane'; then
    die "$node 是 master（控制面），本脚本为单 master 架构不支持移除 master"
  fi

  confirm "将对以下节点执行 drain 并摘除： ${targets[*]}，确认？"

  local failed=0
  for node in "${targets[@]}"; do
    kubectl get node "$node" >/dev/null 2>&1 || { warn "$node 不在集群中，跳过"; continue; }
    info "drain $node（驱逐 Pod + 停止调度）"
    if [[ "$DRY_RUN" == 1 ]]; then
      dry "kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --grace-period=60"
    else
      if kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
           --grace-period=60 --timeout=5m 2>>"$LOG_FILE"; then
        ok "$node drain 完成"
      else
        # drain 失败常因 PDB/本地存储；--force 是最后手段，仍然保留确认
        warn "$node drain 失败（详见日志），尝试 --force"
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
          --force --grace-period=60 --timeout=5m 2>>"$LOG_FILE" || {
          warn "$node 强 drain 也失败，跳过摘除"; failed=$(( failed + 1 )); continue; }
      fi
      kubectl delete node "$node" >>"$LOG_FILE" 2>&1 && ok "节点已摘除： $node"
      # 顺带清理 ansible 清单与 /etc/ansible/hosts 里的对应行
      remove_node_from_inventory "$node"
    fi
  done
  (( failed == 0 )) || warn "${failed} 个节点摘除失败，可重跑： $(self_invocation) drain"

  info "剩余节点："
  kubectl get nodes -o wide >&2 || true
}

# 从本机 worker 清单与 /etc/ansible/hosts 受管块中移除某个节点（幂等）
remove_node_from_inventory() {
  local node=$1 ip
  ip="$(grep -E "^${node} " "$WORKER_INVENTORY" 2>/dev/null | sed 's/.*ansible_host=\([0-9.]*\).*/\1/' | head -n1)"
  [[ -n "$ip" ]] && REMOTE_PY[$ip]=""
  sed -i "/^${node} /d" "$WORKER_INVENTORY" 2>/dev/null || true
  # /etc/ansible/hosts 的受管块同样清掉
  [[ "$SYNC_ANSIBLE_HOSTS" == 1 && -f "$ANSIBLE_HOSTS_FILE" ]] && \
    sed -i "/^${node} /d" "$ANSIBLE_HOSTS_FILE" 2>/dev/null || true
  debug "已从清单移除 $node"
}

# ----------------------------- 6.7 证书管理 --------------------------------
cert_expiry() {
  setup_kubeconfig
  local out
  if ! out="$(kubeadm certs check-expiration 2>&1)"; then
    err "无法读取证书状态："
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    die "可能还没初始化（先 kubesetup init）或 kubeadm 不可用"
  fi
  printf '%s\n' "$out"
}

# 一键续期：kubeadm certs renew all 会在线续期 CA 之外的所有控制面证书
# （CA 证书无法续期，只能换新并重新签发）。续期后需要重启控制面组件生效。
renew_certs() {
  need_root
  cert_expiry >/dev/null 2>&1 || die "集群未初始化，无法续期"
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "kubeadm certs renew all"
    dry "重启静态 Pod： mv /etc/kubernetes/manifests/*.yaml 再移回（或重启 kubelet）"
    return 0
  fi
  confirm "将续期全部控制面证书并重启控制面组件（会短暂影响 apiserver），确认？"
  if kubeadm certs renew all >>"$LOG_FILE" 2>&1; then
    ok "证书已续期"
  else
    tail -n 20 "$LOG_FILE" >&2 || true
    die "续期失败，详见日志"
  fi
  info "重启控制面静态 Pod 使新证书生效"
  local tmpd=/etc/kubernetes/manifests.bak
  run mkdir -p "$tmpd"
  run mv /etc/kubernetes/manifests/*.yaml "$tmpd/" 2>/dev/null || true
  sleep 5
  run mv "$tmpd"/*.yaml /etc/kubernetes/manifests/ 2>/dev/null || true
  run rmdir "$tmpd" 2>/dev/null || true
  wait_for "apiserver 恢复" 180 kubectl get --raw='/readyz?verbose'
  ok "证书续期完成；再次查看： $(self_invocation) certs"
}

# ----------------------------- 6.8 etcd 快照备份 ------------------------------
# kubeadm 部署的 etcd 是 static pod，etcdctl **不在宿主机上**，而是在 etcd 容器里。
# 因此优先用 docker exec 进容器做 snapshot save，再 docker cp 出来；宿主若有
# etcdctl 也可以直接用。快照目录/保留份数：ETCD_BACKUP_DIR / ETCD_BACKUP_KEEP。
BACKUP_CERTS_DIR=/etc/kubernetes/pki/etcd

etcd_backup() {
  need_root
  setup_kubeconfig
  local dir="${ETCD_BACKUP_DIR:-/root/etcd-backups}"
  local keep="${ETCD_BACKUP_KEEP:-7}"
  local name f

  run mkdir -p "$dir"
  name="etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"
  f="$dir/$name"

  # dry-run 放在所有探测之前：不碰系统、也不因缺 etcdctl 而失败
  if [[ "$DRY_RUN" == 1 ]]; then
    dry "在 etcd 容器内执行 etcdctl snapshot save /tmp/$name"
    dry "docker cp <etcd容器>:/tmp/$name $f"
    dry "保留最近 $keep 份：清理更早的 $dir/etcd-snapshot-*.db"
    return 0
  fi

  # ① 宿主机自带 etcdctl 时直接快照
  local hostctl
  hostctl="$(command -v etcdctl 2>/dev/null || true)"
  [[ -n "$hostctl" && -x "$hostctl" ]] || hostctl=""
  if [[ -n "$hostctl" ]]; then
    info "使用宿主机 etcdctl 创建快照： $f"
    if ! ETCDCTL_API=3 "$hostctl" snapshot save "$f" \
         --cacert "$BACKUP_CERTS_DIR/ca.crt" --cert "$BACKUP_CERTS_DIR/server.crt" \
         --key "$BACKUP_CERTS_DIR/server.key" --endpoints https://127.0.0.1:2379 \
         >>"$LOG_FILE" 2>&1; then
      tail -n 20 "$LOG_FILE" >&2 || true
      die "etcd 快照失败（详见 $LOG_FILE）"
    fi
  else
    # ② 走 etcd 容器（kubeadm + docker 的常规情况）
    command -v docker >/dev/null 2>&1 || die "宿主机没有 etcdctl，也没有 docker，无法创建 etcd 快照"
    local cid
    cid="$(docker ps --filter 'name=k8s_etcd' --format '{{.ID}}' 2>/dev/null | head -n1)"
    [[ -n "$cid" ]] || cid="$(docker ps --filter 'ancestor=.*etcd' --format '{{.ID}}' 2>/dev/null | head -n1)"
    [[ -n "$cid" ]] || die "找不到 etcd 容器（docker ps --filter name=k8s_etcd）；集群可能未初始化"
    info "在 etcd 容器内创建快照： $cid"
    if ! docker exec -e ETCDCTL_API=3 "$cid" etcdctl snapshot save "/tmp/$name" \
         --cacert "$BACKUP_CERTS_DIR/ca.crt" --cert "$BACKUP_CERTS_DIR/server.crt" \
         --key "$BACKUP_CERTS_DIR/server.key" --endpoints https://127.0.0.1:2379 \
         >>"$LOG_FILE" 2>&1; then
      tail -n 20 "$LOG_FILE" >&2 || true
      die "容器内 etcdctl 快照失败（详见 $LOG_FILE）"
    fi
    docker cp "$cid:/tmp/$name" "$f" >>"$LOG_FILE" 2>&1 || die "从容器拷贝快照失败"
    docker exec "$cid" rm -f "/tmp/$name" >>"$LOG_FILE" 2>&1 || true
  fi

  [[ -s "$f" ]] || die "快照文件为空： $f"
  ok "etcd 快照已保存： $f（$(du -h "$f" | awk '{print $1}')）"
  run chmod 600 "$f"

  # 只保留最近 N 份
  local cnt
  cnt=$(ls -1t "$dir"/etcd-snapshot-*.db 2>/dev/null | wc -l)
  if (( cnt > keep )); then
    ls -1t "$dir"/etcd-snapshot-*.db 2>/dev/null | tail -n $(( cnt - keep )) | while read -r old; do
      run rm -f "$old" && debug "清理旧快照： $old"
    done
    ok "保留最近 $keep 份，已清理 $(( cnt - keep )) 份"
  fi
  info "恢复提示：见 README「etcd 备份与恢复」一节（需停 etcd 后 snapshot restore）"
}

# ----------------------------- 6.5 flannel 清单落盘 ---------------------------
write_flannel_manifest() {
  info "生成 CNI 清单： $FLANNEL_MANIFEST"
  [[ -f "$FLANNEL_MANIFEST" ]] && backup_path "$FLANNEL_MANIFEST"
  write_file "$FLANNEL_MANIFEST" <<'EOF'
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    k8s-app: flannel
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
    k8s-app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        #image: docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel2
        image: registry.cn-beijing.aliyuncs.com/jack_web_images/flannel-cni-plugin-all:v1.5.1-flannel2
        command:
        - cp
        args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        #image: docker.io/flannel/flannel:v0.25.7
        image: registry.cn-beijing.aliyuncs.com/jack_web_images/flannel-all:v0.25.7
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        #image: docker.io/flannel/flannel:v0.25.7
        image: registry.cn-beijing.aliyuncs.com/jack_web_images/flannel-all:v0.25.7
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
EOF
  ok "$FLANNEL_MANIFEST 已生成（正文与 kube-flannel-all.yml 一致）"
}
# ----------------------------- 7. 预检 / 状态 / 清理 -------------------------
preflight() {
  info "预检目标： $(cat /etc/redhat-release 2>/dev/null || echo '非 RHEL 系') / $(hostname)"
  local fails=0
  chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else warn "$d"; fails=$(( fails + 1 )); fi; }

  chk "root 权限"               test "$(id -u)" -eq 0
  chk "CentOS/RHEL 7"           grep -qi 'release 7' /etc/redhat-release
  chk "内存 >= 2GB"             awk '/^MemTotal:/{exit !($2>=2097152)}' /proc/meminfo
  chk "CPU >= 2 核"             test "$(nproc)" -ge 2
  chk "根分区可用 >= 20GB"      test "$(df -Pm / | awk 'NR==2{print $4}')" -ge 20480
  chk "swap 已关闭"             test -z "$(swapon --show=NAME --noheadings 2>/dev/null)"
  chk "SELinux 已关闭"          test "$(getenforce 2>/dev/null || echo Disabled)" = Disabled
  chk "firewalld 已停止"        bash -c '! systemctl is-active --quiet firewalld'
  chk "ipv4 转发已开启"          test "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1
  chk "br_netfilter 已加载"     grep -q '^br_netfilter ' /proc/modules
  chk "ip_vs 已加载"            grep -q '^ip_vs ' /proc/modules
  chk "主机名符合 k8s 规范"      bash -c '[[ "$(hostname)" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]'
  chk "主机名可解析"            bash -c 'getent hosts "$(hostname)" >/dev/null'
  chk "Pod 网段与清单一致"       test "$POD_CIDR" = "$FLANNEL_NETWORK"
  chk "docker 正在运行"         systemctl is-active --quiet docker
  chk "docker cgroup=systemd"   bash -c 'docker info 2>/dev/null | grep -qi "Cgroup Driver:[[:space:]]*systemd"'
  chk "kubelet 已 enable"       systemctl is-enabled --quiet kubelet
  chk "kubeadm 版本匹配"        test "$(kubeadm version -o short 2>/dev/null)" = "v${K8S_VERSION}"
  chk "已能探测到本机 IPv4"      detect_ip

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    chk "控制面 readyz 通过" bash -c 'KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw="/readyz?verbose" >/dev/null'
    chk "kube-proxy 为 ipvs" bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get cm kube-proxy -o yaml 2>/dev/null | grep -q ipvs"
  else
    info "本机尚未 kubeadm init，跳过集群内检查（装完再跑一次本命令）"
  fi

  printf '\n' >&2
  if (( fails == 0 )); then
    ok "预检全部通过"
  else
    warn "共 ${fails} 项未通过；集群未安装时部分项属预期，修复后重跑： $(self_invocation) preflight"
  fi
  (( fails == 0 ))
}

status() {
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  command -v kubectl >/dev/null 2>&1 || die "kubectl 未安装，无可查看的集群状态"
  # 节点与组件状态放一起输出（get cs 读的是 insecure 端口，见下方说明）
  info "节点与组件状态"
  kubectl get nodes -o wide || true
  printf '\n' >&2
  kubectl get cs 2>/dev/null || warn "kubectl get cs 不可用（k8s 1.19+ 已废弃 ComponentStatus）"
  info "健康检查（readyz 是真实状态，优先级高于 get cs）"
  if kubectl get --raw='/readyz' >/dev/null 2>&1; then
    ok "readyz 通过"
  else
    warn "readyz 未通过，检查： kubectl -n kube-system get pods"
    kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -E '^\[-\]' | head -5 || true
  fi
  # 说明 get cs 的坑：它读的是 insecure 端口，--port=0 时会显示 Unhealthy
  if insecure_ports_enabled; then
    info "控制面 insecure 端口：开启（get cs 会显示 Healthy；仅限实验环境）"
  else
    info "控制面 insecure 端口：关闭（安全默认）"
    info "  └ 上面 get cs 若显示 scheduler/controller-manager Unhealthy，是正常的，不代表集群有故障"
    info "  └ 想让 get cs 全绿： sudo $(self_invocation) ports --on（生产不要开）"
  fi
  info "控制面与 CNI Pod"
  kubectl get pods -A -o wide 2>/dev/null | awk 'NR==1 || $1 ~ /^kube-/' || true
  if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    info "ingress-nginx"
    kubectl -n ingress-nginx get pods -o wide 2>/dev/null || true
    local ingress_np
    ingress_np="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
                  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
    kubectl get ingressclass 2>/dev/null >&2 || true
    if [[ -n "$ingress_np" ]]; then
      info "  └ 入口： http://<节点IP>:${ingress_np}（NodePort）"
    fi
  fi
  info "kube-proxy 模式"
  kubectl -n kube-system get cm kube-proxy -o yaml 2>/dev/null | grep -oE 'mode: *"?ipvs"?' | head -n1 \
    || warn "未检测到 ipvs"
  info "证书有效期"
  command -v kubeadm >/dev/null 2>&1 && kubeadm certs check-expiration 2>/dev/null | head -n 15 || true
  info "join 命令缓存"
  if [[ -s "$JOIN_FILE" ]]; then cat "$JOIN_FILE"; else warn "无 $JOIN_FILE（init 后自动生成）"; fi
}

reset_local() {
  need_root
  confirm "将重置本机集群（清空 CNI 配置、kubelet 证书与 iptables/IPVS 规则），确认？"
  command -v kubeadm >/dev/null 2>&1 && { quiet kubeadm reset -f || warn "kubeadm reset 失败，见日志"; }
  run rm -rf /etc/cni/net.d "$HOME/.kube"
  if command -v iptables >/dev/null 2>&1; then
    quiet iptables -FP || true
    quiet iptables -t nat -FP || true
    quiet iptables -t mangle -FP || true
  fi
  command -v ipvsadm >/dev/null 2>&1 && { quiet ipvsadm --clear || true; }
  quiet systemctl disable --now kubelet || true
  ok "本机已重置"
  warn "彻底重来还需： yum remove -y kubelet kubeadm kubectl docker-ce* containerd.io && rm -rf /var/lib/etcd /var/lib/kubelet ${DOCKER_DATA_ROOT}"
}

# ----------------------------- 8. 参数解析与入口 ------------------------------
usage() {
  # 头部注释里的示例写的是 kubeadm-install.sh；这里替换成当前实际文件名，
  # 这样把脚本改名（或安装成 kubesetup）后，帮助里显示的名字依然对得上。
  local name; name="$(basename "$SELF_PATH")"
  awk 'f && /^# ={10,}/ {exit} NR>=3 {f=1; sub(/^# ?/,""); print}' "$SELF_PATH" \
    | while IFS= read -r line; do printf '%s\n' "${line//kubeadm-install.sh/$name}"; done
}

parse_args() {
  CMD="bootstrap"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --k8s-version)      K8S_VERSION="${2:?--k8s-version 需要值}"; shift 2 ;;
      --service-cidr)     SERVICE_CIDR="${2:?--service-cidr 需要值}"; shift 2 ;;
      --pod-cidr)         POD_CIDR="${2:?--pod-cidr 需要值}"; shift 2 ;;
      --apiserver-ip)     API_ADVERTISE_ADDRESS="${2:?--apiserver-ip 需要值}"; shift 2 ;;
      --image-repository) IMAGE_REPOSITORY="${2:?--image-repository 需要值}"; shift 2 ;;
      --cri-socket)       CRI_SOCKET="${2:?--cri-socket 需要值}"; shift 2 ;;
      --node-name)        NODE_NAME="${2:?--node-name 需要值}"; shift 2 ;;
      --ssh-user)         ANSIBLE_SSH_USER="${2:?--ssh-user 需要值}"; shift 2 ;;
      --ssh-pass)         SSH_PASSWORD="${2:?--ssh-pass 需要值}"; shift 2 ;;
      --ssh-key)          SSH_KEY_FILE="${2:?--ssh-key 需要值}"; shift 2 ;;
      --keep-backups)     KEEP_BACKUPS=1; shift ;;
      --no-crictl-download) CRICTL_DOWNLOAD=0; shift ;;
      --crictl-version)   CRICTL_VERSION_COMPAT="${2:?--crictl-version 需要值}"; shift 2 ;;
      --on)               PORTS_MODE=on; shift ;;
      --off)              PORTS_MODE=off; shift ;;
      --log-keep)         LOG_KEEP="${2:?--log-keep 需要值}"; shift 2 ;;
      --drain-node)       DRAIN_NODE="${2:?--drain-node 需要值}"; shift 2 ;;
      --backup-dir)       ETCD_BACKUP_DIR="${2:?--backup-dir 需要值}"; shift 2 ;;
      --backup-keep)      ETCD_BACKUP_KEEP="${2:?--backup-keep 需要值}"; shift 2 ;;
      --ansible-hosts)    ANSIBLE_HOSTS_FILE="${2:?--ansible-hosts 需要值}"; shift 2 ;;
      --ansible-python)   ANSIBLE_PYTHON_INTERPRETER="${2:?--ansible-python 需要值}"; shift 2 ;;
      --sync-hosts)       SYNC_ANSIBLE_HOSTS=1; shift ;;
      --no-sync-hosts)    SYNC_ANSIBLE_HOSTS=0; shift ;;
      --inventory)        WORKER_INVENTORY="${2:?--inventory 需要值}"; shift 2 ;;
      --manifest)         FLANNEL_MANIFEST="${2:?--manifest 需要值}"; shift 2 ;;
      --ingress-manifest) INGRESS_MANIFEST="${2:?--ingress-manifest 需要值}"; shift 2 ;;
      -l|--log-file)      LOG_FILE="${2:?$1 需要值}"; shift 2 ;;
      --force)            FORCE=1; shift ;;
      --insecure-ports)   ALLOW_INSECURE_PORTS=1; shift ;;
      --restart-network)  RESTART_NETWORK=1; shift ;;
      --token-ttl)        TOKEN_TTL="${2:?--token-ttl 需要值（0=永不过期，或 30m/24h）}"; shift 2 ;;
      --ttl-forever|--never-expire) TOKEN_TTL=0; shift ;;
      --no-completion)    INSTALL_COMPLETION=0; shift ;;
      --with-completion)  INSTALL_COMPLETION=1; shift ;;
      --no-install-cmd)   INSTALL_SYS_CMD=0; shift ;;
      --install-cmd)      INSTALL_SYS_CMD=1; shift ;;
      --cmd-name)         SYS_CMD_NAME="${2:?--cmd-name 需要值}"; shift 2 ;;
      --cmd-dir)          SYS_CMD_DIR="${2:?--cmd-dir 需要值}"; shift 2 ;;
      -y|--yes)           ASSUME_YES=1; shift ;;
      -n|--dry-run)       DRY_RUN=1; shift ;;
      -v|--verbose)       VERBOSE=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      # 子命令白名单来自 SUBCOMMANDS，避免与补全清单两处漂移
      *) if is_subcommand "$1"; then CMD="$1"; shift; else err "未知参数： $1（-h 查看用法）"; exit 2; fi ;;
    esac
  done

  [[ "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "K8S_VERSION 需形如 1.20.11： $K8S_VERSION"
  valid_cidr "$SERVICE_CIDR" || die "SERVICE_CIDR 非法： $SERVICE_CIDR"
  valid_cidr "$POD_CIDR"     || die "POD_CIDR 非法： $POD_CIDR"
  # CRI_SOCKET 为空表示交给 kubeadm 自动探测（默认，推荐）；非空则必须是 unix:// 形式
  [[ -z "$CRI_SOCKET" || "$CRI_SOCKET" == unix://* ]] || \
    die "CRI_SOCKET 需形如 unix:///run/containerd/containerd.sock，或留空由 kubeadm 自动探测： $CRI_SOCKET"
  # TOKEN_TTL：0 = 永不过期；否则须是 Go duration（30m / 2h / 24h / 90s）
  case "$TOKEN_TTL" in
    0|never) TOKEN_TTL=0 ;;
    *) [[ "$TOKEN_TTL" =~ ^([0-9]+(\.[0-9]+)?(ns|us|µs|ms|s|m|h))+$ ]] || \
         die "--token-ttl 需为 0（永不过期）或 Go 时长（如 30m/2h/24h/1h30m）： $TOKEN_TTL" ;;
  esac
  [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT 需为秒数： $WAIT_TIMEOUT"

  # 网段以清单为唯一来源：清单已存在时读其中的 Network，避免两处各写一份
  [[ -n "$FLANNEL_NETWORK" ]] || FLANNEL_NETWORK="$(flannel_network_from_manifest "$FLANNEL_MANIFEST")"

  # 注意：`:` 的重定向按从左到右处理，若写成 `: >"$LOG_FILE" 2>/dev/null`，
  # 打开失败的信息会在 stderr 被重定向之前打印出来。故用 { } 包住整条命令再屏蔽。
  if ! { : >"$LOG_FILE"; } 2>/dev/null; then      # /var/log 不可写时退回 /tmp
    LOG_FILE="${TMPDIR:-/tmp}/$(basename "$LOG_FILE")"
    { : >"$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
  fi
  export LOG_FILE
  prune_old_logs        # 只保留最近 LOG_KEEP 份，避免日志越攒越多
}

set_node_name() {
  [[ -n "$NODE_NAME" ]] || return 0
  need_root
  local cur; cur="$(hostname)"
  [[ "$cur" == "$NODE_NAME" ]] && { debug "主机名已是 $NODE_NAME"; return 0; }
  [[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "主机名需为小写字母/数字/-/.： $NODE_NAME"
  info "主机名： $cur -> $NODE_NAME"
  run hostnamectl set-hostname "$NODE_NAME" || die "hostnamectl 设置失败"
  if ! grep -qE "[[:space:]]${NODE_NAME}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    local ip; ip="$(detect_ip || true)"
    backup_path /etc/hosts
    run bash -c "echo \"${ip:-127.0.0.1} ${NODE_NAME}\" >>/etc/hosts"
  fi
}

banner() {
  local ip; ip="$(detect_ip || echo '未探测到，可用 --apiserver-ip 指定')"
  info "子命令=$CMD | K8S=v${K8S_VERSION} | pod=$POD_CIDR | svc=$SERVICE_CIDR | cri=${CRI_SOCKET:-自动}"
  info "主机=$(hostname) ip=${ip} | dry-run=${DRY_RUN} | 日志=$LOG_FILE"
  printf -- '--------------------------------------------------------------------------\n' >&2
  [[ "$DRY_RUN" == 1 ]] && info "DRY-RUN：只校验与打印，不落盘、不装包、不动服务"
  return 0
}

main() {
  parse_args "$@"
  banner

  # 核心诉求：不管本次子命令最终成功还是中途失败，$SYS_CMD_NAME 都必须已经就位。
  # 因此放在分派之前执行（若放在之后，status/token 这类会 die 的子命令就装不上了）。
  case "$CMD" in
    uninstall) : ;;                                   # 卸载分支自己删，不预装
    install)   need_root; install_system_command force ;;
    *)         install_system_command ;;              # 先装，保证“跑完就有命令”
  esac

  case "$CMD" in
    # preflight 用 || 调用：既保留非 0 退出码（便于 CI），又不会触发 ERR trap 的“失败”噪声
    preflight)     preflight || { err "预检未通过（详见上方 [warn] 列表）"; exit 1; } ;;
    prepare)       need_root; set_node_name; node_prepare ;;
    init)          need_root; set_node_name; master_init ;;
    token)         need_root; token_cmd ;;
    completion)    need_root; install_shell_completion ;;
    cni)           need_root; apply_cni ;;
    ingress)       need_root; apply_ingress ;;
    scale)         need_root; scale_workers ;;
    ports)         ports_cmd ;;
    drain)         need_root; drain_workers ;;
    certs)         cert_expiry ;;
    renew)         need_root; renew_certs ;;
    backup)        need_root; etcd_backup ;;
    status)        status ;;
    reset)         need_root; reset_local ;;
    install)       : ;;
    uninstall)     uninstall_system_command ;;
    bootstrap)
      need_root
      set_node_name
      node_prepare
      master_init
      apply_cni
      if confirm "master 与 CNI 就绪，继续添加 worker 节点？"; then
        scale_workers
      else
        warn "已跳过 worker 扩容，稍后可执行： $(self_invocation) scale"
      fi
      # ingress 放在 worker 之后：控制面默认带 NoSchedule taint，先加 worker 才能调度
      apply_ingress
      status
      ;;
    *) usage; exit 2 ;;
  esac

  printf -- '--------------------------------------------------------------------------\n' >&2
  ok "完成： $CMD"
  info "日志： $LOG_FILE"
}

main "$@"
