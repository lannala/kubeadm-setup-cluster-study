# ZooKeeper 安装（zookeeper-install.sh）

CentOS / RHEL 一键安装 Apache ZooKeeper，一张脚本覆盖**单机、集群、伪集群**三种模式，附 systemd 托管、防火墙放行和启动自检。

## 三种模式

| 模式 | 场景 | 说明 |
|---|---|---|
| `standalone` | 单机 / 开发测试 | 单节点，配置里**不写** `server.X` |
| `cluster` | 生产集群（3/5/7 台） | 每台机器各跑一次，`--myid` 不同、`--servers` 相同 |
| `pseudo` | 单机学集群 | 一台机器起 3 个实例（2181/2182/2183），独立数据目录 |

## 常用命令

```bash
cd zookeeper
chmod +x zookeeper-install.sh

# 单机
./zookeeper-install.sh standalone

# 集群：在所有节点执行，--servers 必须完全一致，只改 --myid / --hostname
./zookeeper-install.sh cluster --myid 1 --servers "zk-1,zk-2,zk-3" \
  --hosts "192.168.60.147=zk-1,192.168.60.133=zk-2,192.168.60.137=zk-3" \
  --hostname zk-1
# zk-2、zk-3 同理，只把 --myid 换成 2、3

# 伪集群（单机 3 实例）
./zookeeper-install.sh pseudo --nodes 3

# 离线安装 / 指定版本 / 卸载
./zookeeper-install.sh standalone --pkg /opt/apache-zookeeper-3.9.7-bin.tar.gz
./zookeeper-install.sh standalone -v 3.9.4
./zookeeper-install.sh uninstall [--purge]
```

## 常用选项

| 选项 | 说明 |
|---|---|
| `-v, --version` | ZooKeeper 版本，默认 `3.9.7` |
| `--pkg FILE` | 使用本地 tar.gz（离线安装） |
| `--myid N` | 集群模式必填，本节点编号 |
| `--servers LIST` | `zk-1,zk-2,zk-3` 或 `zk-1:2888:3888,...` |
| `--hosts LIST` | `ip=主机名` 追加到 `/etc/hosts`（已存在则跳过） |
| `--hostname NAME` | 安装前设置主机名 |
| `--firewall open\|stop\|skip` | 开放端口（默认）/ 关防火墙 / 不动防火墙 |
| `--no-start` | 装完不启动 |
| `--jdk-home` / `--jdk-tar` | 指定已有 JDK / 用 tar 包安装 JDK |
| `--force` | 已安装时强制重装 |

## 默认布局

| 项 | 路径 |
|---|---|
| 程序 | `/usr/local/zookeeper` |
| 配置 | `/usr/local/zookeeper/conf/zoo.cfg` |
| 数据 | `/data/zookeeper`（集群的 `myid` 也在这里） |
| 日志 | `/data/zookeeper/logs` |
| 服务 | `/etc/systemd/system/zookeeper.service` |
| 环境变量 | `/etc/profile.d/zookeeper.sh` |
| 伪集群 | `/data/zk-cluster/zk{1,2,3}/`，启停用 `/usr/local/zookeeper/bin/zk-cluster.sh` |

## 端口

| 端口 | 用途 |
|---|---|
| 2181 | 客户端连接 |
| 2888 | Leader/Follower 数据同步 |
| 3888 | Leader 选举 |
| 8080+ | AdminServer（3.5+ 自带，**脚本自动避开占用端口**） |

伪集群三个实例：客户端 2181/2182/2183，同步与选举端口依次 +1。

## 版本说明（重要）

- 脚本默认装 **3.9.7**。原 PDF 文档写的是 3.9.4，但阿里云镜像现在只保留 3.7.2 / 3.8.8 / 3.9.7，3.9.4 已 404，`archive.apache.org` 国内又很慢；3.9.7 与 3.9.4 的配置参数完全一致。
- 需要严格复现文档时：`./zookeeper-install.sh standalone -v 3.9.4`，脚本会自动走 archive 源。

## 安装后的行为

- 自动生成 `zoo.cfg`（含 `tickTime`、`initLimit`、`syncLimit`、`autopurge`、`4lw.commands.whitelist`），并备份旧配置；
- 自动写 `myid`，校验 `--myid` 范围；主机名与 `server.N` 指向不一致时告警；
- 启动后等待 `Mode: leader/follower/standalone`，并用 `ruok` 探测；
- **集群首次部署只启动第一台时不会选主**（需要过半节点在线），脚本此时只提示、不报错，装完其它节点再验证。

## 验证

```bash
systemctl status zookeeper
/usr/local/zookeeper/bin/zkServer.sh status        # 预期 Mode: leader / follower
echo ruok | nc 127.0.0.1 2181                      # 预期 imok
/usr/local/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181
```
