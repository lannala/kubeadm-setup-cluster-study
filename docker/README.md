# Docker 相关脚本（docker/）

| 脚本 | 作用 |
|---|---|
| `docker-install.sh` | 一键安装 Docker CE（阿里云源）、生成 daemon.json、启动并校验 |
| `tag.sh` | 批量给本地镜像打 tag 并推送到内网私有 registry |

---

## 1. docker-install.sh —— 安装 Docker

依据《Docker》课程文档整理，覆盖文档里的完整安装流程：环境检查 → IPv4 转发 → 时间同步 → 卸载旧版 → 加阿里云源 → 安装组件 → 镜像加速 → 启动校验。

### 快速开始

```bash
cd docker
chmod +x docker-install.sh

sudo ./docker-install.sh                    # 默认安装（install 可省略）
sudo ./docker-install.sh install --version 26.1.4
sudo ./docker-install.sh status             # 查看状态
sudo ./docker-install.sh uninstall --purge  # 卸载并删数据
```

### 子命令

| 子命令 | 说明 |
|---|---|
| `install` | 完整安装（缺省子命令，不带参数也执行它） |
| `configure` | 只按当前参数重写 `/etc/docker/daemon.json` 并重启 docker |
| `status` | 服务状态、版本、数据目录、镜像/容器数量 |
| `start` / `stop` / `restart` | 常规启停（systemctl） |
| `info` | 打印 docker info 关键项 |
| `uninstall` | 卸载软件包与配置；`--purge` 同时删除镜像/容器数据 |

### 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--version VER` | 仓库最新 | 指定 `docker-ce` 版本，如 `26.1.4`、`20.10.7` |
| `--repo aliyun\|official\|URL` | `aliyun` | 仓库来源 |
| `--mirror "u1,u2"` | 见下 | 镜像加速地址，逗号分隔 |
| `--no-mirror` | — | 不配置镜像加速 |
| `--data-root DIR` | `/data/docker_data` | 镜像/容器存储目录 |
| `--dns "ip1,ip2"` | `223.5.5.5,8.8.8.8` | daemon 的 DNS |
| `--insecure-registry ADDR` | 空 | 信任 HTTP 仓库，可重复传 |
| `--user NAME` | 空 | 把用户加入 `docker` 组 |
| `--no-start` | — | 装完不启动 |
| `--no-test` | — | 跳过 hello-world 测试 |
| `--skip-time` | — | 跳过时区/时间同步 |
| `--keep-daemon` | — | 已有 daemon.json 时不覆盖 |
| `-f, --force` | — | 强制重装（移除已有 docker-ce） |
| `--purge` | — | 卸载时删数据 |

### 安装做了什么

1. **环境检查**：发行版、架构、内核 ≥ 3.10；
2. **时区/时间**：`Asia/Shanghai`，优先 chronyd，退化为 `ntpdate ntp1.aliyun.com`；
3. **IPv4 转发**：写入 `/etc/sysctl.d/99-docker.conf` 的 `net.ipv4.ip_forward = 1` 并生效（文档强调不开启则容器无法访问外网），不执行 `systemctl restart network`，避免远程 SSH 断连；
4. **清理旧版**：移除 `docker docker-client docker-client-latest docker-common docker-latest docker-logrotate docker-selinux docker-engine` 等；
5. **仓库**：写 `/etc/yum.repos.d/docker-ce.repo`（默认阿里云，`--repo official` 用官方源）；
6. **安装**：`docker-ce`、`docker-ce-cli`、`containerd.io`，以及 `docker-buildx-plugin`、`docker-compose-plugin`（插件装不上时按文档的做法回退到手动 rpm）；
7. **daemon.json**：生成镜像加速、`data-root`、DNS、insecure-registry，并做 JSON 合法性校验（非法 JSON 会导致 docker 启动失败，文档特别提醒过）；
8. **启动校验**：`systemctl enable --now docker`、`docker version`、`docker info`，最后跑 `hello-world` 验证拉取链路。

### 默认 daemon.json

```json
{
  "data-root": "/data/docker_data",
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.1panel.live",
    "https://docker.m.daocloud.io",
    "https://mirror.ccs.tencentyun.com"
  ],
  "dns": ["223.5.5.5", "8.8.8.8"],
  "experimental": false,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "3"}
}
```

其中 `live-restore`、日志轮转是文档之外补充的常规实践；不需要可用 `--keep-daemon` 保留自己的配置，或 `configure --no-mirror` 重写。

### 镜像加速说明（重要）

- 课程文档里列的公共加速地址（ustc、网易、百度等）**不少已经不可用**，脚本默认只保留几个仍在维护的；
- 最稳的是阿里云 **ACR 专属加速地址**：控制台 → 容器镜像服务 → 镜像加速器，得到 `https://<你的ID>.mirror.aliyuncs.com`，然后：

  ```bash
  sudo ./docker-install.sh configure --mirror "https://<你的ID>.mirror.aliyuncs.com"
  docker info | grep -A3 'Registry Mirrors'
  ```

- `hello-world` 失败通常就是加速器不可用，换地址即可，不影响 Docker 本身。

### 版本说明

- CentOS 7（el7）仓库目前最高到 **26.1.4**，Docker 27 起不再提供 el7 的包；要装旧版本用 `--version 20.10.7` 这类写法，脚本会带 `--setopt=obsoletes=0` 防止被自动升级；
- 查看仓库可用版本：`yum list docker-ce --showduplicates | sort -r`。

### 注意事项

- `data-root` 默认 `/data/docker_data`（与文档一致），切换目录前先停 docker，旧数据不会自动迁移；
- CentOS 7 已 EOL，若基础 yum 源失效会先卡在 `yum install`，请先修好 `/etc/yum.repos.d/`（本仓库根目录的 `Centos-Base.repo` 可用）；
- SELinux 为 enforcing 时，挂载宿主机目录可能需要在卷后面加 `:z`；
- 加入 `docker` 组后需重新登录（或 `newgrp docker`）才生效；
- 本脚本**不设置** `exec-opts` 的 cgroup driver（Docker 默认 cgroupfs）。如果要接着部署 Kubernetes，`kubesetup prepare` 会重写 `daemon.json` 并写入 `native.cgroupdriver=systemd`，两者不冲突。

---

## 2. tag.sh —— 批量打 tag 并推送私有仓库

把本机所有 Docker 镜像批量重打成 `<私有仓库>/<镜像>:<tag>` 并推送，推送完默认清理本地临时 tag。

### 用法

```bash
cd docker
chmod +x tag.sh

./tag.sh                                  # 自动探测本机 IP + 端口 5000
./tag.sh -r 192.168.1.10 -p 5000          # 指定仓库地址
./tag.sh -n                               # 只打印将执行的命令
./tag.sh -e 'redis|mysql'                 # 排除名称/标签含关键字的镜像
./tag.sh -k                               # 推送后保留本地 tag（默认删掉）
./tag.sh -h                               # 帮助
```

### 选项

| 选项 | 说明 |
|---|---|
| `-k, --keep` | 推送后保留本地打好的 tag（默认推送完删除，节省磁盘） |
| `-e, --exclude` | 排除名称/标签中含该关键字的镜像；默认 `2.14.4`，传 `''` 关闭 |
| `-r, --registry` | 手动指定仓库地址（默认自动探测本机 IP） |
| `-p, --port` | 仓库端口，默认 `5000` |
| `-n, --dry-run` | 只打印将要执行的命令 |
| `-h, --help` | 帮助 |

环境变量同名可覆盖：`REGISTRY`、`REGISTRY_PORT`、`EXCLUDE`、`KEEP_LOCAL=1`。

### 行为要点

- 用 `docker images --format '{{.Repository}}:{{.Tag}}'` 取镜像，不依赖行号推算，过滤 `<none>` 与重复项；
- 自动探测本机 IP（`ip route get` → `hostname -I` → `ip -4 addr` 依次尝试），不写死网卡；
- 推送失败不会静默跳过，最后统一汇总并以非 0 退出；
- 只删除**本次新打出来**、带仓库前缀的 tag，绝不会误删本地原始镜像；
- 校验 docker 守护进程可用（带超时，避免无响应时卡死）。

### 前置条件

- 本机已装 docker 并能执行 `docker info`（root 或 docker 组）；
- 私有 registry 已运行且可访问（如 `docker run -d -p 5000:5000 --name registry registry:2`）；
- 若 registry 走 HTTPS 自签证书，需要先配置 docker 的 `insecure-registries`（可用 `docker-install.sh --insecure-registry`）。

### 典型用途

内网离线环境：在一台能联网的机器上 `docker pull` 好镜像，用本脚本统一推到内网 registry，业务机器再从内网拉取。
