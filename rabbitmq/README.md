# RabbitMQ 一键安装（rabbitmq-install.sh）

在 CentOS / RHEL 7（x86_64）上安装 **Erlang 23.2.7 + RabbitMQ Server 3.10.0**，并启用管理插件。

## 用法

```bash
cd rabbitmq
chmod +x rabbitmq-install.sh

sudo bash rabbitmq-install.sh
sudo bash rabbitmq-install.sh --help

# 自定义管理员账号（sudo 需要 -E 保留环境变量）
ADMIN_USER=ops ADMIN_PASS='S3cret!' sudo -E bash rabbitmq-install.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ADMIN_USER` | `admin` | 管理员账号；设为 `guest` 时不删除内置 guest |
| `ADMIN_PASS` | `123456` | 管理员密码（**仅测试用，生产务必改**） |
| `ERLANG_VER` | `23.2.7` | 来自 `rabbitmq/erlang-rpm` 的发布版本 |
| `RABBITMQ_VER` | `3.10.0` | RabbitMQ Server 版本 |
| `SKIP_ALIYUN_REPO` | `0` | 置 1 则不替换阿里云 yum 源 |

## 脚本行为

- 可重复执行：已装的组件跳过，已存在的用户只更新密码与权限；
- 默认**删除 guest 用户**（`ADMIN_USER=guest` 除外）；
- 自动启用 `rabbitmq_management` 管理插件；
- `firewalld` 运行时自动放行 `5672`（AMQP）与 `15672`（管理界面）；集群还需手工放行 `4369`（epmd）与 `25672`（节点间）；
- 安装出错时 `trap ERR` 打印失败行号与退出码；临时目录自动清理。

## 端口

| 端口 | 用途 |
|---|---|
| 5672 | AMQP 协议 |
| 15672 | 管理界面 `http://<IP>:15672` |
| 4369 | epmd（集群） |
| 25672 | 节点间通信（集群） |

## 常用命令

```bash
systemctl status rabbitmq-server
rabbitmqctl status
rabbitmqctl list_users
rabbitmq-plugins list -e
```

管理界面默认用脚本里配置的 `ADMIN_USER / ADMIN_PASS` 登录。
