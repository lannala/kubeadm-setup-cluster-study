# 运维脚本集合（CentOS 7）

本目录是在 CentOS 7.9 学习/实验环境中积累的一套独立运维脚本，按服务分目录存放，每个目录配一份 README，说明用法、路径、端口和注意事项。

所有脚本都是**单文件、自包含**的 bash 脚本：自带安装包查找、依赖安装、配置生成、systemd 托管和启动校验，互相之间没有调用依赖，可以单独拷走使用。

---

## 目录结构

```
jiaoben/
├── README.md                      ← 本文件（总览）
├── Centos-Base.repo               ← yum 源（阿里云 CentOS 7.9 vault）
│
├── docker/
│   ├── docker-install.sh          ← Docker CE 安装 + daemon.json 配置
│   ├── tag.sh                     ← 批量打 tag 并推送私有 registry
│   └── README.md
├── elk/
│   ├── elk-standalone.sh          ← ELK 8.13.1 单机一键部署
│   └── README.md
├── kubesetup/
│   ├── kubesetup.sh               ← Kubernetes 1.20.11 一键部署（18 个子命令）
│   └── README.md                  ← 极详细的专项文档
├── mysql/
│   ├── mysql_install.sh           ← MySQL 5.7.44 / 8.0.11 / 8.0.23 安装
│   ├── mysql-initialize.sh        ← 数据目录初始化 + 建库建表（容器用）
│   └── README.md
├── nginx/
│   ├── ngx-install.sh             ← nginx 源码编译安装
│   ├── ngx-control.sh             ← 启停/重载/平滑升级/卸载
│   └── README.md
├── php/
│   ├── php-install.sh             ← PHP + libzip + php-fpm 源码编译
│   └── README.md
├── rabbitmq/
│   ├── rabbitmq-install.sh        ← Erlang 23.2.7 + RabbitMQ 3.10.0
│   └── README.md
├── tomcat/
│   ├── tomcat-install_.sh         ← JDK 8 + Tomcat 8.5.29
│   └── README.md
├── zookeeper/
│   ├── zookeeper-install.sh       ← ZooKeeper 单机/集群/伪集群
│   └── README.md
│
├── lnmp-Dockerfile.md             ← 镜像构建说明（非脚本）
├── mvn-Dockerfile.md              ← 镜像构建说明（非脚本）
├── nginx-Dockerfile.md            ← 镜像构建说明（非脚本）
├── tomcat-Dockerfile.md           ← 镜像构建说明（非脚本）
├── lnmp-dockerfile.tar.gz         ← LNMP 镜像构建上下文（约 684 MB）
└── desktop.ini                    ← Windows 文件夹配置，无关
```

---

## 脚本总览

| 目录 | 脚本 | 作用 | 版本 | 关键端口 |
|---|---|---|---|---|
| `kubesetup/` | `kubesetup.sh` | 一键部署单 master K8s（Docker + ipvs + Flannel），ansible 扩容、drain、证书、备份 | Kubernetes 1.20.11 | 6443 / 30080 |
| `docker/` | `docker-install.sh` | Docker CE 安装：IPv4 转发、阿里云源、daemon.json（镜像加速/data-root）、启动校验 | 仓库最新（el7 最高 26.1.4） | — |
| `docker/` | `tag.sh` | 批量给本地镜像打 tag 并推内网 registry | — | 5000 |
| `elk/` | `elk-standalone.sh` | 单机 ELK 日志平台（nginx 采集 → Logstash → ES → Kibana） | ELK 8.13.1 + nginx 1.26.3 | 80 / 9200 / 5601 / 9800 |
| `mysql/` | `mysql_install.sh` | MySQL 二进制安装、systemd 托管、随机密码提取 | 5.7.44 / 8.0.11 / 8.0.23 | 3306 |
| `mysql/` | `mysql-initialize.sh` | 初始化数据目录、设 `root/root`、建 `test` 库（容器入口） | — | 3306 |
| `nginx/` | `ngx-install.sh` | nginx 源码编译（交互选版本、模块自动裁剪） | 用户指定 | 80 |
| `nginx/` | `ngx-control.sh` | nginx 启停、`reload`、`test`、平滑升级、卸载 | — | 80 |
| `php/` | `php-install.sh` | PHP + libzip + php-fpm 源码编译，systemd 托管 | 用户指定（7.x / 8.x） | 9000 |
| `rabbitmq/` | `rabbitmq-install.sh` | Erlang + RabbitMQ 安装，管理插件、管理员账号 | Erlang 23.2.7 + RabbitMQ 3.10.0 | 5672 / 15672 |
| `tomcat/` | `tomcat-install_.sh` | JDK + Tomcat 安装与启停 | JDK 8 + Tomcat 8.5.29 | 8080 |
| `zookeeper/` | `zookeeper-install.sh` | ZooKeeper 单机 / 3 节点集群 / 单机伪集群 | 默认 3.9.7（可 `-v 3.9.4`） | 2181 / 2888 / 3888 |

---

## 通用约定

1. **目标系统**：CentOS / RHEL 7.x（x86_64），需要 root。部分脚本（kubesetup）对 7.9 验证最充分。
2. **用法统一**：无参数运行多数脚本会进交互菜单；也支持子命令（install / start / stop / restart / status 等），详见各目录 README。
3. **离线友好**：安装包优先在本机目录查找，顺序大致为
   `/root /data /date /tmp /opt /usr/local /usr/src` + 当前目录；
   找不到才联网下载。可用的覆盖变量：
   - `PKG_DIR=/date` —— 追加为最高优先级搜索目录
   - `SRC_DIR` / `DOWNLOAD_DIR` —— 源码与下载目录（默认 `/data`）
4. **幂等**：重复执行一般会跳过已完成的步骤或只做补装；破坏性操作（覆盖配置、替换二进制）会先备份。
5. **systemd 服务名**：docker、mysql、php-fpm、rabbitmq-server、zookeeper；Tomcat/ELK 组件用 startup.sh / supervisor 管理。

---

## kubesetup（重点脚本）

kubesetup/kubesetup.sh 是这套脚本里最完整的一个：CentOS 7.9 单 master 部署 Kubernetes 1.20.11，内置 18 个子命令（bootstrap / preflight / prepare / init / cni / ingress / scale / drain / certs / renew / backup / status / reset 等），并把 `Centos-Base.repo` 与 Flannel / ingress-nginx 清单内联在脚本里。

首次部署：

```bash
cd kubesetup
sudo bash kubesetup.sh preflight      # 只体检
sudo bash kubesetup.sh bootstrap --apiserver-ip 192.168.83.148 --node-name k8s-001
```

完整说明（选项、默认值、故障排查、对系统的改动清单）见 [kubesetup/README.md](kubesetup/README.md)。

---

## 常见组合场景

### Docker 环境（很多脚本的前置）

```bash
cd docker && sudo ./docker-install.sh            # 装 Docker CE + 镜像加速
sudo ./docker-install.sh status                  # 查看状态
sudo ./docker-install.sh configure --mirror "https://<你的ID>.mirror.aliyuncs.com"
```

装完 `docker info` 里能看到 `Registry Mirrors` 即加速生效；Kubernetes（kubesetup）也依赖 Docker，可先装这个再跑 kubesetup。

### LNMP（nginx + MySQL + PHP）

```bash
cd nginx && ./ngx-install.sh            # 1. 编译 nginx
cd ../mysql && ./mysql_install.sh install   # 2. 装 MySQL（交互选版本）
cd ../php && ./php-install.sh           # 3. 编译 PHP + php-fpm
```

装完在 nginx 里把 `fastcgi_pass` 指向 `127.0.0.1:9000` 即可跑 PHP。

### 日志平台

`elk/elk-standalone.sh install` —— 单机 ELK，开箱即用（单节点、关闭 xpack 安全，仅学习环境）。

### 消息队列

`rabbitmq/rabbitmq-install.sh`，装完访问 `http://<IP>:15672`（默认 `admin/123456`，记得改）。

### 注册中心 / 协调服务

`zookeeper/zookeeper-install.sh standalone`（单机）或 `cluster`（三节点集群），Kafka 等组件依赖它。

### 内网镜像同步

在能联网的机器上 `docker pull` 好镜像后，`docker/tag.sh -r <内网registry>` 一把推到私有仓库。

---

## 相关文件说明

| 文件 | 说明 |
|---|---|
| `Centos-Base.repo` | 阿里云 CentOS 7.9 vault 源（base/updates/extras/plus/contrib/epel + k8s v1.28 + docker-ce + elrepo），与 kubesetup 内联的 repo 同源 |
| `*-Dockerfile.md` | lnmp / mvn / nginx / tomcat 的镜像构建笔记，配合 `lnmp-dockerfile.tar.gz` 使用 |
| `lnmp-dockerfile.tar.gz` | LNMP 镜像构建上下文（约 684 MB），体积大，注意不要误提交到 git |

---

## 端口速查

| 服务 | 端口 |
|---|---|
| Docker（仅开 TCP 时） | 2375 / 2376 |
| nginx | 80 |
| MySQL | 3306 |
| PHP-FPM | 9000 |
| Tomcat | 8080 |
| RabbitMQ | 5672 / 15672（管理） |
| ZooKeeper | 2181 / 2888 / 3888（Admin 8080+） |
| Elasticsearch | 9200 / 9300 |
| Kibana | 5601 |
| ElasticHD | 9800 |
| Kubernetes API | 6443 |
| ingress-nginx NodePort | 30080 |
