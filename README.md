# kubesetup

CentOS 7.9 上一键部署 **Kubernetes 1.20.11** 的自包含脚本：Docker 运行时 + ipvs 模式 kube-proxy + Flannel CNI + ansible 批量扩容 worker，并自带节点缩容、证书续期、etcd 快照、CRI 端口开关等运维子命令。

脚本是**单文件**的：`Centos-Base.repo` 与 `kube-flannel-all.yml` 都内联在文件里，不需要额外的仓库文件或清单文件。

---

## 目录

- [快速开始](#快速开始)
- [kubesetup 系统命令](#kubesetup-系统命令)
- [命令补全](#命令补全)
- [子命令详解](#子命令详解)
- [选项与默认值](#选项与默认值)
- [配置持久化](#配置持久化)
- [典型工作流](#典型工作流)
- [对系统的改动清单](#对系统的改动清单)
- [故障排查](#故障排查)
- [安全注意事项](#安全注意事项)
- [已知约束](#已知约束)
- [验证状态](#验证状态)

---

## 快速开始

前置条件：CentOS/RHEL 7.x、root 权限、可访问阿里云镜像源、（扩容 worker 时）主机间可 SSH。

```bash
# 1. 上传并执行（首次）
chmod +x kubesetup.sh
sudo bash kubesetup.sh preflight          # 只检查环境，不改动任何东西

# 2. 预演一遍，确认将要执行的动作
sudo bash kubesetup.sh bootstrap --dry-run -v

# 3. 正式安装（交互式询问 worker 数量与 IP）
sudo bash kubesetup.sh bootstrap --apiserver-ip 192.168.83.148 --node-name k8s-001
#   → 提示输入 worker 数量与 IP，例如： 2  192.168.83.149 192.168.83.150
#   → 中间会逐台提示输入 worker 的 root 密码（用于自动分发 SSH 公钥）
```

`bootstrap` 是缺省子命令，因此 `sudo bash kubesetup.sh` 等价于 `sudo bash kubesetup.sh bootstrap`。

装完后 `kubesetup` 命令会出现在 `/usr/bin/`，之后可以直接：

```bash
kubesetup status
```

> 脚本文件名可任意改（下文示例统一用 `kubesetup.sh`），功能与安装出的命令名都不受影响，详见[关于改文件名](#关于改文件名)。

---

## kubesetup 系统命令

每次运行结束（任何子命令），脚本都会把**自己的一份独立副本**原子安装到 `/usr/bin/kubesetup`（`0755`），所以删掉源脚本后命令依然可用：

```bash
sudo bash /root/kubesetup.sh bootstrap     # 跑完
sudo rm -f /root/kubesetup.sh              # 删掉源文件
kubesetup status                           # 照常工作
```

- 安装发生在**子命令分派之前**，所以即使某个子命令中途失败，命令也已装好，方便按提示重试；
- 目标已存在且内容相同（`cmp`）时跳过，不产生无谓写入；
- 用 `cp` 到临时文件再 `mv -f` 原子替换，避免"半个可执行文件"；
- 想改名：`kubesetup install --cmd-name kx`（补全函数名、`/etc/bash_completion.d/<名>`、`profile.d` 里的 source 路径会一起跟着改）；
- 不要这个行为：`--no-install-cmd`，或单独用 `kubesetup install` / `kubesetup uninstall` 管理。

---

## 命令补全

装完后支持三套补全：

| 命令 | 补全内容 | 文件 |
|---|---|---|
| `kubectl` | 子命令、资源、flag | `/etc/profile.d/k8s-completion.sh` |
| `kubeadm` | 子命令、flag | 同上 |
| `kubesetup` | 17 个子命令 + 全部长选项 | `/etc/bash_completion.d/kubesetup` |

`kubesetup` 的补全清单**与参数白名单同源**（都来自脚本里的 `SUBCOMMANDS` / `CMD_OPTIONS` 数组），不会出现"能补全但跑不通"的漂移。补全用纯 bash 写的，不依赖 `bash-completion` 框架；`kubectl`/`kubeadm` 那套则要求系统装了 `bash-completion`。

生效方式：`/etc/profile.d` 只在**登录 shell** 生效，当前终端需要：

```bash
source /etc/profile.d/k8s-completion.sh
complete -p kubesetup        # 有输出说明注册成功
```

若 `kubesetup<TAB>` 补出来的是文件名，说明补全没注册，按上面两步查。

---

## 子命令详解

共 17 个，全部纯字母无连字符。**除 `preflight`、`status`、`certs` 可用普通用户执行外，其余均需 root**。

| 子命令 | 作用 | 改动系统 | 需 root |
|---|---|---|---|
| `bootstrap` | **缺省**。全流程：准备 → init → CNI → 询问是否加 worker → 显示状态 | ✅ | ✅ |
| `preflight` | 只读体检，逐项输出 `[ok]`/`[warn]`；未通过时退出码 1（便于 CI） | ❌ | 建议 |
| `prepare` | 单节点全套准备（yum repo、时间、防火墙、SELinux、swap、sysctl、IPVS、Docker、kubelet、补全） | ✅ | ✅ |
| `init` | 生成 kubeadm 配置并执行 `kubeadm init`，配好 kubeconfig，产出 join 命令 | ✅ | ✅ |
| `token` | 只生成/重造 join 命令（默认永不过期） | ⚠️ 写 token | ✅ |
| `completion` | 只安装 kubectl / kubeadm / kubesetup 补全 | ⚠️ 写 profile.d | ✅ |
| `cni` | 落盘 Flannel 清单并 `kubectl apply`，等待 flannel Pod 与节点 Ready | ✅ | ✅ |
| `scale` | 交互输入 worker 数量与 IP，经 ansible 批量准备 + join | ✅ 含远端 | ✅ |
| `drain` | **缩容**：drain 驱逐 Pod → 摘除节点 → 清理清单（`--drain-node` 指定单台） | 🔴 摘除节点 | ✅ |
| `ports` | 控制面 insecure 端口（10251/10252）开关：查看 / `--on` / `--off` | ✅ 改 manifest | ✅ |
| `certs` | 查看控制面证书有效期 | ❌ 只读 | 建议 |
| `renew` | 续期全部控制面证书并重启组件（CA 不可续） | ✅ | ✅ |
| `backup` | etcd 一致性快照（宿主机 etcdctl 或容器内 `docker exec`） | ⚠️ 只新增文件 | ✅ |
| `status` | 节点 + `get cs` + readyz + 控制面/CNI Pod + kube-proxy 模式 + 证书 + join 命令 | ❌ 只读 | ❌ |
| `reset` | `kubeadm reset -f` + 清 CNI/iptables/IPVS，会先要求确认（`-y` 跳过） | 🔴 破坏性 | ✅ |
| `install` | 只把脚本装成 `/usr/bin/kubesetup` | ⚠️ 写 /usr/bin | ✅ |
| `uninstall` | 删除 kubesetup 命令与其补全文件 | ⚠️ 删自己 | ✅ |

### prepare 做了什么

按顺序，可反复执行（幂等）：

1. **yum 仓库** — 原有 `*.repo` 移到 `/etc/yum.repos.d/back/`，写入内联的 `Centos-Base.repo`（内容按要求**原样不改**）
2. **时间同步** — 启用 `chronyd`，写入 `NTP_SERVER`
3. **防火墙** — 停用并 disable `firewalld`
4. **SELinux** — 置为 permissive
5. **swap** — `swapoff -a` 并注释 `/etc/fstab` 里的 swap 行
6. **内核参数** — `br_netfilter`、`ip_vs*` 模块；`/etc/sysctl.d/k8s.conf`；`ip_forward` 仅在缺失时追加
7. **IPVS** — 安装 `ipvsadm`，写 `/etc/sysconfig/modules/ipvs.modules`
8. **Docker** — 加 docker-ce 源、写 `/etc/docker/daemon.json`（`data-root=DOCKER_DATA_ROOT`、`exec-opts=native.cgroupdriver=systemd`）、启动并**校验 cgroup 驱动确实是 systemd**
9. **kubelet 三件套** — 锁定 `kubelet/kubeadm/kubectl-1.20.11`，写 `/etc/sysconfig/kubelet`（只留 `--node-ip`），然后 **`systemctl enable kubelet`（只 enable，不 start）** + `systemctl reset-failed kubelet`
   —— init 前 kubelet 缺 `/var/lib/kubelet/config.yaml`，启动必失败；若此时反复拉起会打满 systemd 的启动频率限制，导致 kubeadm 后在 `kubelet-start` 阶段真正启动它时被拒绝。启动交给 kubeadm。
10. **补全** — 见[命令补全](#命令补全)

> 默认**不会**执行 `systemctl restart network`：sysctl 变更并不需要它，而远程操作时这一步常把自己踢下线。确实需要时加 `--restart-network`。

**cgroup 驱动单一来源**：只由 kubeadm 的 `KubeletConfiguration.cgroupDriver` 下发（写进 `/var/lib/kubelet/config.yaml`，worker 通过 `kubelet-config` ConfigMap 继承）。早期版本还在 `/etc/sysconfig/kubelet` 和 `kubeletExtraArgs` 里各传一份 `--cgroup-driver`，属于重复下发，已移除。

### 首次 init 前 kubelet 为什么反复失败（含 CRI 报错）

`dockershim.sock` **由 kubelet 提供**，而首次 `kubeadm init` 之前 kubelet **必然起不来**——它启动时要读 `/var/lib/kubelet/config.yaml`，该文件正是 kubeadm 的 `kubelet-start` 阶段才写入的。缺这个文件，kubelet 直接 `klog.Fatal` 退出（`journalctl` 能看到完整栈）：

```
Started kubelet: The Kubernetes Node Agent.
F1108 15:48:20 server.go:198] failed to load Kubelet config file /var/lib/kubelet/config.yaml,
    error ... open /var/lib/kubelet/config.yaml: no such file or directory
```

由此引发的报错会因阶段不同：

```
# preflight 阶段（显式指定了 --cri-socket 时）
[ERROR CRI]: container runtime is not running:
  ... dial unix /var/run/dockershim.sock: connect: no such file or directory

# 若绕过 preflight，失败会推迟到拉镜像阶段
[ERROR ImagePull]: failed to pull image ...: dial unix .../dockershim.sock: no such file
```

**结论：默认不要指定 `--cri-socket`。** 留空时 kubeadm 走标准流程：写 `config.yaml` → 启动 kubelet → kubelet 提供 CRI socket → 拉镜像。脚本的行为：

| 情况 | 行为 |
|---|---|
| 默认（`CRI_SOCKET` 为空） | 配置里写 `nodeRegistration: {}`，交 kubeadm 自动探测；只检查 Docker 是否在跑 |
| 显式传 `--cri-socket` | 写进配置；若 socket 暂缺，仅放宽 preflight 的 CRI 一项并说明原因 |

> 只有机器上同时装了多个运行时、kubeadm 报 `found multiple CRI endpoints` 时，才需要显式指定。

### scale 的执行序列

`scale` 内部依次做（每步失败都会给出可执行的修复命令）：

1. **SSH 免密**（自动完成）
   - 本机无 `~/.ssh/id_rsa` 时自动 `ssh-keygen -t rsa -b 2048 -N ''`
   - 逐台 `ssh -o BatchMode=yes` 探测，已通的跳过
   - 对不通的节点逐台执行 `ssh-copy-id`，**由它提示你输入该节点密码**（不回显、不落盘）
   - 若系统里已有 `sshpass`，改为开头提示一次、全部复用（脚本不会去装它）
2. **探测远端 python** —— ansible 2.7 不会自动发现解释器，而 CentOS 8+ 只有 `python3`。按 `/usr/bin/python` → `/usr/libexec/platform-python` → `/usr/bin/python3` 顺序实测，把真实路径写进清单；都没有则报错退出
3. **写清单** —— `/root/k8s-workers.ini`（脚本自己用），并**幂等同步**到 `/etc/ansible/hosts` 的受管块（手工 `ansible workers -m ping` 不用带 `-i`）
4. **ping** —— 失败时打印完整输出与排查命令
5. **分发脚本** —— 把本脚本拷到各 worker 的 `/usr/bin/kubesetup`
6. **prepare** —— 远端执行 `kubesetup prepare`
7. **join** —— 逐台执行缓存的 join 命令，统计失败
8. **等待** —— 全部节点 `Ready`

所有 ansible 调用都带 `StrictHostKeyChecking=no`、`ConnectTimeout=10`、`BatchMode=yes`，**不会弹出 `continue connecting (yes/no)` 把脚本卡住**。

### 节点缩容（drain）

```bash
kubesetup drain --drain-node worker2     # 指定单台
kubesetup drain                          # 交互输入，空格分隔可多台
```

每台依次：

1. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=5m`
2. 失败时自动 `--force` 重试一次（仍失败则跳过该节点并汇总）
3. `kubectl delete node <node>`，并**同步清理** `/root/k8s-workers.ini` 与 `/etc/ansible/hosts` 里对应的行

安全护栏：

- **拒绝移除控制面**：检测到 `master` / `control-plane` 标签直接报错退出（单 master 架构，摘掉就没了）
- 节点不在集群中时 `[warn]` 并跳过，不中断其它节点
- 所有动作在 `confirm` 之后执行，`--dry-run` 只打印

缩容后该机器仍保留 kubelet 配置；想让它以后能干净地重新加入，在该节点执行 `kubesetup reset`。

### 控制面 insecure 端口（ports）

这是 `kubectl get cs` 显示 `Unhealthy` 的根因，值得单独说明。

kubeadm 1.19+ 在 `kube-scheduler.yaml` / `kube-controller-manager.yaml` 里默认带 `- --port=0`，即**关闭** 10251/10252 明文健康端口——**这是安全默认**。而 `kubectl get cs`（ComponentStatus，1.19+ 已废弃）读的正是这两个端口，于是显示：

```
controller-manager  Unhealthy  Get "http://127.0.0.1:10252/healthz": connect: connection refused
scheduler           Unhealthy  Get "http://127.0.0.1:10251/healthz": connect: connection refused
etcd-0              Healthy    {"health":"true"}
```

**这不是集群故障。** 真实健康状态看 `kubectl get --raw='/readyz?verbose'`。

```bash
kubesetup ports            # 查看当前是开还是关
kubesetup ports --on       # 注释掉 --port=0，让 get cs 全绿（实验环境）
kubesetup ports --off      # 恢复 --port=0（安全默认）
```

`--on` / `--off` 都是幂等的，改完会等静态 Pod 重建并用 `readyz` 复核。`kubesetup status` 也会把 `get nodes` 与 `get cs` 一起打印，并直接注明这一点。

> `kubesetup init --insecure-ports` 与 `ports --on` 等价（历史上的写法，保留兼容）。

### 证书管理（certs / renew）

```bash
kubesetup certs        # 查看全部控制面证书的到期时间
kubesetup renew        # 一键续期 + 重启控制面组件
```

`renew` 的要点：

- `kubeadm certs renew all` 只续**叶证书**，**CA 无法续期**（到期只能换新 CA 并重新签发，属破坏性操作，脚本不做，会提示）
- 续期后不会自动生效：脚本用「移走 `/etc/kubernetes/manifests/*.yaml` → 等 5 秒 → 移回」触发 kubelet 重建静态 Pod
- 最后用 `readyz` 等 apiserver 恢复，避免续期后集群不可用却不知道

### etcd 备份（backup）

```bash
kubesetup backup                                   # 默认 /root/etcd-backups
kubesetup backup --backup-dir /data/bk --backup-keep 3
```

kubeadm 部署的 etcd 是 **static pod**，宿主机通常没有 `etcdctl`。两条路：

| 情况 | 做法 |
|---|---|
| 宿主机有 `etcdctl` | 直接 `etcdctl snapshot save`，证书用 `/etc/kubernetes/pki/etcd/{ca,server}.crt/key` |
| 宿主机没有（常见） | `docker exec <etcd容器> etcdctl snapshot save /tmp/xxx.db` → `docker cp` 拷出 → 删容器内临时文件 |

- 容器用 `docker ps --filter name=k8s_etcd` 自动定位
- 落盘后校验非空，权限 `0600`
- 按 `ETCD_BACKUP_KEEP`（默认 7）只保留最近 N 份

> 恢复需停 etcd 后 `etcdctl snapshot restore`，属破坏性操作，脚本只做备份。步骤见[故障排查](#故障排查)。

### token 与永不过期

`TOKEN_TTL` 默认 **`0`，即永不过期**（kubeadm 语义：`--ttl 0` = 不过期，文档默认 24h）。学习环境反复加删 worker 时不必每次重造：

```bash
kubesetup token                      # 默认永不过期
kubesetup token --token-ttl 30m      # 临时收紧一次
kubesetup token --ttl-forever        # 等价于 --token-ttl 0
kubesetup init --token-ttl 24h       # 初始化时就限定有效期
```

生成后用 `kubeadm token list` **复核** `EXPIRES` 列，显示 `never` 才报 `[ok]`。join 命令缓存在 `~/kubeadm-join-command.txt`（`0600`）。

---

## 选项与默认值

所有选项都有同名环境变量，命令行优先级最高。

### 版本与网络

| 选项 | 环境变量 | 默认值 |
|---|---|---|
| `--k8s-version` | `K8S_VERSION` | `1.20.11` |
| `--service-cidr` | `SERVICE_CIDR` | `10.96.0.0/16` |
| `--pod-cidr` | `POD_CIDR` | `10.244.0.0/16` |
| `--image-repository` | `IMAGE_REPOSITORY` | `registry.cn-hangzhou.aliyuncs.com/google_containers` |
| `--apiserver-ip` | `API_ADVERTISE_ADDRESS` | 空 = 探测默认路由出口 IPv4 |
| `--cri-socket` | `CRI_SOCKET` | **空 = 由 kubeadm 自动探测**（推荐） |
| `--node-name` | `NODE_NAME` | 空 = 不改主机名 |

> **`--pod-cidr` 必须等于 Flannel 清单里的 `Network`**。清单按要求不可修改，其值为 `10.244.0.0/16`；脚本以清单为唯一事实来源，不一致会直接中止并提示正确取值。网段不匹配的后果是跨节点 Pod 不通。

### 运行时与镜像源

| 环境变量 | 默认值 |
|---|---|
| `DOCKER_DATA_ROOT` | `/data/docker_data` |
| `DOCKER_REPO_URL` | `http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo` |
| `NTP_SERVER` | `ntp1.aliyun.com` |
| `BASH_COMPLETION_PKG` | `bash-completion` |

### 扩容与产物路径

| 选项 | 环境变量 | 默认值 |
|---|---|---|
| `--inventory` | `WORKER_INVENTORY` | `/root/k8s-workers.ini` |
| `--ansible-hosts` | `ANSIBLE_HOSTS_FILE` | `/etc/ansible/hosts`（写入受管块） |
| `--no-sync-hosts` / `--sync-hosts` | `SYNC_ANSIBLE_HOSTS` | `1`（同步） |
| `--ansible-python` | `ANSIBLE_PYTHON_INTERPRETER` | 空 = 逐台自动探测 |
| `--ssh-user` | `ANSIBLE_SSH_USER` | `root` |
| `--ssh-pass` | `SSH_PASSWORD` | 空 = 用 `ssh-copy-id` 交互输入 |
| `--ssh-key` | `SSH_KEY_FILE` | `~/.ssh/id_rsa`（不存在会自动生成） |
| `--manifest` | `FLANNEL_MANIFEST` | `$HOME/kube-flannel-all.yml` |
| `--drain-node` | `DRAIN_NODE` | 空 = 交互输入；仅 `drain` |
| `--on` / `--off` | `PORTS_MODE` | `status`；仅 `ports` |
| `--backup-dir` | `ETCD_BACKUP_DIR` | `/root/etcd-backups` |
| `--backup-keep` | `ETCD_BACKUP_KEEP` | `7`（份） |
| `--keep-backups` | `KEEP_BACKUPS` | `0`（成功即删备份） |
| — | `BACKUP_ROOT` | `/var/backups/kubesetup` |
| `--log-keep` | `LOG_KEEP` | `2`（保留最近 N 份日志） |
| — | `JOIN_FILE` | `$HOME/kubeadm-join-command.txt` |
| — | `REMOTE_SCRIPT` | `/usr/bin/kubesetup` |
| — | `WORKER_HOST_PREFIX` | `worker` |
| — | `ANSIBLE_FORKS` | `5` |
| — | `WAIT_TIMEOUT` | `600`（秒） |

### token / 补全 / 命令安装

| 选项 | 环境变量 | 默认值 |
|---|---|---|
| `--token-ttl` | `TOKEN_TTL` | `0`（永不过期） |
| `--ttl-forever` | — | 等价 `--token-ttl 0` |
| `--no-completion` | `INSTALL_COMPLETION` | 默认安装（`1`） |
| `--no-install-cmd` | `INSTALL_SYS_CMD` | 默认安装（`1`） |
| `--cmd-name` | `SYS_CMD_NAME` | `kubesetup` |
| `--cmd-dir` | `SYS_CMD_DIR` | `/usr/bin` |
| `-l` / `--log-file` | `LOG_FILE` | `/var/log/kubeadm-install-<时间戳>.log` |

通用开关：`-y/--yes`（跳过确认）、`-n/--dry-run`（零副作用预演）、`-v/--verbose`、`--force`（已初始化时强制重建）、`--insecure-ports`（等价 `ports --on`）、`--restart-network`。

---

## 配置持久化

把变量写进 `/etc/k8s-install.conf`（bash 语法，`KEY=VALUE`），每次运行自动 source：

```bash
# /etc/k8s-install.conf
K8S_VERSION=1.20.11
POD_CIDR=10.244.0.0/16
IMAGE_REPOSITORY=registry.cn-hangzhou.aliyuncs.com/google_containers
TOKEN_TTL=0
ANSIBLE_SSH_USER=root
ETCD_BACKUP_KEEP=5
```

优先级：命令行 > 环境变量 > 配置文件 > 内置默认值。

---

## 典型工作流

### 分阶段学习（推荐）

每步都能单独观察效果、单独重跑（幂等）：

```bash
sudo kubesetup preflight      # 1. 看环境差什么
sudo kubesetup prepare        # 2. 打底：repo / 内核参数 / docker / kubelet
sudo kubesetup init           # 3. 起控制面，拿到 join 命令
sudo kubesetup cni            # 4. 装网络，节点 NotReady → Ready
sudo kubesetup scale          # 5. 加 worker
kubesetup status              # 随时看状态（含 get cs）

kubesetup backup              # 练熟了先做一份 etcd 快照
sudo kubesetup drain --drain-node worker2   # 缩容：学怎么优雅下线节点
kubesetup certs               # 看证书还有多久到期
sudo kubesetup ports --on     # 让 kubectl get cs 全绿（实验环境）
```

### 从零装一套 1 master + 2 worker

```bash
sudo bash kubesetup.sh bootstrap --apiserver-ip 192.168.83.148 --node-name k8s-001
#   → 交互输入 2 和 "192.168.83.149 192.168.83.150"
#   → 逐台输入 worker root 密码（自动分发公钥）

# 事后补一台
sudo kubesetup scale
```

### 节点掉了重新加入

```bash
kubesetup token                                  # 重造 join 命令
sudo kubesetup drain --drain-node worker2        # 先把旧记录摘掉（若节点还在集群里）
# 在 worker2 上：
sudo kubesetup reset
# 回到 master：
sudo kubesetup scale                             # 重新输入该节点
```

### 证书快到期

```bash
kubesetup certs            # 确认到期时间
sudo kubesetup renew       # 续期并重启组件
kubesetup certs            # 复核
```

---

## 对系统的改动清单

| 路径 | 动作 |
|---|---|
| `/etc/yum.repos.d/*.repo` | 原有文件移到 `back/` 备份（真有文件可挪时才建该目录） |
| `/etc/yum.repos.d/Centos-Base.repo` | 新建（0644，内容原样不改） |
| `/etc/selinux/config`、`/etc/fstab`、`/etc/hosts` 等 | 修改前备份到 `/var/backups/kubesetup/<时间戳>/`（见下） |
| `/etc/sysctl.d/k8s.conf` | 新建（0644） |
| `/etc/sysctl.conf` | **仅在缺少时追加** `net.ipv4.ip_forward`，不覆盖原内容 |
| `/etc/modules-load.d/k8s.conf` | 新建，开机加载 `br_netfilter` / `nf_conntrack` |
| `/etc/sysconfig/modules/ipvs.modules` | 新建（0755） |
| `/etc/docker/daemon.json` | 写入（已存在则先备份） |
| `/etc/sysconfig/kubelet` | 写入（已存在则先备份），内容只有 `--node-ip` |
| `/etc/kubernetes/kubeadm-init.yaml` | 由 `init` 生成 |
| `/etc/kubernetes/manifests/kube-{scheduler,controller-manager}.yaml` | 仅 `ports --on/--off` 时改写 `--port=0` |
| `/etc/profile.d/k8s-completion.sh` | 新建（0644），kubectl/kubeadm 补全 |
| `/etc/bash_completion.d/kubesetup` | 新建（0644），kubesetup 补全 |
| `/usr/bin/kubesetup` | 新建（0755） |
| `/etc/ansible/hosts` | 写入一个受管块 `[workers]`（`--no-sync-hosts` 可关） |
| `~/.bashrc` | 幂等追加 `KUBECONFIG` 与补全 source 行 |
| `~/kube-flannel-all.yml`、`~/kubeadm-join-command.txt`、`/root/k8s-workers.ini` | 生成，权限 `0600` |

服务：`firewalld` 停用并 disable，`chronyd` 启用，`docker`/`kubelet` 启用开机自启。

### 运行完不留垃圾

早期版本会在 `/etc`、`/root` 下散落 `xxx.bak.20260101-120000`，每跑一次多一批。现在：

| 项 | 行为 |
|---|---|
| 配置备份 | 统一收进 **`/var/backups/kubesetup/<时间戳>/`**（保持原路径层级），不再散落 `.bak` |
| 运行**成功** | 整个备份目录**自动删除**（连空父目录一起清） |
| 运行**失败** | 备份**保留**并打印路径，便于对照回滚 |
| 想强制保留 | `--keep-backups` |
| 日志 | 只保留最近 **2** 份 `kubeadm-install-*.log`（`--log-keep N` 可调） |
| 临时文件 | `mktemp`、静态 Pod 重启用的临时目录用完即删 |

仍会长期保留的三个文件是功能性的：

| 文件 | 为什么留着 |
|---|---|
| `~/kube-flannel-all.yml` | `kubesetup cni` 重发 CNI 要用；也是按要求原样保留的那份清单 |
| `~/kubeadm-join-command.txt` | `token` / `scale` 复用 join 命令 |
| `/root/k8s-workers.ini` | `scale` / `drain` 用的清单；只有跑过 `scale` 才生成 |

想换位置用 `--manifest`、`--inventory`；日志不想留用 `-l /dev/null`。

---

## 故障排查

先看本次运行日志（路径在输出末尾打印，默认 `/var/log/kubeadm-install-<时间戳>.log`）。

| 现象 | 处理 |
|---|---|
| `[ERROR CRI]` / `[ERROR ImagePull] ... dial unix .../dockershim.sock` | init **之前**出现属正常（kubelet 缺 `config.yaml`）。init **之后**才要查：`journalctl -u kubelet -b --no-pager -o cat \| head -40`、`systemctl is-active docker`、`docker info \| grep -i cgroup`（应 `systemd`） |
| kubelet 报 `failed to load Kubelet config file` | init 前正常；init 后仍报说明 `kubelet-start` 没跑成，`kubeadm reset -f` 重试 |
| `kubeadm init` 失败 | `journalctl -u kubelet -b --no-pager -o cat \| head -40` 看首个 `F`/`E` 行。注意 `journalctl` 默认带前缀，**必须 `-o cat`**，否则 `grep '^F'` 永远匹配不到 |
| `kubectl get cs` 显示 scheduler/controller-manager `Unhealthy` | **不是故障**。insecure 端口默认关闭。真实健康看 `kubectl get --raw='/readyz?verbose'`；想全绿用 `kubesetup ports --on` |
| 节点一直 `NotReady` | CNI 未就绪：`kubectl -n kube-flannel get pods`、`kubectl -n kube-flannel logs -f ds/kube-flannel-ds`；确认 `POD_CIDR` 与清单 `Network` 一致 |
| Pod 跨节点不通 | `cat /proc/sys/net/ipv4/ip_forward` 应为 `1`；`lsmod \| grep br_netfilter`、`grep -c . /etc/resolv.conf` |
| kube-proxy 非 ipvs | `kubesetup status` 会检查；确认用的是 `init` 生成的配置 |
| `kubesetup` 命令找不到 | 确认 `/usr/bin/kubesetup` 存在且在 `PATH`；`sudo kubesetup install`。旧会话需 `hash -r` |
| `kubesetup<TAB>` 补出文件名 | 补全未注册：`complete -p kubesetup` 无输出 → `source /etc/profile.d/k8s-completion.sh` |
| ansible `UNREACHABLE`（弹 `continue connecting`） | 免密没配好。`scale` 会自动逐台 `ssh-copy-id`；仍不通查对端 `PermitRootLogin`、22 端口 |
| ansible `ping` 失败但 SSH 通 | 多半是远端没有 python 或路径不对。脚本会逐台探测；仍失败用 `--ansible-python /usr/libexec/platform-python` |
| `ansible -m ping` 说找不到主机 | 清单在 `/root/k8s-workers.ini`；`/etc/ansible/hosts` 里只有受管块。用 `ansible workers -m ping` 或带 `-i` |
| `drain` 报无法驱逐 | 常见是 PDB 或本地存储：`kubectl get pdb -A`。脚本会自动 `--force` 重试一次 |
| `drain` 拒绝移除某节点 | 该节点是控制面（单 master 架构，有意拦截） |
| `renew` 后续期没生效 | 需重启静态 Pod；脚本会自动移走并移回 manifest，失败时手工 `systemctl restart kubelet` |
| 证书 CA 也过期了 | CA 不能续期，需按 kubeadm 官方流程换新 CA 并重新签发（脚本不做） |
| etcd 需要恢复 | `kubesetup backup` 只备份。恢复：停 kubelet → 移走 `/var/lib/etcd` → `etcdctl snapshot restore <db> --data-dir=/var/lib/etcd` → 启动 kubelet（先备份当前数据目录） |
| 想预演不落地 | 任何子命令加 `--dry-run`，只打印动作、零系统副作用（含 `install`/`uninstall`） |

---

## 安全注意事项

面向学习环境的默认值**不适合直接上生产**：

1. **join token 永不过期**（`TOKEN_TTL=0`）。token 是入场券，加完 worker 后建议 `kubeadm token delete <token-id>`，或改用 `--token-ttl 24h`。
2. **Chrony 用公网 NTP**，内网环境请改 `NTP_SERVER`。
3. **`--insecure-ports` / `ports --on` 只为让 `get cs` 好看**：10251/10252 对集群内任意 Pod 开放，生产必须保持关闭。
4. **SELinux 置 permissive**，生产建议 enforcing 并配好策略。
5. **`--dry-run` 也不能代替备份**：`reset`、`renew`、`ports` 都会改系统状态。
6. **`/etc/ansible/hosts` 的受管块**会被覆盖重写，自己的配置请写在块外。

---

## 已知约束

- **单 master 架构**：不支持多 master/HA，也不支持移除 master（`drain` 会拒绝）。
- **仅 CentOS/RHEL 7.x**：依赖 `yum`、`firewalld`、`chronyd`、systemd 的写法。
- **Kubernetes 固定 1.20.11**：镜像 tag、API 版本（`kubeadm.k8s.io/v1beta2`）、`dockershim` 都是按这个版本写的；换版本要同步改这些。
- **网络依赖外网**：yum 源、Docker 源、K8s 镜像源都是阿里云；离线环境需自建源。
- **两处正文不可改**：`Centos-Base.repo` 与 `kube-flannel-all.yml` 按要求原样保留，`POD_CIDR` 必须等于清单里的 `Network`（`10.244.0.0/16`）。
- **bash 4.2 兼容**：不使用 `${var@Q}` 等 4.4+ 语法；空数组展开统一用 `${arr[@]+"${arr[@]}"}`。

---

## 验证状态

已自动化验证：

- `bash -n` 语法检查
- 主回归 **56 项**断言 + 补全加载链路 **13 项**断言，全部通过
- 覆盖场景：子命令中途失败仍完成命令安装、删除源脚本后功能完好、参数白名单/补全清单/帮助文本三者同源、`--dry-run` 零系统副作用、`--token-ttl` 与 `EXPIRES=never` 复核、可选包安装失败不中断流程、补全链路与路径可配置性、init 前 CRI 参数取舍、cgroup 驱动单一来源、帮助文本跟随文件名
- 新增子命令定向验证：`ports --on/--off` 双向 + 幂等 + 与原始 manifest 逐字节一致、`drain` 拒绝 master、`backup` dry-run 不依赖 etcdctl、`certs` 输出
- 清理逻辑验证：成功删备份 / 失败保留 / 日志剪枝 / 无散落 `.bak`
- 5 项"污染自检"断言：测试过程绝不写入真实 `/usr/bin`、`/etc`

两处受保护正文（`Centos-Base.repo`、`kube-flannel-all.yml`）与原始文件**逐字节一致**，输出为纯 LF 换行。

---

### 关于改文件名

- **改源脚本名**（如 `kubeadm-install.sh` ↔ `kubesetup.sh`，或任意名字）：**功能零影响**。所有自引用都是运行时从 `${BASH_SOURCE[0]}` 推导的——`SELF_PATH`、帮助文本（按 basename 替换示例）、`install` 的安装目标（由 `SYS_CMD_NAME` 决定）、`scale` 的分发源、补全与清单署名。
- **改已安装的命令名**（`/usr/bin/kubesetup` → 别的）：不能直接 `mv`。补全函数名、`/etc/bash_completion.d/<名>`、`profile.d` 的 source 路径、`self_invocation()` 都绑定 `SYS_CMD_NAME`。正确做法：

```bash
kubesetup uninstall
kubesetup install --cmd-name kx        # 或 bootstrap 时直接 --cmd-name kx
```
