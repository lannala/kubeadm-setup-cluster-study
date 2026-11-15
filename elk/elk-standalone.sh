#!/bin/bash
# ============================================================================
#  ELK 单机（standalone）一键部署脚本
#
#  组件版本:
#     nginx           1.26.3        （源码编译）
#     JDK             jdk-*_linux-x64_bin.tar.gz （沿用原匹配模式，自动查找）
#     Elasticsearch   8.13.1
#     Kibana          8.13.1
#     Logstash        8.13.1
#     ElasticHD       elasticHD_linux_amd64.zip
#     进程管理         supervisor
#     日志采集         access_json.log + error_json.log 双路（与 .bak 一致）
#
#  用法:
#     ./elk-standalone.sh              # 交互菜单
#     ./elk-standalone.sh install      # 完整部署并按序启动
#     ./elk-standalone.sh start|stop|restart|status
#     ./elk-standalone.sh diagnose     # 打印排查信息
#
#  可用环境变量:
#     ELK_HOST_IP=192.168.83.134   指定对外 IP（默认自动探测 ens33/eth0/ens192）
#     ES_HEAP=2g                   ES 堆大小（默认 2g，与 .bak 一致）
#     NGINX_PREFIX=/usr/local/nginx-1.26.3
#     PKG_DIR=/date                安装包所在目录（优先级最高的搜索目录）
# ============================================================================
set -o pipefail

#-------------------------------- 版本（写死，勿改） ---------------------------
NGINX_VER="1.26.3"
NGINX_TAR="nginx-${NGINX_VER}.tar.gz"
NGINX_PREFIX="${NGINX_PREFIX:-/usr/local/nginx-${NGINX_VER}}"

ELK_VER="8.13.1"
ES_HOME="/usr/local/elasticsearch-${ELK_VER}"
KIBANA_HOME="/usr/local/kibana-${ELK_VER}"
LOGSTASH_HOME="/usr/local/logstash-${ELK_VER}"
ES_TAR="elasticsearch-${ELK_VER}-linux-x86_64.tar.gz"
KIBANA_TAR="kibana-${ELK_VER}-linux-x86_64.tar.gz"
LOGSTASH_TAR="logstash-${ELK_VER}-linux-x86_64.tar.gz"
ELASTICHD_ZIP="elasticHD_linux_amd64.zip"
JDK_TAR_PATTERN="jdk-*_linux-x64_bin.tar.gz"

ES_HEAP="${ES_HEAP:-2g}"

#-------------------------------- 目录规划 ------------------------------------
SRC_DIR="${SRC_DIR:-/data}"
DATA_ROOT="/data"
ES_DATA_DIR="/data/elasticsearch/data"
ES_LOG_DIR="/data/elasticsearch/logs"
KIBANA_LOG_DIR="/data/kibana/log"
LOGSTASH_DATA_DIR="/data/logstash"
NGINX_LOG_DIR="/data/nginx/log"
SUP_LOG_DIR="/data/supervisor/log"
NGINX_ACCESS_JSON="${NGINX_LOG_DIR}/access_json.log"
NGINX_ERROR_JSON="${NGINX_LOG_DIR}/error_json.log"

SEARCH_DIRS=(/root /date /data /tmp /opt /usr/local /usr/src "$PWD")
[[ -n ${PKG_DIR:-} ]] && SEARCH_DIRS=("$PKG_DIR" "${SEARCH_DIRS[@]}")

#-------------------------------- 日志函数 ------------------------------------
C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
C_MAGENTA=$'\033[1;35m'; C_END=$'\033[0m'
[[ -t 1 ]] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_MAGENTA=''; C_END=''; }

info() { echo -e "${C_YELLOW}[INFO]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
warn() { echo -e "${C_MAGENTA}[WARN]${C_END} $*"; }
err()  { echo -e "${C_RED}[FAIL]${C_END} $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行本脚本"; }

#-------------------------------- 查找与解压 ----------------------------------
# 用法: find_pkg <模式...>   打印第一个命中的文件路径（找不到返回 1）
find_pkg() {
    local pat dir found
    for pat in "$@"; do
        for dir in "${SEARCH_DIRS[@]}"; do
            [[ -d $dir ]] || continue
            found=$(find "$dir" -maxdepth 4 -name "$pat" -type f -print -quit 2>/dev/null)
            [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
        done
    done
    found=$(find / -xdev -name "$1" -type f -print -quit 2>/dev/null)
    [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
    return 1
}

# 按魔数返回 tar 压缩选项字母（后缀名不可信：404 页面也常被存成 .tar.gz）
tar_cflag() {
    local magic
    magic=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        1f8b*)        printf '%s' 'z' ;;   # gzip
        fd377a585a00) printf '%s' 'J' ;;   # xz
        425a68*)      printf '%s' 'j' ;;   # bzip2
        *)            printf '%s' ''  ;;   # 未知，交给 tar 自行判断
    esac
}

pkg_ok() {   # 归档是否真实可读
    local t="$1" flag
    [[ -f $t ]] || return 1
    flag=$(tar_cflag "$t")
    tar -t"${flag}f" "$t" >/dev/null 2>&1
}

extract_to() {   # extract_to <包> <目标目录>
    local t="$1" dest="$2" flag
    flag=$(tar_cflag "$t")
    tar -x"${flag}f" "$t" -C "$dest"
}

# 幂等备份：只在首次留一份 .bak，避免每次重跑都覆盖掉真正的原始配置
backup_once() {   # backup_once <文件>
    local f="$1"
    [[ -f $f ]] || return 0
    [[ -f "${f}.bak" ]] && return 0
    cp -a "$f" "${f}.bak" 2>/dev/null || true
}

#-------------------------------- 端口 / IP -----------------------------------
port_listening() {
    local p="$1"
    if have ss; then
        ss -lnt 2>/dev/null | grep -q ":${p} "
    else
        netstat -lnt 2>/dev/null | grep -q ":${p} "
    fi
}

detect_hostip() {
    local ip=""
    if [[ -n ${ELK_HOST_IP:-} ]]; then
        ip="$ELK_HOST_IP"
    else
        # 保持网卡优先级（ens33/eth0/ens192），再退回任意非 lo 地址，
        ip=$(ip -4 -o addr show 2>/dev/null \
             | awk '$2 ~ /^(ens33|eth0|ens192|ens32|ens160)$/ {print $4}' \
             | cut -d/ -f1 | head -n1)
        [[ -z $ip ]] && ip=$(ip -4 -o addr show 2>/dev/null \
             | awk '$2 != "lo" {print $4}' | cut -d/ -f1 | head -n1)
        [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [[ -n $ip ]] || die "无法确定本机 IP，请用 ELK_HOST_IP=<IP> 指定"
    printf '%s' "$ip"
}

#-------------------------------- 组件是否已就位 ------------------------------
need_jdk()      { ! [[ -x "$(ls -d /usr/local/jdk-*/bin/java 2>/dev/null | head -n1)" ]]; }
need_nginx()    { [[ ! -x "${NGINX_PREFIX}/sbin/nginx" ]]; }
need_es()       { [[ ! -x "${ES_HOME}/bin/elasticsearch" ]]; }
need_kibana()   { [[ ! -x "${KIBANA_HOME}/bin/kibana" ]]; }
need_logstash() { [[ ! -x "${LOGSTASH_HOME}/bin/logstash" ]]; }
need_hd()       { [[ ! -x "${ES_HOME}/bin/ElasticHD" ]]; }

#-------------------------------- 前置检查 ------------------------------------
preflight() {
    require_root
    have tar  || die "系统缺少 tar"
    have find || die "系统缺少 find"

    HOST_IP=$(detect_hostip)
    ok "本机 IP: ${HOST_IP}"

    info "探测安装包（已搜索: ${SEARCH_DIRS[*]}）..."
    JDK_PAK=$(find_pkg "$JDK_TAR_PATTERN") || true
    NGINX_PAK=$(find_pkg "$NGINX_TAR") || true
    ES_PAK=$(find_pkg "$ES_TAR") || true
    KIBANA_PAK=$(find_pkg "$KIBANA_TAR") || true
    LOGSTASH_PAK=$(find_pkg "$LOGSTASH_TAR") || true
    ELASTICHD_PAK=$(find_pkg "$ELASTICHD_ZIP") || true

    # 只对"尚未安装且缺包"的组件报错，一次性列全，避免跑到一半才炸
    local missing=()
    need_jdk      && [[ -z $JDK_PAK ]]       && missing+=("$JDK_TAR_PATTERN")
    need_nginx    && [[ -z $NGINX_PAK ]]     && missing+=("$NGINX_TAR")
    need_es       && [[ -z $ES_PAK ]]        && missing+=("$ES_TAR")
    need_kibana   && [[ -z $KIBANA_PAK ]]    && missing+=("$KIBANA_TAR")
    need_logstash && [[ -z $LOGSTASH_PAK ]]  && missing+=("$LOGSTASH_TAR")
    need_hd       && [[ -z $ELASTICHD_PAK ]] && missing+=("$ELASTICHD_ZIP")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "以下安装包未找到:"
        printf '  - %s\n' "${missing[@]}" >&2
        die "请把包放到 ${SEARCH_DIRS[*]} 之一，或用 PKG_DIR=<目录> 指定后重跑"
    fi

    # 找到的包必须真能读：下载失败的 404 页面也常叫 *.tar.gz
    local p
    for p in "$JDK_PAK" "$NGINX_PAK" "$ES_PAK" "$KIBANA_PAK" "$LOGSTASH_PAK"; do
        [[ -n $p ]] || continue
        pkg_ok "$p" || die "安装包损坏或不是有效归档（可能是下载失败的残留）: ${p}"
    done

    ok "安装包检查通过:"
    for p in "$JDK_PAK" "$NGINX_PAK" "$ES_PAK" "$KIBANA_PAK" "$LOGSTASH_PAK" "$ELASTICHD_PAK"; do
        [[ -n $p ]] && echo "     ${p}"
    done
    return 0
}

#-------------------------------- 内核参数 / 句柄 ------------------------------
tune_system() {
    info "写入内核参数 /etc/sysctl.d/99-elk.conf（不覆盖 /etc/sysctl.conf）"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-elk.conf << 'EOF'
# ELK 必需：ES 大量使用 mmap，低于 262144 会启动失败
vm.max_map_count=262144
# 原脚本用 0（完全禁止换存），内存吃紧时 OOM Killer 会直接杀掉 ES；1 更稳妥
vm.swappiness=1
vm.overcommit_memory=1
EOF
    sysctl -p /etc/sysctl.d/99-elk.conf >/dev/null \
        || warn "sysctl 下发失败，请手动确认 vm.max_map_count"

    info "写入句柄限制 /etc/security/limits.d/99-elk.conf（不覆盖 limits.conf）"
    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-elk.conf << 'EOF'
*      soft   nofile   65535
*      hard   nofile   131072
*      soft   nproc    2048
*      hard   nproc    4096
*      soft   memlock  unlimited
*      hard   memlock  unlimited
EOF
    ok "内核参数与句柄已配置（当前 vm.max_map_count=$(sysctl -n vm.max_map_count 2>/dev/null)）"
}

#-------------------------------- EPEL / 依赖 ---------------------------------
setup_epel() {
    if yum repolist 2>/dev/null | grep -qi '^epel'; then
        ok "EPEL 源已存在"
        return 0
    fi
    local ver=""
    [[ -r /etc/os-release ]] && . /etc/os-release && ver="${VERSION_ID:-}"
    case "$ver" in
        7*)
            info "配置阿里云 EPEL 7 源"
            [[ -f /etc/yum.repos.d/epel.repo ]] && cp -a /etc/yum.repos.d/epel.repo \
                "/etc/yum.repos.d/epel.repo.bak.$(date +%s)"
            cat > /etc/yum.repos.d/epel.repo << 'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=https://mirrors.aliyun.com/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7
EOF
            ;;
        *)
            info "安装 epel-release"
            yum install -y epel-release >/dev/null 2>&1 \
                || warn "epel-release 安装失败，supervisor 可能装不上"
            ;;
    esac
    yum makecache fast >/dev/null 2>&1 || yum makecache >/dev/null 2>&1 || true
}

install_deps() {
    info "安装编译与运行依赖..."
    yum install -y ntpdate make gcc gcc-c++ pcre pcre-devel zlib zlib-devel \
        glibc glibc-devel unzip tar findutils which iproute net-tools \
        >/dev/null 2>&1 || warn "部分依赖安装失败，若 nginx 编译报错请检查软件源"
    have ntpdate && ntpdate ntp1.aliyun.com >/dev/null 2>&1 || true
    have timedatectl && timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1 || true
}

create_users() {
    local u
    info "创建运行用户（幂等）..."
    for u in es kibana logstash nginx; do
        if id -u "$u" >/dev/null 2>&1; then
            ok "用户 ${u} 已存在"
        else
            useradd -s /sbin/nologin -M "$u" || die "创建用户 ${u} 失败"
            ok "已创建用户 ${u}"
        fi
    done
}

create_dirs() {
    info "创建数据与日志目录..."
    mkdir -p "$SRC_DIR" "$ES_DATA_DIR" "$ES_LOG_DIR" "$KIBANA_LOG_DIR" \
             "$LOGSTASH_DATA_DIR" "$NGINX_LOG_DIR" "$SUP_LOG_DIR" \
        || die "创建目录失败"
    # logstash 的 file 输入要求文件已存在，否则管道启动即报错
    local f
    for f in "$NGINX_ACCESS_JSON" "$NGINX_ERROR_JSON"; do
        [[ -f $f ]] || : > "$f"
    done
    chmod 755 "$DATA_ROOT"
    ok "目录就绪"
}

#-------------------------------- JDK -----------------------------------------
install_jdk() {
    local existing
    existing=$(ls -d /usr/local/jdk-* 2>/dev/null | head -n1)
    if [[ -n $existing && -x "${existing}/bin/java" ]]; then
        JDK_REAL_HOME="$existing"
        ok "JDK 已存在，跳过解压: ${JDK_REAL_HOME}"
    else
        info "解压 JDK: $(basename "$JDK_PAK") -> /usr/local"
        extract_to "$JDK_PAK" /usr/local || die "JDK 解压失败"
        JDK_REAL_HOME=$(ls -d /usr/local/jdk-* 2>/dev/null | head -n1)
        [[ -n $JDK_REAL_HOME && -x "${JDK_REAL_HOME}/bin/java" ]] \
            || die "解压后未找到可用的 JDK 目录"
    fi

    # 全局环境变量写入独立文件，重登录即生效（原脚本只 export 给当前 shell）
    cat > /etc/profile.d/jdk.sh << EOF
export JAVA_HOME=${JDK_REAL_HOME}
export PATH=\$PATH:\${JAVA_HOME}/bin
export CLASSPATH=.:\${JAVA_HOME}/lib
EOF
    chmod 644 /etc/profile.d/jdk.sh
    export JAVA_HOME="$JDK_REAL_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
    ok "JDK 就绪: $("${JDK_REAL_HOME}/bin/java" -version 2>&1 | head -n1)"
    info "提示：ES 8 / Logstash 8 自带 JDK17，运行时不使用上面的 JDK8"
}

#-------------------------------- nginx ---------------------------------------
install_nginx() {
    if [[ -x "${NGINX_PREFIX}/sbin/nginx" ]]; then
        ok "nginx ${NGINX_VER} 已安装，跳过编译: ${NGINX_PREFIX}"
    else
        info "解压 nginx: ${NGINX_TAR} -> ${SRC_DIR}"
        extract_to "$NGINX_PAK" "$SRC_DIR" || die "nginx 解压失败"
        local src="${SRC_DIR}/nginx-${NGINX_VER}"
        [[ -d $src ]] || die "解压后未找到目录 ${src}"

        info "configure nginx（源码编译耗时较久）..."
        cd "$src" || die "无法进入 ${src}"
        ./configure --prefix="$NGINX_PREFIX" --user=nginx --group=nginx \
            --with-http_stub_status_module --without-http_gzip_module \
            > /tmp/nginx_configure.log 2>&1 \
            || { err "nginx configure 失败，详见 /tmp/nginx_configure.log"
                 tail -n 20 /tmp/nginx_configure.log >&2
                 die "nginx 编译配置失败"; }

        local jobs; jobs=$(nproc 2>/dev/null || echo 2)
        make -j"$jobs" > /tmp/nginx_make.log 2>&1 \
            || { err "nginx make 失败，详见 /tmp/nginx_make.log"
                 tail -n 20 /tmp/nginx_make.log >&2
                 die "nginx 编译失败"; }
        make install > /tmp/nginx_install.log 2>&1 \
            || { err "nginx make install 失败，详见 /tmp/nginx_install.log"
                 tail -n 20 /tmp/nginx_install.log >&2
                 die "nginx 安装失败"; }
        cd "$DATA_ROOT" > /dev/null 2>&1 || true
    fi

    mkdir -p "${NGINX_PREFIX}/conf/conf.d" "${NGINX_PREFIX}/logs" "$NGINX_LOG_DIR"
    backup_once "${NGINX_PREFIX}/conf/nginx.conf"

    # nginx 自身的 $ 变量必须原样保留：用未转义 heredoc 并逐条转义 \$
    cat > "${NGINX_PREFIX}/conf/nginx.conf" << EOF
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    # 改进点 7：原脚本用默认 combined 格式写 access_json.log，
    # logstash 的 json filter 解析不了，日志一条也进不了 ES。这里真正输出 JSON。
    log_format json escape=json '{'
        '"@timestamp":"\$time_iso8601",'
        '"remote_addr":"\$remote_addr",'
        '"remote_user":"\$remote_user",'
        '"request":"\$request",'
        '"method":"\$request_method",'
        '"uri":"\$uri",'
        '"status":\$status,'
        '"body_bytes_sent":\$body_bytes_sent,'
        '"request_time":\$request_time,'
        '"http_referer":"\$http_referer",'
        '"http_user_agent":"\$http_user_agent",'
        '"http_x_forwarded_for":"\$http_x_forwarded_for"'
    '}';

    access_log ${NGINX_ACCESS_JSON} json;
    error_log  ${NGINX_ERROR_JSON} warn;

    include ${NGINX_PREFIX}/conf/conf.d/*.conf;
}
EOF

    # 反向代理 Kibana；IP/路径用占位符注入（引号 heredoc，$host 等原样保留）
    cat > "${NGINX_PREFIX}/conf/conf.d/elk.conf" << 'EOF'
server {
    listen   80;
    server_name  elk;

    location / {
        proxy_pass http://@HOST_IP@:5601;
        proxy_set_header Host $host:5601;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Via "nginx";
        proxy_connect_timeout 30s;
        proxy_read_timeout 120s;
    }

    location /status {
        stub_status on;
        access_log @NGINX_LOG_DIR@/kibana_status.log;
        auth_basic "NginxStatus";
    }
}
EOF
    sed -i -e "s|@HOST_IP@|${HOST_IP}|" -e "s|@NGINX_LOG_DIR@|${NGINX_LOG_DIR}|" \
        "${NGINX_PREFIX}/conf/conf.d/elk.conf"

    "${NGINX_PREFIX}/sbin/nginx" -t > /tmp/nginx_test.log 2>&1 \
        || { err "nginx 配置校验失败:"; cat /tmp/nginx_test.log >&2; die "nginx 配置有误"; }
    ok "nginx ${NGINX_VER} 就绪，配置校验通过"
}

#-------------------------------- elasticsearch -------------------------------
install_elasticsearch() {
    if [[ -x "${ES_HOME}/bin/elasticsearch" ]]; then
        ok "Elasticsearch 已存在，跳过解压: ${ES_HOME}"
    else
        info "解压 Elasticsearch: ${ES_TAR} -> /usr/local"
        extract_to "$ES_PAK" /usr/local || die "Elasticsearch 解压失败"
        [[ -x "${ES_HOME}/bin/elasticsearch" ]] || die "解压后未找到 ${ES_HOME}"
    fi

    backup_once "${ES_HOME}/config/elasticsearch.yml"

    cat > "${ES_HOME}/config/elasticsearch.yml" << 'EOF'
cluster.name: elk
node.name: node1
path.data: @ES_DATA@
path.logs: @ES_LOG@
# 单机 + supervisor 托管，拿不到 RLIMIT_MEMLOCK，锁内存会导致启动失败
bootstrap.memory_lock: false
network.host: 0.0.0.0
http.port: 9200
cluster.initial_master_nodes: ["node1"]
xpack.security.enabled: false
http.cors.enabled: true
http.cors.allow-origin: "*"
http.cors.allow-headers: Authorization
EOF
    sed -i -e "s|@ES_DATA@|${ES_DATA_DIR}|" -e "s|@ES_LOG@|${ES_LOG_DIR}|" \
        "${ES_HOME}/config/elasticsearch.yml"

    # 只改堆大小，保留发行 jvm.options 里必需的 --add-opens 等参数
    # 就地替换 -Xms/-Xmx，避免与 jvm.options.d/ 里的同名参数重复。
    local jvm="${ES_HOME}/config/jvm.options"
    rm -f "${ES_HOME}/config/jvm.options.d/heap.options" 2>/dev/null || true
    if [[ -f $jvm ]]; then
        backup_once "$jvm"
        if grep -qE '^[[:space:]]*-Xms' "$jvm"; then
            sed -i -E "s|^[[:space:]]*-Xms.*|-Xms${ES_HEAP}|" "$jvm"
        else
            printf -- '-Xms%s\n' "$ES_HEAP" >> "$jvm"
        fi
        if grep -qE '^[[:space:]]*-Xmx' "$jvm"; then
            sed -i -E "s|^[[:space:]]*-Xmx.*|-Xmx${ES_HEAP}|" "$jvm"
        else
            printf -- '-Xmx%s\n' "$ES_HEAP" >> "$jvm"
        fi
    else
        printf -- '-Xms%s\n-Xmx%s\n' "$ES_HEAP" "$ES_HEAP" > "$jvm"
    fi
    ok "Elasticsearch 配置完成（堆 ${ES_HEAP}，安全认证已关闭）"
}

install_elasticHD() {
    if [[ -x "${ES_HOME}/bin/ElasticHD" ]]; then
        ok "ElasticHD 已存在，跳过"
        return 0
    fi
    info "解压 ElasticHD 到 ES bin 目录..."
    unzip -o "$ELASTICHD_PAK" -d "${ES_HOME}/bin" > /dev/null \
        || die "ElasticHD 解压失败"
    if [[ -x "${ES_HOME}/bin/ElasticHD" ]]; then
        ok "ElasticHD 安装完成"
        return 0
    fi
    # 包内二进制名可能是小写 elastichd，自动纠正，避免 supervisor 起不来
    local alt
    alt=$(find "${ES_HOME}/bin" -maxdepth 2 -type f -iname 'elastichd*' 2>/dev/null | head -n1)
    if [[ -n $alt ]]; then
        mv "$alt" "${ES_HOME}/bin/ElasticHD" && chmod +x "${ES_HOME}/bin/ElasticHD"
        ok "ElasticHD 安装完成（已按实际文件名纠正: $(basename "$alt")）"
    else
        warn "zip 内未找到 ElasticHD 可执行文件，supervisor 里该 program 会启动失败"
    fi
}

#-------------------------------- kibana --------------------------------------
install_kibana() {
    if [[ -x "${KIBANA_HOME}/bin/kibana" ]]; then
        ok "Kibana 已存在，跳过解压: ${KIBANA_HOME}"
    else
        info "解压 Kibana: ${KIBANA_TAR} -> /usr/local"
        extract_to "$KIBANA_PAK" /usr/local || die "Kibana 解压失败"
        [[ -x "${KIBANA_HOME}/bin/kibana" ]] || die "解压后未找到 ${KIBANA_HOME}"
    fi

    backup_once "${KIBANA_HOME}/config/kibana.yml"

    cat > "${KIBANA_HOME}/config/kibana.yml" << 'EOF'
server.port: 5601
server.host: "0.0.0.0"
server.name: "node1"
server.ssl.enabled: false
# 改进点 6：Kibana 8 默认要求安全认证；ES 侧已关闭，这里必须同步关闭
xpack.security.enabled: false
elasticsearch.hosts: ["http://@HOST_IP@:9200"]
logging.root.level: info
logging.appenders.default:
  type: file
  fileName: @KIBANA_LOG@/kibana.log
  layout:
    type: json
i18n.locale: "zh-CN"
EOF
    sed -i -e "s|@HOST_IP@|${HOST_IP}|" -e "s|@KIBANA_LOG@|${KIBANA_LOG_DIR}|" \
        "${KIBANA_HOME}/config/kibana.yml"
    ok "Kibana 配置完成"
}

#-------------------------------- logstash ------------------------------------
install_logstash() {
    if [[ -x "${LOGSTASH_HOME}/bin/logstash" ]]; then
        ok "Logstash 已存在，跳过解压: ${LOGSTASH_HOME}"
    else
        info "解压 Logstash: ${LOGSTASH_TAR} -> /usr/local"
        extract_to "$LOGSTASH_PAK" /usr/local || die "Logstash 解压失败"
        [[ -x "${LOGSTASH_HOME}/bin/logstash" ]] || die "解压后未找到 ${LOGSTASH_HOME}"
    fi

    mkdir -p "${LOGSTASH_HOME}/config/conf.d" "$LOGSTASH_DATA_DIR"
    backup_once "${LOGSTASH_HOME}/config/logstash.yml"

    cat > "${LOGSTASH_HOME}/config/logstash.yml" << 'EOF'
node.name: node1
pipeline.id: node1
path.config: "@LS_HOME@/config/conf.d/*.conf"
path.data: @LS_DATA@
pipeline.workers: 2
pipeline.batch.size: 5000
pipeline.batch.delay: 200
api.http.host: 0.0.0.0
api.http.port: 9600-9700
EOF
    sed -i -e "s|@LS_HOME@|${LOGSTASH_HOME}|" -e "s|@LS_DATA@|${LOGSTASH_DATA_DIR}|" \
        "${LOGSTASH_HOME}/config/logstash.yml"

    # 双路 file 输入与 .bak 保持一致；改进点 8：按 type 分流，避免整行 json 解析
    # 把非 JSON 的 error 日志静默丢弃
    cat > "${LOGSTASH_HOME}/config/conf.d/logstash.conf" << 'EOF'
input {
  file {
    path => ["@ACCESS_JSON@"]
    type => "shopweb-access"
    start_position => "end"
    sincedb_path => "@LS_DATA@/sincedb-access"
  }
  file {
    path => ["@ERROR_JSON@"]
    type => "shopweb-error"
    start_position => "end"
    sincedb_path => "@LS_DATA@/sincedb-error"
  }
}

filter {
  # access 由 nginx 的 log_format json 产生，可直接解析成字段
  if [type] == "shopweb-access" {
    json {
      source => "message"
      skip_on_invalid_json => true
    }
  }
  # error_json.log 实为 nginx 错误日志（非 JSON）：原样入库，
  # 需要结构化字段时再自行加 grok（nginx 时间格式为 yyyy/MM/dd HH:mm:ss）
}

output {
  elasticsearch {
    hosts => ["http://@HOST_IP@:9200"]
    index => "logstashaa-%{type}-%{+YYYY.MM.dd}"
  }
}
EOF
    sed -i -e "s|@ACCESS_JSON@|${NGINX_ACCESS_JSON}|" \
           -e "s|@ERROR_JSON@|${NGINX_ERROR_JSON}|" \
           -e "s|@LS_DATA@|${LOGSTASH_DATA_DIR}|" \
           -e "s|@HOST_IP@|${HOST_IP}|" \
           "${LOGSTASH_HOME}/config/conf.d/logstash.conf"
    ok "Logstash 配置完成"
}

#-------------------------------- 属主 ----------------------------------------
fix_ownership() {
    info "设置目录属主..."
    chown -R es:es "$ES_HOME" "$DATA_ROOT/elasticsearch" 2>/dev/null || warn "ES 属主设置异常"
    chown -R kibana:kibana "$KIBANA_HOME" "$DATA_ROOT/kibana" 2>/dev/null || warn "Kibana 属主设置异常"
    chown -R logstash:logstash "$LOGSTASH_HOME" "$LOGSTASH_DATA_DIR" 2>/dev/null || warn "Logstash 属主设置异常"
    chown -R nginx:nginx "$NGINX_PREFIX" "$DATA_ROOT/nginx" 2>/dev/null || warn "nginx 属主设置异常"
    # logstash（非 nginx 用户）要读 nginx 写的日志，必须放开读权限
    chmod 644 "$NGINX_ACCESS_JSON" "$NGINX_ERROR_JSON" 2>/dev/null || true
    ok "属主设置完成"
}

#-------------------------------- supervisor ----------------------------------
install_supervisor() {
    if ! have supervisord && ! have supervisorctl; then
        info "安装 supervisor..."
        yum install -y supervisor >/dev/null 2>&1 \
            || die "supervisor 安装失败（请确认 EPEL 源可用）"
    fi
    mkdir -p /etc/supervisord.d /etc/systemd/system/supervisord.service.d "$SUP_LOG_DIR"

    cat > /etc/systemd/system/supervisord.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
LimitNPROC=4096
EOF

    if [[ -f /etc/supervisord.conf ]]; then
        grep -q '^minfds=' /etc/supervisord.conf \
            || sed -i '/\[supervisord\]/a minfds=65535' /etc/supervisord.conf
        grep -q '^minprocs=' /etc/supervisord.conf \
            || sed -i '/\[supervisord\]/a minprocs=4096' /etc/supervisord.conf
        sed -i -E 's/^minfds=[0-9]+/minfds=65535/; s/^minprocs=[0-9]+/minprocs=4096/' \
            /etc/supervisord.conf
    fi

    cat > /etc/supervisord.d/elk.ini << EOF
[group:elk]
programs=nginx,elasticsearch,elasticHD,logstash,kibana
priority=999

[program:nginx]
command=${NGINX_PREFIX}/sbin/nginx -g "daemon off;"
directory=${NGINX_PREFIX}
user=root
autostart=false
autorestart=true
startretries=3
startsecs=10
redirect_stderr=true
stdout_logfile=${SUP_LOG_DIR}/nginx.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3

[program:elasticsearch]
command=${ES_HOME}/bin/elasticsearch
directory=${ES_HOME}
user=es
autostart=false
autorestart=true
startretries=3
startsecs=10
redirect_stderr=true
stdout_logfile=${SUP_LOG_DIR}/elasticsearch.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3
rlimit_nofile=65535
rlimit_nproc=4096

[program:elasticHD]
command=${ES_HOME}/bin/ElasticHD -p 0.0.0.0:9800
directory=${ES_HOME}
user=es
autostart=false
autorestart=true
startretries=3
startsecs=10
redirect_stderr=true
stdout_logfile=${SUP_LOG_DIR}/elasticHD.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3

[program:logstash]
command=${LOGSTASH_HOME}/bin/logstash -f ${LOGSTASH_HOME}/config/conf.d/logstash.conf --config.reload.automatic
directory=${LOGSTASH_HOME}
user=logstash
autostart=false
autorestart=true
startretries=3
startsecs=20
redirect_stderr=true
stdout_logfile=${SUP_LOG_DIR}/logstash.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3

[program:kibana]
command=${KIBANA_HOME}/bin/kibana
directory=${KIBANA_HOME}
user=kibana
autostart=false
autorestart=true
startretries=3
startsecs=10
redirect_stderr=true
stdout_logfile=${SUP_LOG_DIR}/kibana.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3
EOF
    # 全部 autostart=false，由本脚本按依赖顺序串行拉起，
    # 避免 Kibana/Logstash 抢在 ES 就绪前启动而反复重启。

    systemctl daemon-reload
    systemctl enable supervisord >/dev/null 2>&1 || true
    if systemctl is-active --quiet supervisord; then
        supervisorctl reread > /dev/null 2>&1 || true
        supervisorctl update > /dev/null 2>&1 || true
        ok "supervisor 已在运行，配置已更新"
    else
        systemctl start supervisord || die "supervisord 启动失败"
        supervisorctl reread > /dev/null 2>&1 || true
        supervisorctl update > /dev/null 2>&1 || true
        ok "supervisor 就绪"
    fi
}

wait_for_port() {   # wait_for_port <端口> <秒数>
    local p="$1" timeout="$2" i=0
    while (( i < timeout )); do
        port_listening "$p" && return 0
        sleep 2; i=$((i + 2))
    done
    return 1
}

start_stack() {
    info "启动 Elasticsearch（首个拉起，等待 9200 就绪）..."
    supervisorctl start elk:elasticsearch > /dev/null 2>&1 || true
    if ! wait_for_port 9200 180; then
        err "Elasticsearch 未能在 180 秒内监听 9200，最近日志:"
        tail -n 30 "${SUP_LOG_DIR}/elasticsearch.log" 2>/dev/null
        tail -n 20 "${ES_LOG_DIR}"/*.log 2>/dev/null
        die "Elasticsearch 启动失败"
    fi
    ok "Elasticsearch 已就绪: $(curl -s -m 5 http://127.0.0.1:9200 | grep -o '"number"[^,]*' | head -n1)"

    info "启动 Kibana / Logstash / ElasticHD / nginx ..."
    supervisorctl start elk:kibana elk:logstash elk:elasticHD elk:nginx > /dev/null 2>&1 || true

    wait_for_port 5601 120 && ok "Kibana 监听 5601" \
        || warn "Kibana 未在 120 秒内就绪（首次启动需初始化索引，可稍后用 status 复查）"
    wait_for_port 9600 120 && ok "Logstash 监听 9600" \
        || warn "Logstash 未在 120 秒内就绪"
    wait_for_port 9800 60  && ok "ElasticHD 监听 9800" \
        || warn "ElasticHD 未在 60 秒内就绪（不影响 ELK 主链路）"
    wait_for_port 80   60  && ok "nginx 监听 80" \
        || warn "nginx 未在 60 秒内就绪"

    info "写入测试文档并验证链路..."
    curl -s -XPOST "http://127.0.0.1:9200/test-logs/_doc/1" \
        -H 'Content-Type: application/json' \
        -d "{\"@timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"message\":\"test log\"}" \
        > /dev/null || warn "测试文档写入失败"

    # 造一条 JSON 访问日志，验证 nginx -> logstash -> ES 真的通
    printf '{"@timestamp":"%s","remote_addr":"127.0.0.1","remote_user":"-","request":"GET /health","method":"GET","uri":"/health","status":200,"body_bytes_sent":6,"request_time":0.001,"http_referer":"-","http_user_agent":"elk-standalone-check","http_x_forwarded_for":"-"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" >> "$NGINX_ACCESS_JSON" 2>/dev/null || true
    sleep 10

    echo
    info "当前索引:"
    curl -s -m 10 "http://127.0.0.1:9200/_cat/indices?v" || warn "索引列表获取失败"
    if curl -s -m 10 "http://127.0.0.1:9200/logstashaa-shopweb-access-$(date +%Y.%m.%d)/_count" \
        | grep -q '"count":[1-9]'; then
        ok "日志链路验证通过：nginx access 日志已进入 ES"
    else
        warn "未查到今天的 shopweb-access 文档（可能是索引日期时区差异或管道延迟），可用 status/diagnose 复查"
    fi
}

show_status() {
    echo "==================== ELK 状态 ===================="
    printf '  %-16s %-8s %s\n' "组件" "端口" "状态"
    local row name port st
    for row in "elasticsearch:9200" "kibana:5601" "logstash:9600" "elasticHD:9800" "nginx:80"; do
        name="${row%%:*}"; port="${row##*:}"
        if port_listening "$port"; then st="${C_GREEN}监听中${C_END}"; else st="${C_RED}未监听${C_END}"; fi
        printf '  %-16s %-8s %b\n' "$name" "$port" "$st"
    done
    echo
    supervisorctl status 2>/dev/null || echo "supervisorctl 不可用"
    echo
    echo "访问入口:"
    echo "  Kibana(直连)      http://${HOST_IP:-本机IP}:5601"
    echo "  Kibana(经 nginx)  http://${HOST_IP:-本机IP}:80"
    echo "  ES REST           http://${HOST_IP:-本机IP}:9200"
    echo "  ElasticHD         http://${HOST_IP:-本机IP}:9800"
    echo "  nginx stub_status http://${HOST_IP:-本机IP}/status"
    echo
    echo "日志文件:"
    echo "  nginx access(JSON) ${NGINX_ACCESS_JSON}"
    echo "  nginx error        ${NGINX_ERROR_JSON}"
    echo "  supervisor         ${SUP_LOG_DIR}/*.log"
}

diagnose() {
    echo "--- supervisorctl status ---"; supervisorctl status 2>&1 || true
    echo "--- 监听端口 ---"
    if have ss; then
        ss -lntp 2>/dev/null | grep -E ':(80|5601|9200|9600|9800) ' || echo "无 ELK 端口监听"
    else
        netstat -lntp 2>/dev/null | grep -E ':(80|5601|9200|9600|9800) ' || echo "无 ELK 端口监听"
    fi
    echo "--- vm.max_map_count ---"; sysctl -n vm.max_map_count 2>/dev/null
    echo "--- ES 健康 ---"; curl -s -m 5 "http://127.0.0.1:9200/_cat/health?v" || echo "ES 不可达"
    echo "--- supervisor 侧日志末尾 ---"
    local f
    for f in "${SUP_LOG_DIR}"/*.log; do
        [[ -f $f ]] || continue
        echo ">>> $f"; tail -n 15 "$f"; echo
    done
    echo "--- 采集链路 ---"
    echo "  access_json.log 行数: $(wc -l < "$NGINX_ACCESS_JSON" 2>/dev/null || echo 0)"
    echo "  error_json.log  行数: $(wc -l < "$NGINX_ERROR_JSON" 2>/dev/null || echo 0)"
    ls -l "$LOGSTASH_DATA_DIR" 2>/dev/null | head -n 5
    echo "--- 索引与文档数 ---"
    curl -s -m 10 "http://127.0.0.1:9200/_cat/indices?v" || echo "ES 不可达"
    echo "--- ES 日志目录 ---"; ls -l "$ES_LOG_DIR" 2>/dev/null | head -n 10
    echo "--- 磁盘空间 ---"; df -h "$DATA_ROOT" 2>/dev/null | tail -n 1
    echo "--- 内存 ---"; free -m 2>/dev/null | head -n 2
}

usage() {
    cat << EOF
用法: $(basename "$0") [install|start|stop|restart|status|diagnose]

  install    完整部署：探测包 -> 系统调优 -> 装组件 -> 按序启动 -> 链路验证
  start      按依赖顺序启动全部组件
  stop       停止全部组件
  restart    重启全部组件
  status     查看端口、supervisor 状态与访问入口
  diagnose   打印排查信息（端口/日志/健康/链路/资源）
  不带参数   进入交互菜单

环境变量:
  ELK_HOST_IP=<IP>   指定对外 IP（默认自动探测）
  ES_HEAP=<2g>       ES 堆大小
  PKG_DIR=<目录>     安装包所在目录

版本（写死，与 .bak 一致）: nginx ${NGINX_VER} / ES·Kibana·Logstash ${ELK_VER}
EOF
}

do_install() {
    preflight
    tune_system
    setup_epel
    install_deps
    create_users
    create_dirs
    install_jdk
    install_nginx
    install_elasticsearch
    install_elasticHD
    install_kibana
    install_logstash
    fix_ownership
    install_supervisor
    start_stack
    echo
    ok "ELK 单机部署完成"
    show_status
}

do_stop() {
    require_root
    info "停止 ELK 全部组件..."
    supervisorctl stop elk:nginx elk:elasticHD elk:kibana elk:logstash elk:elasticsearch \
        > /dev/null 2>&1 || true
    ok "已停止"
}

do_start() {
    require_root
    install_supervisor
    start_stack
    show_status
}

interactive_menu() {
    local an
    echo "请选择要执行的操作:"
    echo "  1) install   完整部署（探测包+安装+按序启动+链路验证）"
    echo "  2) start     启动全部组件"
    echo "  3) stop      停止全部组件"
    echo "  4) restart   重启全部组件"
    echo "  5) status    查看状态"
    echo "  6) diagnose  诊断（端口/日志/健康/链路）"
    read -r -p "$(printf '%b' "${C_YELLOW}请输入编号或操作名: ${C_END}")" an
    case "$an" in
        1|install)  do_install ;;
        2|start)    do_start ;;
        3|stop)     do_stop ;;
        4|restart)  do_stop; do_start ;;
        5|status)   show_status ;;
        6|diagnose) diagnose ;;
        *)          err "请输入正确的选项"; exit 1 ;;
    esac
}

main() {
    local action="${1:-}"
    # 非 install 动作也要有 HOST_IP，否则 status 里的访问入口只能显示占位符
    if [[ -n $action && $action != "help" && $action != "-h" && $action != "--help" ]]; then
        HOST_IP=$(detect_hostip 2>/dev/null) || HOST_IP=""
    fi

    case "$action" in
        install)  do_install ;;
        start)    do_start ;;
        stop)     do_stop ;;
        restart)  do_stop; do_start ;;
        status)   show_status ;;
        diagnose) diagnose ;;
        -h|--help|help) usage ;;
        "")       interactive_menu ;;
        *)        err "未知操作: $action"; echo; usage; exit 1 ;;
    esac
}

main "$@"
