#!/bin/bash
#================================================================
# RabbitMQ 一键安装脚本（CentOS / RHEL 7，x86_64）
# 组件：Erlang 23.2.7 + RabbitMQ Server 3.10.0（含管理插件）
#
# 用法：
#   sudo bash rabbitmq-install.sh
#   sudo bash rabbitmq-install.sh --help
#   用环境变量覆盖默认值（注意 sudo 加 -E 保留环境变量）：
#   ADMIN_USER=xxx ADMIN_PASS=yyy sudo -E bash rabbitmq-install.sh
#
# 可用环境变量：
#   ADMIN_USER=admin      管理员账号
#   ADMIN_PASS=123456     管理员密码（仅限测试，生产环境务必修改）
#   ERLANG_VER=23.2.7     Erlang 版本（rabbitmq/erlang-rpm 的发布版本）
#   RABBITMQ_VER=3.10.0   RabbitMQ Server 版本
#   SKIP_ALIYUN_REPO=1    置 1 时不替换阿里云 yum 源
#
# 说明：
#   1. 脚本可重复执行：已安装的组件自动跳过，已存在的用户仅更新密码与权限；
#   2. 默认删除 guest 用户（ADMIN_USER 设为 guest 时除外）；
#   3. firewalld 运行时自动放行 5672(AMQP) 与 15672(管理界面)；
#      集群部署还需手工放行 4369(epmd) 与 25672(节点间通信)。
#================================================================
set -euo pipefail

#----------------- 可配置参数 -----------------
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-123456}"
ERLANG_VER="${ERLANG_VER:-23.2.7}"
RABBITMQ_VER="${RABBITMQ_VER:-3.10.0}"
SKIP_ALIYUN_REPO="${SKIP_ALIYUN_REPO:-0}"
ERLANG_RPM="erlang-${ERLANG_VER}-1.el7.x86_64.rpm"
ERLANG_URL="https://github.com/rabbitmq/erlang-rpm/releases/download/v${ERLANG_VER}/${ERLANG_RPM}"
WORKDIR="$(mktemp -d /tmp/rabbitmq-install.XXXXXX)"

#----------------- 输出与错误处理 -----------------
C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_END=$'\033[0m'
[ -t 1 ] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_END=''; }

info() { echo -e "${C_GREEN}[INFO]${C_END} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_END} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_END} $*"; }
die()  { echo -e "${C_RED}[ERROR]${C_END} $*" >&2; exit 1; }

trap 'rc=$?; echo -e "${C_RED}[ERROR]${C_END} 脚本在第 ${LINENO} 行执行失败（退出码 ${rc}），已中止。" >&2; exit $rc' ERR
trap 'rm -rf "$WORKDIR"' EXIT

usage() {
    cat <<EOF
用法：sudo bash $(basename "$0") [--help]

一键安装 Erlang ${ERLANG_VER} + RabbitMQ Server ${RABBITMQ_VER}（CentOS/RHEL 7，含管理插件）

可用环境变量：
  ADMIN_USER=admin      管理员账号
  ADMIN_PASS=123456     管理员密码（生产环境务必修改）
  ERLANG_VER=23.2.7     Erlang 版本
  RABBITMQ_VER=3.10.0   RabbitMQ Server 版本
  SKIP_ALIYUN_REPO=1    置 1 时不替换阿里云 yum 源

示例：
  sudo bash $(basename "$0")
  ADMIN_USER=mq ADMIN_PASS='Str0ng!Pass' sudo -E bash $(basename "$0")
EOF
}

#----------------- 参数与前置检查 -----------------
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "")        : ;;
    *)         die "未知参数：$1（使用 --help 查看用法）" ;;
esac

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户或 sudo 运行本脚本。"
[ -n "${ADMIN_USER}" ] && [ -n "${ADMIN_PASS}" ] || die "ADMIN_USER 与 ADMIN_PASS 不能为空。"

# sudo -E 会保留普通用户的 HOME，导致 rabbitmqctl 读不到 erlang cookie 而认证失败
export HOME=/root

[ "$(uname -m)" = "x86_64" ] || die "仅支持 x86_64 架构（Erlang RPM 为 x86_64 包）。"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
        centos|rhel) : ;;
        *) warn "当前系统（${ID:-未知}）不是 CentOS/RHEL，脚本可能不适用。" ;;
    esac
    [ "${VERSION_ID%%.*}" = "7" ] || warn "本脚本针对 CentOS/RHEL 7 编写，当前版本：${VERSION_ID:-未知}。"
else
    warn "无法读取 /etc/os-release，跳过系统版本检查。"
fi

# curl 是后续所有下载的前提，最小化安装的系统可能缺失
command -v curl >/dev/null 2>&1 || yum install -y curl

# 端口冲突预检（已安装 RabbitMQ 时跳过）
if ! rpm -q rabbitmq-server >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ':(5672|15672)$'; then
        warn "5672/15672 端口已被占用，RabbitMQ 安装后可能无法启动。"
    fi
fi

#----------------- 1. 配置阿里云 yum 源 -----------------
info "1/8 配置阿里云 yum 源..."
if [ "${SKIP_ALIYUN_REPO}" = "1" ]; then
    warn "SKIP_ALIYUN_REPO=1，跳过 yum 源替换。"
else
    if [ -f /etc/yum.repos.d/CentOS-Base.repo ]; then
        cp -a /etc/yum.repos.d/CentOS-Base.repo "/etc/yum.repos.d/CentOS-Base.repo.bak.$(date +%F_%H%M%S)"
    fi
    # CentOS 7 已 EOL：常规镜像不可用时回退到 vault 存档源
    if curl -fsSL --retry 3 --connect-timeout 15 -o /etc/yum.repos.d/CentOS-Base.repo \
            https://mirrors.aliyun.com/repo/Centos-7.repo \
        && yum clean all && yum makecache fast; then
        ok "阿里云 yum 源配置完成。"
    else
        warn "常规镜像不可用，回退到 aliyun vault 存档源..."
        curl -fsSL --retry 3 --connect-timeout 15 -o /etc/yum.repos.d/CentOS-Base.repo \
            https://mirrors.aliyun.com/repo/Centos-vault-7.repo
        yum clean all && yum makecache fast
        ok "aliyun vault 存档源配置完成。"
    fi
fi

#----------------- 2. 安装基础依赖 -----------------
info "2/8 安装基础依赖..."
# python3 来自 EPEL；EPEL 安装失败不影响主流程（rabbitmqadmin 可用系统 python2 运行）
yum install -y epel-release || warn "epel-release 安装失败，python3 将不可用（不影响 RabbitMQ 本身）。"
yum install -y ntpdate socat logrotate wget
yum install -y python3 || warn "python3 安装失败，rabbitmqadmin 将使用系统默认 python。"

info "同步系统时间并设置时区 Asia/Shanghai..."
ntpdate ntp1.aliyun.com || warn "时间同步失败，请检查网络后手动执行 ntpdate。"
timedatectl set-timezone Asia/Shanghai || warn "时区设置失败（容器环境可忽略）。"

#----------------- 3. 下载 Erlang -----------------
info "3/8 下载 Erlang ${ERLANG_VER}..."
curl -fSL --retry 3 --connect-timeout 15 -o "${WORKDIR}/${ERLANG_RPM}" "${ERLANG_URL}"
# 基本完整性校验：必须是合法的 RPM 包（防止下载截断或拿到错误页面）
rpm -qip "${WORKDIR}/${ERLANG_RPM}" >/dev/null 2>&1 || die "Erlang RPM 下载不完整或已损坏，请重新运行脚本。"
ok "Erlang RPM 下载并校验完成。"

#----------------- 4. 添加 RabbitMQ 仓库并安装 -----------------
info "4/8 添加 RabbitMQ packagecloud 仓库..."
if [ -f /etc/yum.repos.d/rabbitmq_rabbitmq-server.repo ]; then
    ok "packagecloud 仓库已存在，跳过添加。"
else
    curl -fsSL --connect-timeout 15 https://packagecloud.io/install/repositories/rabbitmq/rabbitmq-server/script.rpm.sh | bash
fi

# 检测到其他版本时给出兼容性提示
if rpm -q erlang >/dev/null 2>&1 && ! rpm -q "erlang-${ERLANG_VER}" >/dev/null 2>&1; then
    warn "检测到其他版本的 Erlang（$(rpm -q erlang)），如安装冲突请先 yum remove 'erlang*' 后重试。"
fi
if rpm -q rabbitmq-server >/dev/null 2>&1 && ! rpm -q "rabbitmq-server-${RABBITMQ_VER}" >/dev/null 2>&1; then
    warn "检测到其他版本的 RabbitMQ（$(rpm -q rabbitmq-server)），本脚本将尝试安装 ${RABBITMQ_VER}。"
fi

info "安装 Erlang ${ERLANG_VER} 与 RabbitMQ Server ${RABBITMQ_VER}..."
if rpm -q "erlang-${ERLANG_VER}" >/dev/null 2>&1; then
    ok "Erlang ${ERLANG_VER} 已安装，跳过。"
else
    yum install -y "${WORKDIR}/${ERLANG_RPM}"
fi

if rpm -q "rabbitmq-server-${RABBITMQ_VER}" >/dev/null 2>&1; then
    ok "RabbitMQ Server ${RABBITMQ_VER} 已安装，跳过。"
else
    # packagecloud 不同批次的 release 后缀不同，依次尝试
    yum install -y "rabbitmq-server-${RABBITMQ_VER}-1.el7.noarch" \
        || yum install -y "rabbitmq-server-${RABBITMQ_VER}-1.el7" \
        || yum install -y "rabbitmq-server-${RABBITMQ_VER}"
fi

#----------------- 5. 启动服务 -----------------
info "5/8 启动 RabbitMQ 并设置开机自启..."
systemctl daemon-reload
systemctl enable rabbitmq-server
if systemctl is-active --quiet rabbitmq-server; then
    ok "RabbitMQ 已在运行。"
else
    systemctl start rabbitmq-server
fi

# 等待节点就绪，避免后续 rabbitmqctl 因未启动完成而失败
info "等待 RabbitMQ 节点就绪..."
ready=0
for _ in $(seq 1 30); do
    if rabbitmq-diagnostics -q ping >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
[ "${ready}" -eq 1 ] || die "RabbitMQ 启动失败，请用 journalctl -u rabbitmq-server -xe 排查。"

#----------------- 6. 启用管理插件 -----------------
info "6/8 启用管理插件 rabbitmq_management..."
rabbitmq-plugins enable rabbitmq_management   # 运行中的节点动态生效，无需重启

# 节点就绪 ≠ 管理插件就绪，15672 需要额外等待
info "等待管理插件（15672 端口）就绪..."
ui=0
for _ in $(seq 1 30); do
    if curl -fs -o /dev/null http://127.0.0.1:15672/; then ui=1; break; fi
    sleep 2
done
[ "${ui}" -eq 1 ] || die "管理插件未就绪，请用 journalctl -u rabbitmq-server -xe 排查。"

#----------------- 7. 配置用户 -----------------
info "7/8 配置管理员用户 ${ADMIN_USER}..."
if [ "${ADMIN_USER}" = "guest" ]; then
    warn "ADMIN_USER=guest：保留 guest 用户（该用户默认仅允许本机登录）。"
elif rabbitmqctl list_users | awk '{print $1}' | grep -Fxq "guest"; then
    rabbitmqctl delete_user guest
else
    ok "guest 用户不存在，无需删除。"
fi
if rabbitmqctl list_users | awk '{print $1}' | grep -Fxq "${ADMIN_USER}"; then
    warn "用户 ${ADMIN_USER} 已存在，更新其密码、标签与权限。"
    rabbitmqctl change_password "${ADMIN_USER}" "${ADMIN_PASS}"
else
    rabbitmqctl add_user "${ADMIN_USER}" "${ADMIN_PASS}"
fi
rabbitmqctl set_user_tags "${ADMIN_USER}" administrator
rabbitmqctl set_permissions -p / "${ADMIN_USER}" ".*" ".*" ".*"

#----------------- 8. 安装 rabbitmqadmin CLI -----------------
info "8/8 安装 rabbitmqadmin 命令行工具..."
curl -fsSL --retry 3 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -o /usr/local/bin/rabbitmqadmin \
    http://127.0.0.1:15672/cli/rabbitmqadmin
chmod +x /usr/local/bin/rabbitmqadmin

cat > /root/.rabbitmqadmin.conf <<EOF
[default]
hostname = 127.0.0.1
port = 15672
username = ${ADMIN_USER}
password = ${ADMIN_PASS}
EOF
chmod 600 /root/.rabbitmqadmin.conf

# 验证管理账号可正常登录 API
curl -fs -u "${ADMIN_USER}:${ADMIN_PASS}" http://127.0.0.1:15672/api/whoami >/dev/null \
    || warn "管理账号 API 验证失败，请检查用户 ${ADMIN_USER} 的状态。"

#----------------- 防火墙放行 -----------------
if systemctl is-active --quiet firewalld; then
    info "放行防火墙端口 5672(AMQP) 与 15672(管理界面)..."
    firewall-cmd --permanent --add-port=5672/tcp --add-port=15672/tcp
    firewall-cmd --reload
    # 集群部署还需：firewall-cmd --permanent --add-port=4369/tcp --add-port=25672/tcp && firewall-cmd --reload
else
    warn "firewalld 未运行，跳过端口放行（请自行确认 5672/15672 可访问）。"
fi

# SELinux 提示（RPM 自带 targeted 策略，通常无需处理）
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    warn "SELinux 处于 Enforcing：如服务异常，请检查 /var/log/audit/audit.log。"
fi

#----------------- 完成 -----------------
echo
ok "安装完成！"
echo -e "${C_GREEN}管理界面：http://<服务器IP>:15672   用户：${ADMIN_USER}   密码：${ADMIN_PASS}${C_END}"
echo -e "${C_GREEN}AMQP 地址：amqp://${ADMIN_USER}:${ADMIN_PASS}@<服务器IP>:5672/${C_END}"
echo "  配置文件：/etc/rabbitmq/   日志：/var/log/rabbitmq/   服务：systemctl {start|stop|status|restart} rabbitmq-server"
if [ "${ADMIN_PASS}" = "123456" ]; then
    warn "正在使用默认密码，请尽快修改：rabbitmqctl change_password ${ADMIN_USER} <新密码>"
fi
echo
rabbitmqctl status
rabbitmqctl list_users
rabbitmqadmin list queues || warn "rabbitmqadmin 执行失败（通常是 python 环境问题），不影响 RabbitMQ 服务本身。"
