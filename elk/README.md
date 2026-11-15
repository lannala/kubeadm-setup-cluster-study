# ELK 单机部署（elk-standalone.sh）

CentOS 7 上的一键单机 ELK 日志平台：nginx 收集访问/错误日志 → Logstash 解析 → Elasticsearch 存储 → Kibana 展示，并用 supervisor 统一托管进程、ElasticHD 提供 ES 图形管理。

## 组件与版本

| 组件 | 版本 | 说明 |
|---|---|---|
| Elasticsearch | 8.13.1 | 单节点，`xpack.security.enabled: false`（学习环境） |
| Kibana | 8.13.1 | 中文界面，nginx 80 端口反向代理 |
| Logstash | 8.13.1 | file 输入，读 nginx 的 JSON 日志 |
| nginx | 1.26.3 | 源码编译，输出 `access_json.log` / `error_json.log` |
| ElasticHD | 压缩包内版本 | ES 图形化管理，`0.0.0.0:9800` |
| supervisor | 系统包 | 托管上述 5 个进程 |

## 脚本用法

```bash
cd elk
chmod +x elk-standalone.sh

./elk-standalone.sh            # 交互菜单
./elk-standalone.sh install    # 完整部署并按序启动
./elk-standalone.sh start|stop|restart|status
./elk-standalone.sh diagnose   # 打印排查信息（进程/端口/日志）
```

执行前脚本会**优先在本机常见目录找安装包**（`/root /data /date /tmp /opt /usr/local /usr/src` 及当前目录），找不到才联网下载，适合离线环境。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ELK_HOST_IP` | 自动探测 ens33/eth0/ens192 | 对外 IP，写进 Kibana/Logstash 配置 |
| `ES_HEAP` | `2g` | ES 堆大小 |
| `NGINX_PREFIX` | `/usr/local/nginx-1.26.3` | nginx 安装目录 |
| `PKG_DIR` | 空 | 追加为**最高优先级**的安装包搜索目录 |
| `SRC_DIR` | `/data` | 源码/安装包目录 |

## 端口

| 端口 | 服务 |
|---|---|
| 80 | nginx（反代 Kibana，`http://<IP>/`） |
| 9200 / 9300 | Elasticsearch REST / 集群通信 |
| 5601 | Kibana |
| 9800 | ElasticHD |

## 目录布局

| 路径 | 内容 |
|---|---|
| `/usr/local/elasticsearch-8.13.1` | ES 程序 |
| `/usr/local/kibana-8.13.1` | Kibana 程序 |
| `/usr/local/logstash-8.13.1` | Logstash 程序（配置在 `config/conf.d/logstash.conf`） |
| `/data/elasticsearch/{data,logs}` | ES 数据与日志 |
| `/data/kibana/log`、`/data/logstash` | Kibana、Logstash 数据 |
| `/data/nginx/log` | nginx 日志（`access_json.log`、`error_json.log`） |
| `/data/supervisor/log` | supervisor 日志 |

## 数据流

```
浏览器请求 → nginx(80) ── JSON 访问日志 ─┐
                                        ├→ Logstash(file input) → ES 索引 logstashaa-<type>-YYYY.MM.dd → Kibana
nginx 错误日志 ─────────────────────────┘
```

Kibana 需要在界面里手动创建索引模式 `logstashaa-*` 才能看到数据。

## 注意

- 这是**单机**版本（单 ES 节点、无副本），仅适合学习/测试；生产要做多节点集群并开启安全认证。
- `elk-standalone.sh.bak` 是该脚本的旧版本备份，不要执行，仅用于对比历史实现。
- 进程由 supervisor 管理，`systemctl` 里没有独立的 es/kibana 服务；排查优先跑 `./elk-standalone.sh diagnose`。
