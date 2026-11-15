# MySQL 安装与初始化（mysql/）

两个脚本：`mysql_install.sh` 是完整的二进制安装/管理脚本；`mysql-initialize.sh` 是精简的“初始化数据目录 + 建库建表”脚本，通常用于容器镜像或快速起一个可用实例。

## 1. mysql_install.sh（推荐）

支持 **5.7.44 / 8.0.11 / 8.0.23** 三个版本，二进制包安装，systemd 托管。

```bash
cd mysql
chmod +x mysql_install.sh

./mysql_install.sh              # 交互菜单
./mysql_install.sh install      # 安装（每次都会询问装哪个版本）
./mysql_install.sh start|stop|restart|status
```

非交互场景（CI/批量）用环境变量指定版本：

```bash
MYSQL_VERSION=8.0.23 ./mysql_install.sh install
```

### 默认路径

| 项 | 路径 |
|---|---|
| 程序目录 | `/usr/local/mysql` |
| 数据目录 | `/data/db/mysql/data` |
| 日志目录 | `/data/db/mysql/logs`（`error.log`） |
| 配置文件 | `/etc/my.cnf` |
| socket / pid | `/usr/local/mysql/mysqld/mysqld.sock`、`mysqld.pid` |
| 服务 | `mysql.service`（systemd），端口 3306 |
| 环境变量 | `/etc/profile.d/mysql.sh` |

### 行为特点

- **每次 install 都会让你选版本**，不会静默装某个版本；
- 已装同版本时只做“补装”（配置、服务、启动），不重复解压；
- 已装**其他版本**且数据目录非空时，拒绝替换二进制，避免直接毁库；
- 初始化用 `mysqld --initialize`，随机临时密码会从 `error.log` 中提取并打印出来，需要登录后 `ALTER USER` 修改；
- 自动处理 `/etc/my.cnf` 冲突：先备份再按部署路径重写，`KEEP_MYCNF=1` 可保留原配置；
- 启动失败时打印 socket / 3306 端口 / `journalctl` / 错误日志 / 动态库等诊断信息（常见原因：旧 my.cnf 指向别的 datadir、缺 `libaio`/`libnuma`）。

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MYSQL_VERSION` | 空（交互） | `5.7.44` / `8.0.11` / `8.0.23` |
| `MYSQL_ROOT_PASSWORD` | 空 | **仅提示用**，脚本不会自动改密码 |
| `DATA_ROOT` | `/data/db/mysql` | 数据根目录 |
| `KEEP_MYCNF` | 空 | 置 1 则保留已有 `/etc/my.cnf` |
| `PKG_DIR` | 空 | 安装包搜索的最高优先级目录 |

安装包搜索顺序：`/root /data /date /tmp /opt /usr/local /usr/src` + 当前目录；`8.0.23` 等老版本只在 `downloads.mysql.com/archives` 提供 `.tar.xz`，脚本会自动走归档站。

## 2. mysql-initialize.sh（精简初始化）

面向“已经有 `/usr/local/mysql` 和数据目录”的场景，典型用途是 Docker 镜像启动时初始化：

```bash
./mysql-initialize.sh
```

它做的事：

1. 若 `/data/db/mysql/data/mysql` 不存在 → `chown mysql:mysql /data/db/mysql` 并 `mysqld --initialize-insecure`；
2. 后台启动 mysqld，轮询 `mysqladmin ping`（最多 30 秒）；
3. 设置 `root` 密码为 `root`，创建 `test` 库、`user` 表并插入两条示例数据（`lnmp-ok`、`doubao-test`）；
4. `mysqladmin shutdown` 后以前台方式 `exec mysqld`，适合作为容器主进程。

> ⚠️ 密码 `root/root` 和建表逻辑都是**写死**的，仅限本地学习/镜像构建；生产环境请用 `mysql_install.sh`。
