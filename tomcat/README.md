# JDK + Tomcat 安装（tomcat-install_.sh）

一个脚本同时管 JDK 和 Tomcat：自动判断“没装就装、装了没启动就启动”，也支持手动子命令。

## 用法

```bash
cd tomcat
chmod +x tomcat-install_.sh

./tomcat-install_.sh                  # 自动：没装就装，装了没启动就启动
./tomcat-install_.sh install          # 只安装
./tomcat-install_.sh start|stop|restart|status
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `JDK_MAJOR` | `8` | 需要安装的 JDK 大版本 |
| `TOMCAT_VERSION` | `8.5.29` | Tomcat 版本（从 `archive.apache.org` 下载） |
| `JDK_PACKAGE` | 空 | 手动指定本地 JDK 安装包路径 |
| `JDK_DIR` | `/usr/local/jdk` | JDK 安装目录 |
| `TOMCAT_DIR` | `/usr/local/tomcat` | Tomcat 安装目录 |
| `DOWNLOAD_DIR` | `/data` | 下载目录 |

## JDK 包命名兼容

脚本在本地目录查找 JDK 包时，兼容这几种常见命名：

- `jdk-8u40-linux-x64.gz`
- `jdk-8u40-linux-x64.tar.gz`
- `jdk-8_linux-x64_bin.tar.gz`（Adoptium）
- `OpenJDK8U-jdk_x64_linux_hotspot_<构建>.tar.gz`（Adoptium 旧命名）

找不到本地包再联网下载（Adoptium/Oracle 取决于版本）。

## 实现要点

- 下载统一用 `wget -O` 固定文件名，避免“下载名和 tar 名不一致导致解压失败”；
- 不再全盘 `find /`，按命名规则优先匹配本地包；
- 判断 Tomcat 是否运行用 `pgrep -f catalina.base`，不会误匹配编辑器/命令历史；
- 环境变量写到 `/etc/profile.d/jdk.sh`（幂等，root 和服务都生效），不往 `~/.bashrc` 重复追加；
- 目标目录已存在时先备份再替换；启动后轮询 PID/端口确认真的起来了。

## 端口

Tomcat 默认 `8080`（`conf/server.xml`），JDK 无端口。
