#!/usr/bin/env bash
#
# ==============================================================================
#  zookeeper-install.sh
#  CentOS / RHEL / Rocky / AlmaLinux 一键安装 Apache ZooKeeper（默认 3.9.7）
#
#  说明: 文档《zookeeper集群配置》使用 3.9.4，本脚本默认装 3.9.x 最新补丁版 3.9.7
#        （配置参数与 3.9.4 完全一致，且阿里云镜像有货、下载快）。
#        需要与文档完全一致的 3.9.4: ./zookeeper-install.sh standalone -v 3.9.4
#
#  三种模式:
#    standalone  单机模式    —— 单节点，不写 server.X
#    cluster     集群模式    —— 多台机器各装一个节点（建议奇数个：3/5/7）
#    pseudo      伪集群模式  —— 单台机器起 3 个实例（2181/2182/2183），学习测试用
#
#  示例:
#    # 1) 单机
#    ./zookeeper-install.sh standalone
#
#    # 2) 集群（在 zk-2 上执行，其余节点同理，只改 --myid 和 --hostname）
#    ./zookeeper-install.sh cluster \
#        --myid 2 \
#        --servers "zk-1,zk-2,zk-3" \
#        --hosts "192.168.60.147=zk-1,192.168.60.133=zk-2,192.168.60.137=zk-3" \
#        --hostname zk-2
#
#    # 3) 伪集群（单机 3 实例）
#    ./zookeeper-install.sh pseudo --nodes 3
#
#    # 4) 离线安装（提前把 tar.gz 传到 /opt）
#    ./zookeeper-install.sh standalone --pkg /opt/apache-zookeeper-3.9.7-bin.tar.gz
#
#    # 5) 卸载
#    ./zookeeper-install.sh uninstall          # 保留数据
#    ./zookeeper-install.sh uninstall --purge  # 连数据一起删
# ==============================================================================

set -euo pipefail

# ------------------------------- 默认变量 -------------------------------------
ZK_VERSION="3.9.7"
ZK_PKG_NAME="apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
ZK_HOME="/usr/local/zookeeper"
ZK_DATA="/data/zookeeper"
ZK_LOG="/data/zookeeper/logs"
SERVICE_FILE="/etc/systemd/system/zookeeper.service"
PROFILE_FILE="/etc/profile.d/zookeeper.sh"
MANAGED_MARK=".managed-by-zookeeper-install.sh"

MODE=""
MYID=""
SERVERS=""
HOSTS=""
HOSTNAME_SET=""
CLIENT_PORT=2181
QUORUM_PORT=2888
ELECTION_PORT=3888
FIREWALL="open"        # open | stop | skip
DO_START=1
INSTALL_JDK=1
PKG_PATH=""
FORCE=0
PURGE=0
VERSION_EXPLICIT=0
PSEUDO_NODES=3
JAVA_HOME_DETECTED=""

# ------------------------------- 日志函数 -------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_OFF=""
fi

info()  { echo "${C_BLUE}[INFO ]${C_OFF} $*"; }
ok()    { echo "${C_GREEN}[ OK  ]${C_OFF} $*"; }
warn()  { echo "${C_YELLOW}[WARN ]${C_OFF} $*"; }
err()   { echo "${C_RED}[ERROR]${C_OFF} $*" >&2; }
die()   { err "$*"; exit 1; }

# ------------------------------- 帮助信息 -------------------------------------
usage() {
  cat <<EOF
用法: $(basename "$0") <模式> [选项]

模式:
  standalone        单机模式安装
  cluster           集群模式安装（每个节点执行一次）
  pseudo            伪集群模式（单机多实例，学习/测试）
  uninstall         卸载

通用选项:
  -v, --version VER     ZooKeeper 版本，默认 ${ZK_VERSION}
                        （文档为 3.9.4，需要时用 -v 3.9.4；镜像上仅保留较新版本）
      --pkg FILE        使用本地已有的 tar.gz（离线安装）
      --client-port P   客户端端口，默认 ${CLIENT_PORT}
      --firewall MODE   open(默认开放端口) | stop(关闭防火墙) | skip(不动防火墙)
      --no-start        安装后不自动启动
      --no-jdk          不自动安装 JDK（要求系统已装 java）
      --jdk-home PATH   指定已有 JAVA_HOME（如 /usr/local/jdk）
      --jdk-tar FILE    解压指定 JDK tar.gz 到 /usr/local 并做 jdk 软链
      --hosts LIST      "ip=主机名,ip=主机名" 追加到 /etc/hosts（已存在则跳过）
      --hostname NAME   安装前设置本机主机名
  -f, --force           已存在安装时强制重装
  -h, --help            显示本帮助

集群选项（cluster 模式必填）:
      --myid N          本节点编号（1~N，需与 --servers 顺序对应）
      --servers LIST    "zk-1,zk-2,zk-3" 或 "zk-1:2888:3888,zk-2:2888:3888,..."

伪集群选项:
      --nodes N         实例个数，默认 ${PSEUDO_NODES}

卸载选项:
      --purge           同时删除数据目录 ${ZK_DATA}

示例:
  $(basename "$0") standalone
  $(basename "$0") cluster --myid 1 --servers "zk-1,zk-2,zk-3" --hosts "192.168.60.147=zk-1,192.168.60.133=zk-2,192.168.60.137=zk-3"
  $(basename "$0") pseudo --nodes 3
EOF
}

# ------------------------------- 参数解析 -------------------------------------
parse_args() {
  [ $# -eq 0 ] && { usage; exit 1; }

  case "$1" in
    standalone|cluster|pseudo|uninstall) MODE="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知模式: $1" ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--version)    ZK_VERSION="$2"; ZK_PKG_NAME="apache-zookeeper-${ZK_VERSION}-bin.tar.gz"; VERSION_EXPLICIT=1; shift 2 ;;
      --pkg)           PKG_PATH="$2"; shift 2 ;;
      --myid)          MYID="$2"; shift 2 ;;
      --servers)       SERVERS="$2"; shift 2 ;;
      --hosts)         HOSTS="$2"; shift 2 ;;
      --hostname)      HOSTNAME_SET="$2"; shift 2 ;;
      --client-port)   CLIENT_PORT="$2"; shift 2 ;;
      --firewall)      FIREWALL="$2"; shift 2 ;;
      --nodes)         PSEUDO_NODES="$2"; shift 2 ;;
      --jdk-home)      JAVA_HOME_DETECTED="$2"; shift 2 ;;
      --jdk-tar)       JDK_TAR="$2"; shift 2 ;;
      --no-start)      DO_START=0; shift ;;
      --no-jdk)        INSTALL_JDK=0; shift ;;
      -f|--force)      FORCE=1; shift ;;
      --purge)         PURGE=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *) usage; die "未知参数: $1" ;;
    esac
  done

  case "$FIREWALL" in
    open|stop|skip) ;;
    *) die "--firewall 只能是 open / stop / skip" ;;
  esac
}

# ------------------------------- 基础检查 -------------------------------------
require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 执行（或 sudo）"
}

check_os() {
  [ -f /etc/os-release ] || die "无法识别操作系统（缺少 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    centos|rhel|rocky|almalinux|ol|fedora) ;;
    *) warn "当前系统 ID=${ID:-unknown}，脚本按 RHEL 系处理，可能不适用" ;;
  esac
  info "系统: ${PRETTY_NAME:-unknown} / $(uname -m)"
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "非 x86_64/aarch64 架构，官方 tar.gz 可能不匹配" ;;
  esac
}

pkg_cmd() {
  if command -v dnf >/dev/null 2>&1; then echo dnf; else echo yum; fi
}

install_deps() {
  local pm; pm="$(pkg_cmd)"
  info "安装依赖: tar wget nc($pm)"
  $pm install -y tar wget nc >/dev/null 2>&1 || {
    warn "依赖安装失败，尝试继续（若缺 wget/nc 请手动安装）"
  }
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else
    return 1
  fi
}

# AdminServer(3.5+ 自带) 端口若被占用会导致 ZK 启动失败，这里自动避让
ADMIN_PORTS_USED=""
pick_admin_port() {
  local start="${1:-8080}" p max
  p="$start"; max=$((start + 100))
  local u used
  while [ "$p" -le "$max" ]; do
    used=0
    for u in ${ADMIN_PORTS_USED:-}; do
      [ "$u" = "$p" ] && used=1
    done
    if [ "$used" -eq 0 ] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "$start"
}

# ------------------------------- Java 处理 ------------------------------------
ensure_java() {
  # 1) 显式指定 --jdk-home
  if [ -n "$JAVA_HOME_DETECTED" ]; then
    [ -x "$JAVA_HOME_DETECTED/bin/java" ] || die "--jdk-home 下找不到 bin/java: $JAVA_HOME_DETECTED"
    ok "使用指定 JAVA_HOME: $JAVA_HOME_DETECTED"
    return 0
  fi

  # 2) 从 --jdk-tar 安装
  if [ -n "${JDK_TAR:-}" ]; then
    [ -f "$JDK_TAR" ] || die "--jdk-tar 文件不存在: $JDK_TAR"
    info "解压 JDK: $JDK_TAR"
    tar -zxf "$JDK_TAR" -C /usr/local/
    local jdkdir
    jdkdir="$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)"
    [ -n "$jdkdir" ] || die "无法识别 JDK 包内目录"
    [ -e /usr/local/jdk ] || ln -sfn "/usr/local/$jdkdir" /usr/local/jdk
    JAVA_HOME_DETECTED="/usr/local/jdk"
    ok "JDK 安装到 /usr/local/$jdkdir，软链 /usr/local/jdk"
    return 0
  fi

  # 3) 已有环境变量
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    JAVA_HOME_DETECTED="$JAVA_HOME"
    ok "检测到 JAVA_HOME=$JAVA_HOME"
    return 0
  fi

  # 4) /usr/local/jdk 软链（文档中的方式）
  if [ -x /usr/local/jdk/bin/java ]; then
    JAVA_HOME_DETECTED="/usr/local/jdk"
    ok "检测到 /usr/local/jdk"
    return 0
  fi

  # 5) PATH 里的 java
  if command -v java >/dev/null 2>&1; then
    local real
    real="$(readlink -f "$(command -v java)")"
    JAVA_HOME_DETECTED="$(dirname "$(dirname "$real")")"
    ok "从 PATH 推断 JAVA_HOME=$JAVA_HOME_DETECTED"
    return 0
  fi

  # 6) 自动 yum 安装 JDK
  if [ "$INSTALL_JDK" -eq 1 ]; then
    local pm; pm="$(pkg_cmd)"
    warn "未检测到 Java，尝试 $pm 安装 OpenJDK 8 ..."
    if ! $pm install -y java-1.8.0-openjdk-devel >/dev/null 2>&1; then
      warn "OpenJDK 8 安装失败，尝试 OpenJDK 11"
      $pm install -y java-11-openjdk-devel >/dev/null 2>&1 || die "JDK 安装失败，请手动安装后重跑（或加 --jdk-home）"
    fi
    command -v java >/dev/null 2>&1 || die "JDK 安装后仍找不到 java"
    local real
    real="$(readlink -f "$(command -v java)")"
    JAVA_HOME_DETECTED="$(dirname "$(dirname "$real")")"
    ok "已安装 OpenJDK，JAVA_HOME=$JAVA_HOME_DETECTED"
    return 0
  fi

  die "未检测到 Java。请安装 JDK 或加 --jdk-home / --jdk-tar 参数"
}

# ------------------------------- 下载 & 解压 ----------------------------------
aliyun_versions() {
  # 列出阿里云 apache/zookeeper 下可用版本（按版本号排序）
  local html
  html="$(wget -qO- --timeout=20 "https://mirrors.aliyun.com/apache/zookeeper/" 2>/dev/null \
          || curl -fsS --max-time 20 "https://mirrors.aliyun.com/apache/zookeeper/" 2>/dev/null \
          || true)"
  echo "$html" | grep -oE 'zookeeper-[0-9]+\.[0-9]+\.[0-9]+/' \
    | sed -e 's|^zookeeper-||' -e 's|/$||' | sort -V -u
}

try_download_version() {
  local v="$1"
  local pkg="apache-zookeeper-${v}-bin.tar.gz"
  local mirrors=(
    "https://mirrors.aliyun.com/apache/zookeeper/zookeeper-${v}/${pkg}"
    "https://archive.apache.org/dist/zookeeper/zookeeper-${v}/${pkg}"
    "https://mirrors.tuna.tsinghua.edu.cn/apache/zookeeper/zookeeper-${v}/${pkg}"
  )
  local u
  for u in "${mirrors[@]}"; do
    info "下载: $u"
    if wget -c -T 20 -t 1 -q --show-progress "$u" -O "$pkg"; then
      if tar -tzf "$pkg" >/dev/null 2>&1; then
        ok "下载完成: /opt/$pkg"
        ZK_VERSION="$v"
        ZK_PKG_NAME="$pkg"
        return 0
      fi
      warn "文件不完整，换下一个镜像"
    fi
    rm -f "$pkg"   # 清理失败/半截文件，避免下次误判
  done
  return 1
}

download_zk() {
  if [ -n "$PKG_PATH" ]; then
    [ -f "$PKG_PATH" ] || die "--pkg 文件不存在: $PKG_PATH"
    PKG_PATH="$(readlink -f "$PKG_PATH")"
    ok "使用本地安装包: $PKG_PATH"
    return 0
  fi

  mkdir -p /opt
  cd /opt
  if [ -f "$ZK_PKG_NAME" ] && tar -tzf "$ZK_PKG_NAME" >/dev/null 2>&1; then
    ok "已存在可用安装包 /opt/$ZK_PKG_NAME，跳过下载"
    return 0
  fi

  if try_download_version "$ZK_VERSION"; then
    return 0
  fi

  # 未显式指定版本时，回退到国内镜像上实际可用的 3.9.x 版本
  if [ "$VERSION_EXPLICIT" -eq 0 ]; then
    local avail latest
    avail="$(aliyun_versions || true)"
    latest="$(echo "$avail" | grep -E '^3\.9\.' | tail -1)"
    [ -z "$latest" ] && latest="$(echo "$avail" | grep -E '^3\.' | tail -1)"
    if [ -n "$latest" ] && [ "$latest" != "$ZK_VERSION" ]; then
      warn "版本 ${ZK_VERSION} 在镜像上不可用，回退到阿里云可用版本 ${latest}"
      if try_download_version "$latest"; then
        return 0
      fi
    fi
  fi

  err "所有镜像下载失败。可手动下载后用 --pkg 指定文件，例如："
  err "  wget https://archive.apache.org/dist/zookeeper/zookeeper-${ZK_VERSION}/${ZK_PKG_NAME}"
  [ -n "$(aliyun_versions 2>/dev/null || true)" ] && \
    warn "阿里云镜像当前可用版本: $(aliyun_versions | tr '\n' ' ')"
  die "安装包获取失败"
}

install_zk_files() {
  local src="/opt/${ZK_PKG_NAME}"
  [ -n "$PKG_PATH" ] && src="$PKG_PATH"

  if [ -x "$ZK_HOME/bin/zkServer.sh" ] && [ "$FORCE" -eq 0 ]; then
    ok "$ZK_HOME 已安装，跳过解压（--force 可重装）"
    return 0
  fi

  if [ -d "$ZK_HOME" ]; then
    local bak="${ZK_HOME}.bak.$(date +%Y%m%d%H%M%S)"
    warn "$ZK_HOME 已存在，备份为 $bak"
    mv "$ZK_HOME" "$bak"
  fi

  info "解压: $src"
  tar -zxf "$src" -C /usr/local/
  local dir="/usr/local/apache-zookeeper-${ZK_VERSION}-bin"
  [ -d "$dir" ] || die "解压后未找到目录 $dir（检查版本号是否与包名一致）"
  mv "$dir" "$ZK_HOME"
  chmod +x "$ZK_HOME/bin/"*.sh
  touch "$ZK_HOME/$MANAGED_MARK"
  ok "ZooKeeper 安装到 $ZK_HOME"

  # 文档里的 conf/zoo_sample.cfg 保留，zoo.cfg 由本脚本生成
  [ -f "$ZK_HOME/conf/zoo_sample.cfg" ] || true
}

write_profile() {
  info "写入环境变量: $PROFILE_FILE"
  cat > "$PROFILE_FILE" <<EOF
# 由 zookeeper-install.sh 生成
export JAVA_HOME="${JAVA_HOME_DETECTED}"
export ZOOKEEPER_HOME="${ZK_HOME}"
export PATH="\$PATH:\$JAVA_HOME/bin:\$ZOOKEEPER_HOME/bin"
EOF
  chmod +x "$PROFILE_FILE"
  export JAVA_HOME="$JAVA_HOME_DETECTED"
}

# ------------------------------- 主机相关 -------------------------------------
setup_hostname() {
  [ -z "$HOSTNAME_SET" ] && return 0
  local cur; cur="$(hostname 2>/dev/null || echo "")"
  if [ "$cur" = "$HOSTNAME_SET" ]; then
    ok "主机名已是 $HOSTNAME_SET"
  elif command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$HOSTNAME_SET"
    ok "主机名设置为 $HOSTNAME_SET"
  else
    echo "$HOSTNAME_SET" > /etc/hostname
    hostname "$HOSTNAME_SET"
    ok "主机名设置为 $HOSTNAME_SET（需重新登录生效）"
  fi
}

setup_hosts() {
  [ -z "$HOSTS" ] && return 0
  local IFS=','
  local item ip name
  info "维护 /etc/hosts"
  for item in $HOSTS; do
    item="${item// /}"
    [ -z "$item" ] && continue
    [ "${item#*=}" = "$item" ] && { warn "hosts 项格式应为 ip=主机名，忽略: $item"; continue; }
    ip="${item%%=*}"
    name="${item#*=}"
    if grep -qE "^[[:space:]]*${ip//./\\.}[[:space:]]+.*[[:space:]]${name}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
      ok "/etc/hosts 已存在 $ip $name"
    elif grep -qE "^[[:space:]]*${ip//./\\.}[[:space:]]" /etc/hosts 2>/dev/null; then
      warn "/etc/hosts 中 $ip 已有其它映射，跳过（请手工检查）"
    else
      echo "$ip $name" >> /etc/hosts
      ok "追加 /etc/hosts: $ip $name"
    fi
  done
}

# ------------------------------- 防火墙 ---------------------------------------
firewall_setup() {
  local ports=("$@")
  [ "$FIREWALL" = "skip" ] && { info "--firewall skip，跳过防火墙配置"; return 0; }

  if [ "$FIREWALL" = "stop" ]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop firewalld >/dev/null 2>&1 || true
      systemctl disable firewalld >/dev/null 2>&1 || true
      ok "已停止并禁用 firewalld（测试环境做法）"
    fi
    return 0
  fi

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    info "未安装 firewalld，跳过端口开放"
    return 0
  fi
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld 未运行，无需开放端口"
    return 0
  fi

  local p
  for p in "${ports[@]}"; do
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    ok "firewalld 开放 ${p}/tcp"
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
}

# ------------------------------- 配置生成 -------------------------------------
mkdir_data_dirs() {
  mkdir -p "$ZK_DATA" "$ZK_LOG"
  chmod 755 "$ZK_DATA" "$ZK_LOG"
}

backup_cfg() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份原配置: ${f}.bak.*"
  fi
}

write_cfg_standalone() {
  mkdir_data_dirs
  backup_cfg "$ZK_HOME/conf/zoo.cfg"
  ADMIN_PORT="$(pick_admin_port 8080)"
  ADMIN_PORTS_USED="$ADMIN_PORTS_USED $ADMIN_PORT"
  info "生成单机配置 $ZK_HOME/conf/zoo.cfg"
  cat > "$ZK_HOME/conf/zoo.cfg" <<EOF
# ZooKeeper standalone —— 由 zookeeper-install.sh 生成
# 心跳时间（毫秒）
tickTime=2000

# 初始化连接超时（10 个心跳）
initLimit=10

# 同步超时（5 个心跳）
syncLimit=5

# 数据目录
dataDir=${ZK_DATA}

# 客户端连接端口
clientPort=${CLIENT_PORT}

# 最大客户端连接数
maxClientCnxns=60

# 自动清理快照（保留 3 个，24 小时清理一次）
autopurge.snapRetainCount=3
autopurge.purgeInterval=24

# AdminServer 端口（3.5+ 自带；脚本已自动避开占用）
admin.serverPort=${ADMIN_PORT}

# 4 字母命令白名单（ruok/stat/conf 监控用；生产可收紧为具体命令）
4lw.commands.whitelist=*

# 注意：单机模式不要写 server.X，否则会当作集群启动而失败
EOF

  # 单机模式清理可能残留的 myid，避免误判为集群节点
  if [ -f "$ZK_DATA/myid" ]; then
    warn "检测到残留 myid，单机模式已备份并移除"
    mv "$ZK_DATA/myid" "$ZK_DATA/myid.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

server_lines() {
  local IFS=','
  local item i=0
  for item in $SERVERS; do
    item="${item// /}"
    [ -z "$item" ] && continue
    i=$((i + 1))
    if [[ "$item" == *:* ]]; then
      echo "server.${i}=${item}"
    else
      echo "server.${i}=${item}:${QUORUM_PORT}:${ELECTION_PORT}"
    fi
  done
}

count_servers() {
  local IFS=','
  local item n=0
  for item in $SERVERS; do
    item="${item// /}"
    [ -n "$item" ] && n=$((n + 1))
  done
  echo "$n"
}

write_cfg_cluster() {
  [ -n "$MYID" ] || die "cluster 模式必须指定 --myid"
  [[ "$MYID" =~ ^[0-9]+$ ]] || die "--myid 必须是数字"
  [ -n "$SERVERS" ] || die "cluster 模式必须指定 --servers"

  local total; total="$(count_servers)"
  [ "$total" -ge 1 ] || die "--servers 解析结果为空"
  if [ "$MYID" -lt 1 ] || [ "$MYID" -gt "$total" ]; then
    die "--myid=$MYID 超出范围（--servers 共 $total 个节点，myid 应为 1~$total）"
  fi
  if [ $((total % 2)) -eq 0 ]; then
    warn "节点数为偶数($total)，生产环境建议奇数（3/5/7）以避免脑裂"
  fi

  mkdir_data_dirs
  backup_cfg "$ZK_HOME/conf/zoo.cfg"
  ADMIN_PORT="$(pick_admin_port 8080)"
  ADMIN_PORTS_USED="$ADMIN_PORTS_USED $ADMIN_PORT"

  info "生成集群配置 $ZK_HOME/conf/zoo.cfg（本节点 myid=$MYID，共 $total 节点）"
  {
    cat <<EOF
# ZooKeeper ensemble —— 由 zookeeper-install.sh 生成
tickTime=2000
initLimit=10
syncLimit=5

# 数据目录
dataDir=${ZK_DATA}

# 客户端端口
clientPort=${CLIENT_PORT}
maxClientCnxns=300

# 自动清理
autopurge.snapRetainCount=3
autopurge.purgeInterval=24

# AdminServer 端口（脚本已自动避开占用）
admin.serverPort=${ADMIN_PORT}

# 集群配置（关键部分）
# server.myid=hostname:quorumPort:leaderElectionPort
EOF
    server_lines
    cat <<EOF

# 4 字母命令白名单（用于监控）
4lw.commands.whitelist=*
EOF
  } > "$ZK_HOME/conf/zoo.cfg"

  echo "$MYID" > "$ZK_DATA/myid"
  ok "写入 $ZK_DATA/myid = $MYID"

  local myhost
  myhost="$(echo "$SERVERS" | tr ',' '\n' | sed -n "${MYID}p" | cut -d: -f1 | tr -d ' ')"
  if [ -n "$myhost" ] && [ "$myhost" != "$(hostname 2>/dev/null)" ] && [ "$myhost" != "$(hostname -s 2>/dev/null)" ]; then
    warn "本机主机名是 '$(hostname)'，而 server.${MYID} 指向 '${myhost}'，请确认 --hosts 映射或 --hostname 是否正确"
  fi
}

# ------------------------------- systemd --------------------------------------
write_systemd() {
  local desc="$1"
  info "生成 systemd 服务: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${desc}
After=network.target
Wants=network-online.target

[Service]
Type=forking
User=root
Group=root
Environment="JAVA_HOME=${JAVA_HOME_DETECTED}"
Environment="ZOO_LOG_DIR=${ZK_LOG}"
ExecStart=${ZK_HOME}/bin/zkServer.sh start
ExecStop=${ZK_HOME}/bin/zkServer.sh stop
ExecReload=${ZK_HOME}/bin/zkServer.sh restart
Restart=on-failure
RestartSec=5
SuccessExitStatus=0 143
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable zookeeper >/dev/null 2>&1
  ok "已设置开机自启"
}

# ------------------------------- 启动 & 校验 ----------------------------------
zk_ruok() {
  local port="$1" resp=""
  if command -v nc >/dev/null 2>&1; then
    resp="$(printf 'ruok' | nc -w 2 127.0.0.1 "$port" 2>/dev/null || true)"
  else
    exec 3<>"/dev/tcp/127.0.0.1/${port}" 2>/dev/null || return 1
    printf 'ruok' >&3
    IFS= read -r -t 3 resp <&3 || true
    exec 3<&- 2>/dev/null || true
  fi
  [ "$resp" = "imok" ]
}

zk_mode() {
  "$ZK_HOME/bin/zkServer.sh" status 2>/dev/null | grep -oE 'Mode: (standalone|leader|follower)' | awk '{print $2}' || true
}

wait_ready() {
  local want="$1" i
  for i in $(seq 1 30); do
    local m; m="$(zk_mode)"
    if [ -n "$m" ]; then
      if [ "$want" = "cluster" ]; then
        if [ "$m" = "leader" ] || [ "$m" = "follower" ]; then ok "节点已就绪，Mode: $m"; return 0; fi
      else
        if [ "$m" = "standalone" ]; then ok "节点已就绪，Mode: $m"; return 0; fi
      fi
    fi
    sleep 1
  done
  return 1
}

start_and_verify() {
  local kind="$1"
  if [ "$DO_START" -eq 0 ]; then
    info "--no-start 已指定，跳过启动。手动启动: systemctl start zookeeper"
    return 0
  fi

  info "启动 ZooKeeper ..."
  if systemctl is-active --quiet zookeeper 2>/dev/null; then
    info "服务已在运行，执行重启以加载新配置"
    systemctl restart zookeeper || true
  else
    systemctl start zookeeper || true
  fi

  sleep 3
  if ! systemctl is-active --quiet zookeeper 2>/dev/null; then
    err "服务未启动成功，最近日志："
    tail -n 40 "$ZK_LOG"/zookeeper-*.out 2>/dev/null || tail -n 40 "$ZK_HOME/logs"/*.out 2>/dev/null || true
    journalctl -u zookeeper -n 30 --no-pager 2>/dev/null || true
    return 1
  fi

  if wait_ready "$kind"; then
    if zk_ruok "$CLIENT_PORT"; then ok "ruok 探测正常（${CLIENT_PORT}）"; else warn "ruok 未返回 imok（4lw 白名单或端口问题），可用 zkServer.sh status 复查"; fi
    return 0
  fi

  # 集群首次部署时，只启动第一个节点通常选不出 Leader（需要过半节点在线），属正常现象
  if [ "$kind" = "cluster" ] && zk_ruok "$CLIENT_PORT"; then
    warn "进程已运行，但尚无 Leader/Follower 角色（需多数节点在线才会选主）"
    warn "这是集群首次部署的正常现象：请继续在其它节点执行本脚本，全部启动后再验证"
    return 0
  fi

  warn "30 秒内未拿到 Mode 状态，请检查 myid / hosts / 防火墙 2888、3888"
  "$ZK_HOME/bin/zkServer.sh" status || true
  return 1
}

# ------------------------------- 三种模式 -------------------------------------
do_standalone() {
  info "==== 单机模式安装 ===="
  ensure_java
  install_deps
  download_zk
  install_zk_files
  write_profile
  setup_hostname
  setup_hosts
  write_cfg_standalone
  write_systemd "Apache ZooKeeper (standalone)"
  port_in_use "$CLIENT_PORT" && warn "客户端端口 $CLIENT_PORT 已被占用，如果不是本机旧 ZK 进程，请换 --client-port"
  local ports=("$CLIENT_PORT" "${ADMIN_PORT:-8080}")
  firewall_setup "${ports[@]}"
  start_and_verify standalone || exit 1
  print_summary standalone
}

do_cluster() {
  info "==== 集群模式安装 ===="
  ensure_java
  install_deps
  download_zk
  install_zk_files
  write_profile
  setup_hostname
  setup_hosts
  write_cfg_cluster
  write_systemd "Apache ZooKeeper Cluster (myid=${MYID})"
  port_in_use "$CLIENT_PORT" && warn "客户端端口 $CLIENT_PORT 已被占用，如果不是本机旧 ZK 进程，请换 --client-port"
  firewall_setup "$CLIENT_PORT" "$QUORUM_PORT" "$ELECTION_PORT" "${ADMIN_PORT:-8080}"
  start_and_verify cluster || {
    err "本节点启动失败。提示：首次部署可先确保 zk-1 起来，再依次启动 zk-2、zk-3"
    exit 1
  }
  print_summary cluster
}

do_pseudo() {
  info "==== 伪集群模式安装（单机 ${PSEUDO_NODES} 实例）===="
  [ "$PSEUDO_NODES" -ge 2 ] || die "--nodes 至少为 2"
  [ $((PSEUDO_NODES % 2)) -eq 0 ] && warn "实例数为偶数，建议奇数（3/5/7）"

  ensure_java
  install_deps
  download_zk
  install_zk_files
  write_profile
  setup_hostname

  local BASE="${PSEUDO_BASE:-/data/zk-cluster}"
  mkdir -p "$BASE"
  local i j port d aport
  local admin_ports=""
  for i in $(seq 1 "$PSEUDO_NODES"); do
    d="$BASE/zk$i"
    mkdir -p "$d/conf" "$d/data" "$d/logs"
    port=$((CLIENT_PORT + i - 1))
    port_in_use "$port" && warn "端口 $port 已被占用，实例 zk$i 可能启动失败"
    aport="$(pick_admin_port 8080)"
    ADMIN_PORTS_USED="$ADMIN_PORTS_USED $aport"
    admin_ports="$admin_ports $aport"

    {
      cat <<EOF
# 伪集群实例 zk${i} —— 由 zookeeper-install.sh 生成
tickTime=2000
initLimit=10
syncLimit=5
dataDir=${d}/data
clientPort=${port}
maxClientCnxns=300
autopurge.snapRetainCount=3
autopurge.purgeInterval=24
admin.serverPort=${aport}
4lw.commands.whitelist=*
EOF
      for j in $(seq 1 "$PSEUDO_NODES"); do
        echo "server.${j}=127.0.0.1:$((QUORUM_PORT + j - 1)):$((ELECTION_PORT + j - 1))"
      done
    } > "$d/conf/zoo.cfg"

    echo "$i" > "$d/data/myid"
    ok "实例 zk$i: 客户端端口 $port, 数据目录 $d/data, myid=$i"
  done

  # 由于共用一套二进制，用 ZOOCFGDIR 区分实例
  cat > "$ZK_HOME/bin/zk-cluster.sh" <<EOF
#!/usr/bin/env bash
# 伪集群启停脚本 —— 由 zookeeper-install.sh 生成
export JAVA_HOME="${JAVA_HOME_DETECTED}"
ZK_HOME="${ZK_HOME}"
BASE="${BASE}"
NODES=${PSEUDO_NODES}

case "\${1:-}" in
  start|stop|restart|status) ACTION="\$1" ;;
  *) echo "用法: \$0 {start|stop|restart|status}"; exit 1 ;;
esac

for i in \$(seq 1 "\$NODES"); do
  export ZOOCFGDIR="\$BASE/zk\$i/conf"
  export ZOO_LOG_DIR="\$BASE/zk\$i/logs"
  export ZOOPIDFILE="\$BASE/zk\$i/zookeeper_server.pid"
  echo "==> zk\$i \$ACTION"
  "\$ZK_HOME/bin/zkServer.sh" "\$ACTION" || true
  sleep 2
done
EOF
  chmod +x "$ZK_HOME/bin/zk-cluster.sh"

  local fw_ports=()
  for i in $(seq 1 "$PSEUDO_NODES"); do
    fw_ports+=("$((CLIENT_PORT + i - 1))" "$((QUORUM_PORT + i - 1))" "$((ELECTION_PORT + i - 1))")
  done
  # shellcheck disable=SC2206
  fw_ports+=($admin_ports)
  firewall_setup "${fw_ports[@]}"

  if [ "$DO_START" -eq 1 ]; then
    info "启动伪集群 ..."
    "$ZK_HOME/bin/zk-cluster.sh" start || true
    sleep 5
    local alive=0
    for i in $(seq 1 "$PSEUDO_NODES"); do
      if zk_ruok "$((CLIENT_PORT + i - 1))"; then ok "zk$i 正常（$((CLIENT_PORT + i - 1))）"; alive=$((alive + 1)); else warn "zk$i 未就绪"; fi
    done
    [ "$alive" -ge 2 ] && ok "存活 $alive/$PSEUDO_NODES，满足过半" || warn "存活不足半数，集群无法选主"
  fi
  print_summary pseudo
}

do_uninstall() {
  info "==== 卸载 ZooKeeper ===="
  if [ -f "$SERVICE_FILE" ]; then
    systemctl stop zookeeper >/dev/null 2>&1 || true
    systemctl disable zookeeper >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ok "已移除 systemd 服务"
  fi
  if [ -d "$ZK_HOME" ]; then
    if [ -f "$ZK_HOME/$MANAGED_MARK" ] || [ "$FORCE" -eq 1 ]; then
      rm -rf "$ZK_HOME"
      ok "已删除 $ZK_HOME"
    else
      warn "$ZK_HOME 不是本脚本安装的（缺少标记文件），跳过；可加 --force 强制删除"
    fi
  fi
  rm -f "$PROFILE_FILE"
  if [ -d /data/zk-cluster ]; then
    pkill -f 'zookeeper.*zk-cluster' 2>/dev/null || true
    [ "$PURGE" -eq 1 ] && { rm -rf /data/zk-cluster; ok "已删除 /data/zk-cluster"; }
  fi
  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$ZK_DATA"
    ok "已删除数据目录 $ZK_DATA"
  else
    info "数据目录 $ZK_DATA 已保留（--purge 可一并删除）"
  fi
  ok "卸载完成"
}

# ------------------------------- 安装总结 -------------------------------------
print_summary() {
  local kind="$1"
  echo
  echo "=================================================================="
  ok "ZooKeeper ${ZK_VERSION} ${kind} 模式安装完成"
  echo "------------------------------------------------------------------"
  echo "  安装目录 : $ZK_HOME"
  echo "  配置文件 : $ZK_HOME/conf/zoo.cfg"
  echo "  数据目录 : $ZK_DATA"
  echo "  日志目录 : $ZK_LOG"
  echo "  JAVA_HOME: $JAVA_HOME_DETECTED"
  echo
  echo "  常用命令:"
  echo "    systemctl start|stop|restart|status zookeeper"
  echo "    $ZK_HOME/bin/zkServer.sh status"
  echo "    echo ruok | nc 127.0.0.1 $CLIENT_PORT     # 返回 imok"
  echo "    $ZK_HOME/bin/zkCli.sh -server 127.0.0.1:$CLIENT_PORT"
  echo
  if [ "$kind" = "cluster" ]; then
    echo "  集群验证:"
    echo "    每个节点执行 $ZK_HOME/bin/zkServer.sh status  # 1 个 leader + 2 个 follower"
    echo "    在任一节点: echo conf | nc <主机名> $CLIENT_PORT"
    echo "  注意: 其它节点请用相同 --servers，仅改 --myid"
  fi
  if [ "$kind" = "pseudo" ]; then
    echo "  伪集群命令:"
    echo "    $ZK_HOME/bin/zk-cluster.sh start|stop|restart|status"
    echo "    连接: zkCli.sh -server 127.0.0.1:$CLIENT_PORT"
  fi
  echo "=================================================================="
}

# ------------------------------- 主流程 ---------------------------------------
main() {
  parse_args "$@"
  require_root
  check_os

  case "$MODE" in
    standalone) do_standalone ;;
    cluster)    do_cluster ;;
    pseudo)     do_pseudo ;;
    uninstall)  do_uninstall ;;
    *)          die "未知模式: $MODE" ;;
  esac
}

main "$@"
