# PHP 源码编译安装（php-install.sh）

PHP + libzip + php-fpm 一体化源码编译脚本，装完即可被 nginx 通过 FastCGI 调用（配合 `nginx/` 目录里的脚本使用）。

## 用法

```bash
cd php
chmod +x php-install.sh

./php-install.sh                          # 交互输入 PHP 版本（和 libzip 版本）
PHP_VERSION=8.1.27 ./php-install.sh       # 指定版本
LIBZIP_VERSION=1.7.3 php-install.sh       # 指定 libzip 版本
FORCE=1 ./php-install.sh                  # 已安装也强制重新编译
```

## 默认布局

| 项 | 路径 |
|---|---|
| 安装前缀 | `/usr/local/php<主版本>`，如 `/usr/local/php8`、`/usr/local/php7` |
| 配置目录 | `/usr/local/php<版本>/etc` |
| FPM 主配置 | `etc/php-fpm.conf` |
| FPM 池配置 | `etc/php-fpm.d/www.conf` |
| 服务 | `php-fpm.service`（systemd），默认监听 `127.0.0.1:9000` |
| 动态库 | `/etc/ld.so.conf.d/php.conf` |
| PATH | `/etc/profile.d/php.sh`（幂等写入） |

## 编译特性

- 依赖**分组安装**，单组失败不中断整体，且去掉了原脚本里不存在的包名（如 `libssl-devel`）；
- `--enable-fpm`、`--enable-mbstring`、`--with-openssl`、`--with-curl`、`--with-mysqli`、`--with-pdo-mysql`、`--with-pdo-sqlite`、`--enable-soap`、`--enable-sockets`、`--enable-pcntl` 等常用扩展；
- 按 PHP 大版本区分 configure 参数（新版已移除 `--with-gd`、`--with-freetype-dir`、`--with-xmlrpc` 等，脚本会自动处理，避免新版本 configure 失败）；
- `php.ini`、`www.conf` **只在不存在时生成**，重复执行不会覆盖你改过的配置；
- 安装包在 `/root /data /tmp /opt /usr/local /usr/src` 及当前目录查找，找不到才下载；
- 装完轮询 php-fpm 是否真的起来（`systemctl show -p MainPID` 兼容 CentOS 7 的 systemd 219），失败时给出日志位置。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PHP_VERSION` | 空（交互） | 如 `7.4.33`、`8.1.27` |
| `LIBZIP_VERSION` | 空（交互） | 系统自带 libzip ≥ 0.11 时自动跳过 |
| `FORCE` | `0` | 置 1 强制重新编译 |
| `SRC_DIR` / `DOWNLOAD_DIR` | `/data` | 源码与下载目录 |

## 与 nginx 配合

nginx 侧配置示例（server 段）：

```nginx
location ~ \.php$ {
    root           /data/www;
    fastcgi_pass   127.0.0.1:9000;
    fastcgi_index  index.php;
    fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include        fastcgi_params;
}
```
