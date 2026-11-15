#!/bin/bash
# ============================================================================
#  docker-install.sh —— CentOS / RHEL 7/8/9 Docker CE 一键安装脚本
#
#  依据《Docker》课程文档整理，覆盖：
#    1. 环境检查（内核 >= 3.10）
#    2. 开启 IPv4 转发 net.ipv4.ip_forward=1（否则容器无法访问外网）
#    3. 时区 + 时间同步（chronyd，退化为 ntpdate）
#    4. 卸载旧版本 docker / docker-client / docker-engine 等
#    5. 添加阿里云（或官方）docker-ce 仓库
#    6. 安装 docker-ce / docker-ce-cli / containerd.io / buildx / compose 插件
#    7. 生成 /etc/docker/daemon.json（镜像加速、data-root、dns、insecure-registry）
#    8. 启动并设置开机自启，docker version / docker info 校验，hello-world 测试
#
#  用法:
#    ./docker-install.sh install                   # 安装（默认子命令）
#    ./docker-install.sh install --version 26.1.4  # 安装指定版本
#    ./docker-install.sh configure                 # 只重写 daemon.json 并重启
#    ./docker-install.sh status | start | stop | restart | info
#    ./docker-install.sh uninstall [--purge]
#
#  常用选项:
#    --version VER          指定 docker-ce 版本（默认装仓库最新版）
#    --repo aliyun|official|<URL>   仓库来源，默认 aliyun
#    --mirror "u1,u2"       镜像加速地址，逗号分隔
#    --no-mirror            不配置镜像加速
#    --data-root DIR        镜像/容器存储目录，默认 /data/docker_data
#    --dns "ip1,ip2"        daemon 的 DNS，默认 223.5.5.5,8.8.8.8
#    --insecure-registry "ip:5000"  信任的 HTTP 仓库（可重复）
#    --user NAME            把用户加入 docker 组
#    --no-start             装完不启动
#    --no-test              跳过 hello-world 测试
#    --skip-time            跳过时区/时间同步
#    --keep-daemon          已存在 daemon.json 时不覆盖
#    -f, --force            强制重装（含移除已有 docker-ce）
#    --purge                卸载时同时删除镜像/容器数据
#    -h, --help             帮助
# ============================================================================

set -euo pipefail

# ------------------------------- 默认配置 -------------------------------------
DOCKER_VERSION=""
REPO="aliyun"
MIRRORS=(
  "https://docker.1ms.run"
  "https://docker.1panel.live"
  "https://docker.m.daocloud.io"
  "https://mirror.ccs.tencentyun.com"
)
DATA_ROOT="/data/docker_data"
DNS_SERVERS=("223.5.5.5" "8.8.8.8")
INSECURE_REGISTRIES=()
DO_START=1
DO_TEST=1
DO_TIME=1
TIMEZONE="Asia/Shanghai"
NTP_SERVER="ntp1.aliyun.com"
KEEP_DAEMON=0
FORCE=0
PURGE=0
DOCKER_USER=""

DAEMON_JSON="/etc/docker/daemon.json"
REPO_FILE="/etc/yum.repos.d/docker-ce.repo"
SYSCTL_FILE="/etc/sysctl.d/99-docker.conf"
LEGACY_PKGS="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine docker-engine-selinux"
CORE_PKGS=(docker-ce docker-ce-cli containerd.io)
PLUGIN_PKGS=(docker-buildx-plugin docker-compose-plugin)

# ------------------------------- 输出函数 -------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;36m'; C_END=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_END=""
fi
info() { echo -e "${C_BLUE}[INFO]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_END} $*"; }
err()  { echo -e "${C_RED}[FAIL]${C_END} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行（sudo bash $0 ...）"; }

# ------------------------------- 帮助 -----------------------------------------
usage() {
  cat <<EOF
用法: $(basename "$0") <子命令> [选项]

子命令:
  install      安装 Docker（默认，可省略）
  configure    只重新生成 daemon.json 并重启 docker
  status       查看服务状态 / 版本 / 关键信息
  start|stop|restart   常规启停
  info         打印 docker info 关键项
  uninstall    卸载（--purge 同时删除数据）

选项:
  --version VER              指定 docker-ce 版本，如 26.1.4
  --repo aliyun|official|URL 仓库，默认 aliyun
  --mirror "u1,u2"           镜像加速器（逗号分隔）
  --no-mirror                不配置镜像加速
  --data-root DIR            存储目录，默认 ${DATA_ROOT}
  --dns "ip1,ip2"            DNS，默认 ${DNS_SERVERS[*]}
  --insecure-registry ADDR   信任的 HTTP 仓库，可重复
  --user NAME                把用户加入 docker 组
  --no-start / --no-test     不启动 / 不跑 hello-world
  --skip-time                跳过时间同步
  --keep-daemon              保留已有 daemon.json
  -f, --force                强制重装
  --purge                    卸载时删数据
  -h, --help                 本帮助

示例:
  $(basename "$0") install
  $(basename "$0") install --version 26.1.4 --data-root /var/lib/docker
  $(basename "$0") install --mirror "https://<你的ID>.mirror.aliyuncs.com"
  $(basename "$0") install --insecure-registry 192.168.83.140:5000
  $(basename "$0") configure --no-mirror
  $(basename "$0") uninstall --purge
EOF
}

# ------------------------------- 参数解析 -------------------------------------
parse_args() {
  # 缺省子命令为 install：不带参数，或只跟选项时都按安装处理
  SUB="install"
  if [ $# -gt 0 ]; then
    case "$1" in
      install|configure|status|start|stop|restart|info|uninstall) SUB="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) : ;;                      # 只有选项，默认 install
      *) usage; die "未知子命令: $1" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --version)            DOCKER_VERSION="$2"; shift 2 ;;
      --repo)               REPO="$2"; shift 2 ;;
      --mirror)             IFS=',' read -r -a MIRRORS <<< "$2"; shift 2 ;;
      --no-mirror)          MIRRORS=(); shift ;;
      --data-root)          DATA_ROOT="$2"; shift 2 ;;
      --dns)                IFS=',' read -r -a DNS_SERVERS <<< "$2"; shift 2 ;;
      --insecure-registry)  INSECURE_REGISTRIES+=("$2"); shift 2 ;;
      --user)               DOCKER_USER="$2"; shift 2 ;;
      --no-start)           DO_START=0; shift ;;
      --no-test)            DO_TEST=0; shift ;;
      --skip-time)          DO_TIME=0; shift ;;
      --keep-daemon)        KEEP_DAEMON=1; shift ;;
      -f|--force)           FORCE=1; shift ;;
      --purge)              PURGE=1; shift ;;
      -h|--help)            usage; exit 0 ;;
      *) usage; die "未知参数: $1" ;;
    esac
  done
}

# ------------------------------- 环境检查 -------------------------------------
pkg() { if have dnf; then echo dnf; else echo yum; fi; }

check_os() {
  [ -f /etc/os-release ] || die "无法识别系统（缺少 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    centos|rhel|rocky|almalinux|ol) ;;
    *) warn "当前系统 ID=${ID:-unknown}，脚本按 RHEL 系处理" ;;
  esac
  info "系统: ${PRETTY_NAME:-unknown} / $(uname -m)"

  local kv
  kv="$(uname -r | cut -d- -f1)"
  if [ "$(printf '%s\n' "$kv" "3.10" | sort -V | head -1)" != "3.10" ]; then
    warn "内核版本 ${kv} 低于 3.10，Docker CE 可能无法运行"
  fi
}

# ------------------------------- 时间同步 -------------------------------------
set_time() {
  [ "$DO_TIME" -eq 1 ] || { info "--skip-time，跳过时间同步"; return 0; }

  if have timedatectl; then
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null && ok "时区: $TIMEZONE" || warn "设置时区失败"
  else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone 2>/dev/null || true
    ok "时区: $TIMEZONE"
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^chronyd.service'; then
    systemctl enable chronyd >/dev/null 2>&1 || true
    systemctl restart chronyd >/dev/null 2>&1 || systemctl start chronyd >/dev/null 2>&1 || true
    ok "已启用 chronyd 时间同步"
  else
    info "安装 ntpdate 校时: $NTP_SERVER"
    $(pkg) install -y ntpdate >/dev/null 2>&1 || warn "ntpdate 安装失败（不影响 Docker 安装）"
    ntpdate "$NTP_SERVER" >/dev/null 2>&1 && ok "时间已同步" || warn "ntpdate 校时失败（不影响后续）"
  fi
}

# ------------------------------- 内核参数 -------------------------------------
setup_sysctl() {
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  if [ -f "$SYSCTL_FILE" ] && grep -q '^net.ipv4.ip_forward' "$SYSCTL_FILE"; then
    sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL_FILE"
  else
    echo 'net.ipv4.ip_forward = 1' >> "$SYSCTL_FILE"
  fi
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  # 兼容老系统：/etc/sysctl.conf 里若有明确的 0，也改掉
  if grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*0' /etc/sysctl.conf 2>/dev/null; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
  fi

  local v
  v="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  [ "$v" = "1" ] && ok "net.ipv4.ip_forward=1（容器可访问外网）" || die "ip_forward 仍为 $v，请检查 /etc/sysctl.conf 与内核参数"
}

# ------------------------------- 旧版本清理 -----------------------------------
remove_legacy() {
  local pm; pm="$(pkg)"
  local installed=()
  local p
  for p in $LEGACY_PKGS; do
    rpm -q "$p" >/dev/null 2>&1 && installed+=("$p")
  done
  if [ ${#installed[@]} -gt 0 ]; then
    info "卸载旧版本: ${installed[*]}"
    $pm remove -y "${installed[@]}" >/dev/null 2>&1 || warn "旧版本卸载有残留，可忽略"
    ok "旧版本已清理"
  else
    ok "无旧版本 docker 冲突"
  fi

  if [ "$FORCE" -eq 1 ] && rpm -q docker-ce >/dev/null 2>&1; then
    warn "--force：移除已安装的 docker-ce（镜像数据保留在 data-root）"
    $pm remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
  fi
}

# ------------------------------- 仓库 -----------------------------------------
repo_base() {
  case "$REPO" in
    aliyun)   echo "https://mirrors.aliyun.com/docker-ce/linux/centos" ;;
    official) echo "https://download.docker.com/linux/centos" ;;
    *)        echo "${REPO%/}" ;;
  esac
}

add_repo() {
  local pm; pm="$(pkg)"
  info "安装仓库工具"
  if [ "$pm" = "dnf" ]; then
    $pm install -y dnf-plugins-core >/dev/null 2>&1 || warn "dnf-plugins-core 安装失败"
  else
    $pm install -y yum-utils >/dev/null 2>&1 || warn "yum-utils 安装失败"
  fi

  local base; base="$(repo_base)"
  if [ -f "$REPO_FILE" ]; then
    cp -a "$REPO_FILE" "${REPO_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$REPO_FILE" <<EOF
# 由 docker-install.sh 生成（$REPO）
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=${base}/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=${base}/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo \$basearch
baseurl=${base}/\$releasever/debug-\$basearch/stable
enabled=0
gpgcheck=1
gpgkey=${base}/gpg
EOF
  ok "仓库文件: $REPO_FILE（${base}）"

  $pm clean all >/dev/null 2>&1 || true
  if ! $pm makecache >/dev/null 2>&1; then
    warn "yum makecache 失败（常见原因：其它 yum 源失效，或镜像没有该 releasever 目录）"
    [ "$REPO" = "aliyun" ] && warn "可改用官方源重试：$(basename "$0") install --repo official"
    warn "继续尝试安装，若下载失败请先修好 /etc/yum.repos.d/ 下的源"
  else
    ok "yum 缓存已刷新"
  fi
}

# ------------------------------- 安装 -----------------------------------------
install_docker() {
  local pm; pm="$(pkg)"

  if [ -n "$DOCKER_VERSION" ]; then
    info "安装指定版本 docker-ce ${DOCKER_VERSION}"
    if ! $pm install -y --setopt=obsoletes=0 \
         "docker-ce-${DOCKER_VERSION}" "docker-ce-cli-${DOCKER_VERSION}" containerd.io; then
      err "指定版本安装失败，仓库中可用版本（部分）："
      $pm list docker-ce --showduplicates 2>/dev/null | sort -r | head -12 | sed 's/^/    /'
      die "请换一个 --version 再试"
    fi
  else
    info "安装最新版 ${CORE_PKGS[*]}"
    $pm install -y "${CORE_PKGS[@]}" || die "docker-ce 核心包安装失败"
  fi

  info "安装插件 ${PLUGIN_PKGS[*]}"
  if ! $pm install -y "${PLUGIN_PKGS[@]}"; then
    warn "插件安装失败（常见于镜像缺少对应 el7 包），尝试手动下载 compose 插件"
    local url="https://mirrors.aliyun.com/docker-ce/linux/centos/7.0/x86_64/stable/Packages/docker-compose-plugin-2.27.1-1.el7.x86_64.rpm"
    local rpmfile="/tmp/docker-compose-plugin.rpm"
    if have curl && curl -fsSL --max-time 60 "$url" -o "$rpmfile"; then
      rpm -ivh "$rpmfile" && ok "docker-compose-plugin 手动安装成功" || warn "compose 插件未装好，docker compose 暂不可用"
    else
      warn "compose 插件未安装，dockerd 本身不受影响；需要时手动装 docker-compose-plugin"
    fi
  fi

  ok "Docker 组件安装完成: $(docker --version 2>/dev/null || echo 'docker-ce')"
}

# ------------------------------- daemon.json ---------------------------------
json_valid() {
  local f="$1"
  # 优先用 python 严格校验；python3 可能是 Windows/WSL 的空壳，失败再退回 python
  if have python3 && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
    return 0
  fi
  if have python && python -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
    return 0
  fi
  # 两者都不可用时的基本结构检查（首行 {、末行 }）
  grep -q '^{' "$f" && grep -q '}$' "$f"
}

write_daemon() {
  mkdir -p /etc/docker

  if [ -f "$DAEMON_JSON" ] && [ "$KEEP_DAEMON" -eq 1 ] && [ "$SUB" != "configure" ]; then
    info "--keep-daemon：保留已有 $DAEMON_JSON"
    return 0
  fi
  local bak=""
  if [ -f "$DAEMON_JSON" ]; then
    bak="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$DAEMON_JSON" "$bak"
    info "已备份原 daemon.json → $bak"
  fi

  local fields=() i ml ir
  fields+=("\"data-root\": \"${DATA_ROOT%/}\"")

  if [ ${#MIRRORS[@]} -gt 0 ]; then
    ml=""
    for i in "${MIRRORS[@]}"; do
      [ -z "$i" ] && continue
      [ -n "$ml" ] && ml="${ml}, "
      ml="${ml}\"${i}\""
    done
    [ -n "$ml" ] && fields+=("\"registry-mirrors\": [${ml}]")
  fi

  if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
    local dl="" d
    for d in "${DNS_SERVERS[@]}"; do
      [ -z "$d" ] && continue
      [ -n "$dl" ] && dl="${dl}, "
      dl="${dl}\"${d}\""
    done
    [ -n "$dl" ] && fields+=("\"dns\": [${dl}]")
  fi

  if [ ${#INSECURE_REGISTRIES[@]} -gt 0 ]; then
    ir=""
    for i in "${INSECURE_REGISTRIES[@]}"; do
      [ -n "$ir" ] && ir="${ir}, "
      ir="${ir}\"${i}\""
    done
    fields+=("\"insecure-registries\": [${ir}]")
  fi

  fields+=("\"experimental\": false")
  fields+=("\"live-restore\": true")
  fields+=("\"log-driver\": \"json-file\"")
  fields+=("\"log-opts\": {\"max-size\": \"100m\", \"max-file\": \"3\"}")

  {
    echo "{"
    local n=${#fields[@]} k=0 f
    for f in "${fields[@]}"; do
      k=$((k + 1))
      if [ "$k" -lt "$n" ]; then
        echo "  ${f},"
      else
        echo "  ${f}"
      fi
    done
    echo "}"
  } > "$DAEMON_JSON"
  chmod 644 "$DAEMON_JSON"

  if ! json_valid "$DAEMON_JSON"; then
    err "daemon.json 不是合法 JSON，内容如下："
    cat "$DAEMON_JSON" >&2
    if [ -n "$bak" ] && [ -f "$bak" ]; then
      cp -a "$bak" "$DAEMON_JSON"
      warn "已回滚到备份 $bak"
    else
      rm -f "$DAEMON_JSON"
    fi
    die "请修正 daemon.json（JSON 格式错误会导致 docker 无法启动）"
  fi
  ok "daemon.json 已生成（JSON 校验通过）"

  mkdir -p "${DATA_ROOT%/}"
  ok "镜像存储目录: ${DATA_ROOT%/}"

  systemctl daemon-reload >/dev/null 2>&1 || true
}

# ------------------------------- 启动 -----------------------------------------
start_docker() {
  if [ "$DO_START" -eq 0 ]; then
    info "--no-start：跳过启动。手动启动: systemctl start docker"
    return 0
  fi

  systemctl enable docker >/dev/null 2>&1 || warn "设置开机自启失败"
  systemctl restart docker || {
    err "docker 启动失败，最近日志："
    journalctl -u docker -n 30 --no-pager 2>/dev/null || true
    die "请检查 daemon.json 与系统日志"
  }

  local i
  for i in $(seq 1 20); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 || die "docker 守护进程未就绪"
  ok "docker 已启动并设置开机自启"
}

# ------------------------------- 校验 -----------------------------------------
verify() {
  echo
  docker version --format '  客户端: {{.Client.Version}}' 2>/dev/null || true
  docker version --format '  服务端: {{.Server.Version}}' 2>/dev/null || true

  local root_dir driver
  root_dir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  driver="$(docker info --format '{{.Driver}}' 2>/dev/null || true)"
  echo "  存储驱动: ${driver:-未知}"
  echo "  数据目录: ${root_dir:-未知}"

  local mirrors
  # 优先用 --format（Docker 20.10+），老版本退回解析 docker info 文本
  mirrors="$(docker info --format '{{join .RegistryConfig.Mirrors " "}}' 2>/dev/null || true)"
  if [ -z "$mirrors" ]; then
    mirrors="$(docker info 2>/dev/null \
      | awk '/^Registry Mirrors:/{flag=1;next} flag&&/^ /{print $1;next} flag{exit}' \
      | tr '\n' ' ' || true)"
  fi
  [ -n "$mirrors" ] && echo "  镜像加速: ${mirrors}"

  if [ "$DO_TEST" -eq 1 ] && [ "$DO_START" -eq 1 ]; then
    info "拉取 hello-world 验证（失败只告警，不影响安装结果）"
    if timeout 180 docker run --rm hello-world >/tmp/docker-hello.log 2>&1; then
      ok "hello-world 运行成功，Docker 可用"
      rm -f /tmp/docker-hello.log
    else
      warn "hello-world 失败（多为镜像加速器不可用或网络问题），日志末尾："
      tail -n 5 /tmp/docker-hello.log 2>/dev/null | sed 's/^/    /'
      warn "排查：docker info 看 Registry Mirrors；换 --mirror 或改用阿里云 ACR 专属加速地址"
    fi
  fi
}

add_user_to_group() {
  [ -z "$DOCKER_USER" ] && return 0
  id "$DOCKER_USER" >/dev/null 2>&1 || { warn "用户 $DOCKER_USER 不存在，跳过 docker 组"; return 0; }
  groupadd -f docker
  usermod -aG docker "$DOCKER_USER"
  ok "已把 $DOCKER_USER 加入 docker 组（重新登录后生效）"
}

# ------------------------------- 子命令 ---------------------------------------
do_install() {
  require_root
  check_os
  set_time
  setup_sysctl
  remove_legacy
  add_repo
  install_docker
  write_daemon
  start_docker
  verify
  add_user_to_group
  echo
  echo "=================================================================="
  ok "Docker 安装完成"
  echo "  版本    : $(docker --version 2>/dev/null || echo '-')"
  echo "  数据目录: ${DATA_ROOT%/}"
  echo "  配置文件: $DAEMON_JSON"
  echo "  服务管理: systemctl {start|stop|restart|status} docker"
  if [ ${#MIRRORS[@]} -gt 0 ]; then
    echo "  镜像加速: ${MIRRORS[*]}"
  else
    echo "  镜像加速: 未配置"
  fi
  echo "=================================================================="
}

do_configure() {
  require_root
  write_daemon
  systemctl restart docker || die "docker 重启失败，检查 daemon.json"
  ok "已按新配置重启 docker"
  docker info 2>/dev/null | grep -E 'Docker Root Dir|Registry Mirrors|Storage Driver|Server Version' | sed 's/^/  /' || true
}

do_status() {
  systemctl status docker --no-pager -l 2>/dev/null | head -n 15 || true
  echo
  docker version 2>/dev/null || warn "docker 命令不可用"
  echo
  echo "数据目录: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '-')"
  echo "镜像数量: $(docker images -q 2>/dev/null | wc -l)"
  echo "容器数量: $(docker ps -aq 2>/dev/null | wc -l)（运行中 $(docker ps -q 2>/dev/null | wc -l)）"
}

do_info() {
  docker info 2>/dev/null | grep -E 'Server Version|Storage Driver|Cgroup Driver|Docker Root Dir|Registry Mirrors|Insecure Registries|Live Restore' || die "docker info 失败"
}

do_uninstall() {
  require_root
  info "停止并禁用 docker"
  systemctl stop docker docker.socket >/dev/null 2>&1 || true
  systemctl disable docker docker.socket >/dev/null 2>&1 || true

  local pm; pm="$(pkg)"
  info "卸载 docker 相关软件包"
  $pm remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    docker-compose-plugin docker-ce-rootless-extras >/dev/null 2>&1 || true
  ok "软件包已卸载"

  rm -rf /etc/docker
  rm -f "$REPO_FILE"
  ok "已删除 /etc/docker 与 $REPO_FILE"

  if [ "$PURGE" -eq 1 ]; then
    [ -n "${DATA_ROOT%/}" ] || die "DATA_ROOT 为空，拒绝删除"
    case "${DATA_ROOT%/}" in
      /|/usr|/etc|/var|/data|/home) die "拒绝删除危险路径: ${DATA_ROOT%/}" ;;
    esac
    rm -rf "${DATA_ROOT%/}" /var/lib/docker /var/lib/containerd
    ok "已删除镜像/容器数据: ${DATA_ROOT%/} /var/lib/docker /var/lib/containerd"
  else
    info "镜像/容器数据保留：${DATA_ROOT%/}、/var/lib/docker（--purge 可一并删除）"
  fi
  ok "卸载完成"
}

# ------------------------------- 主流程 ---------------------------------------
main() {
  parse_args "$@"
  case "$SUB" in
    install)     do_install ;;
    configure)   do_configure ;;
    status)      do_status ;;
    info)        do_info ;;
    start)       require_root; systemctl start docker || die "docker 启动失败，查看 journalctl -u docker"; ok "docker 已启动" ;;
    stop)        require_root; systemctl stop docker || die "docker 停止失败"; ok "docker 已停止" ;;
    restart)     require_root; systemctl restart docker || die "docker 重启失败，查看 journalctl -u docker"; ok "docker 已重启" ;;
    uninstall)   do_uninstall ;;
  esac
}

main "$@"
