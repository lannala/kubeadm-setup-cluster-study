# nginx 源码编译与日常管理（nginx/）

| 脚本 | 作用 |
|---|---|
| `ngx-install.sh` | 源码编译安装 nginx（交互输入版本） |
| `ngx-control.sh` | 启停 / 重载 / 状态 / 平滑升级 / 卸载 |

两个脚本**互相独立**，`ngx-control.sh` 假设 nginx 已装在 `/usr/local/nginx`。

## ngx-install.sh —— 编译安装

```bash
cd nginx
chmod +x ngx-install.sh

./ngx-install.sh                        # 交互输入版本号
NGX_VERSION=1.24.0 ./ngx-install.sh     # 指定版本
```

- 默认前缀 `/usr/local/nginx`（`NGX_PREFIX` 可改），源码/安装包目录 `/data`（`SRC_DIR`、`DOWNLOAD_DIR`）；
- 在 `/root /data /tmp /opt /usr/local /usr/src` 及当前目录查找已有的 `nginx-x.y.z.tar.gz`，找不到才下载；
- 编译模块：`http_ssl`、`http_v2`、`http_realip`、`http_stub_status`、`http_gzip_static`、`http_sub`、`http_slice` 等常用模块 + `--with-pcre --with-pcre-jit`；
- 依赖按组安装，单组失败不影响其它组；`gd-devel` / `libxslt-devel` / `perl-devel` / `gperftools-devel` 按系统实际有没有自动裁剪；
- 先创建 `nginx` 用户再 configure；任一步失败立即退出并给出日志位置；
- 已安装时可选择跳过编译直接启动，启动前先 `nginx -t` 校验配置。

## ngx-control.sh —— 管理

```bash
./ngx-control.sh start | stop | restart | status
./ngx-control.sh reload     # 平滑重载配置（不中断连接）
./ngx-control.sh test       # nginx -t 校验配置
./ngx-control.sh update     # 编译新版本并平滑升级（USR2 → WINCH → QUIT）
./ngx-control.sh remove     # 卸载（先把 conf 打包备份）
```

环境变量：`NGX_HOME`（默认 `/usr/local/nginx`）、`NGX_CONF`（默认 `$NGX_HOME/conf/nginx.conf`）。

实现要点：

- 进程判断以 `logs/nginx.pid` + `kill -0` 为准，读不到再退回 `pgrep`；
- `stop` 用 `nginx -s quit` 并轮询确认进程真的退出，`restart` 会等端口释放后再启动，避免 `Address already in use`；
- `update` 会自检新二进制、备份旧二进制，失败自动回滚；
- 端口检查优先 `ss`（CentOS 8+ 已移除 `netstat`），没有 `ss` 再退回 `netstat`；
- `remove` 同时清理 `/usr/local/nginx` 与 `/etc/nginx`，删除前打包 `conf`。

## 端口

默认监听 80（由 `conf/nginx.conf` 决定）。日志默认在 `/usr/local/nginx/logs/`。
