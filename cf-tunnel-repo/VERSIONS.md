# 版本清单

所有交付文件都带版本号。改一次升一版，不要用同名覆盖。

| 文件 | 版本 | 用途 | 装到哪 |
|---|---|---|---|
| `sb-tunnel-v1.9.sh` | **v1.9 ★** | **用这个**。修 9 个 bug（详见 README） | 服务器 `/usr/local/bin/sb2` |
| `worker-v1.3.js` | **v1.3 ★** | **用这个**。修加密爆栈（>200 节点必炸） | Cloudflare Worker |
| `sb-tunnel-v1.7.sh` | v1.7 | 旧版。上报时带上 uuid/path，供面板「一键生成订阅」用 | 服务器 `/usr/local/bin/sb2` |
| `worker-v1.3-old.js` | v1.3 初版 | 已被 ★ 版取代。`/api/gen-sub` 一键生成本机节点订阅；面板加「生成本机 argo 节点订阅」卡片 | Cloudflare Worker |
| `sb-tunnel-v1.6.sh` | v1.6 | 旧版。新增 `--tunnel-poll`：每分钟轮询 Worker，网页点按钮即可让服务器换隧道 | 服务器 `/usr/local/bin/sb2` |
| `worker-v1.2.js` | v1.2 | 旧版。新增 `/api/rotate-request` 等接口 + 面板「🔄 让服务器换新隧道」按钮 | Cloudflare Worker |
| `sb-tunnel-v1.5.sh` | v1.5 | **最新**。新增命令行子命令：`--tunnel-rotate` 等，可不进菜单直接轮换 | 服务器 `/usr/local/bin/sb2` |
| `sb-tunnel-v1.4.sh` | v1.4 | 修复 9 处缺陷：502 判定、实际端口记录、孤儿进程清理、metrics 端口探测等 | 服务器 `/usr/local/bin/sb2` |
| `sb-tunnel-v1.2.sh` | v1.2 |[20] 换隧道后自动同步域名到节点元数据 + 重新生成 vless 链接 | 服务器 `/usr/local/bin/sb2` |
| `sb-tunnel-v1.1.sh` | v1.1 | 端口自动识别 + 清理旧隧道，但**不同步节点域名** | — |
| `sb-tunnel-v1.0.sh` | v1.0 | 旧版，端口靠猜、不清理旧进程，**已知缺陷**，勿用 | — |
| `sb-v30.sh` | v30 | 原版 sb，无 [20]，仅存档对照 | — |
| `tt-v1.0.sh` | v1.0 | 独立隧道管理（start/status/rotate/cron） | 服务器 `/usr/local/bin/tt` |
| `worker-v1.1.js` | v1.1 |。`/panel` 增加「手动更换隧道域名」表单：token 存 localStorage 一次、域名格式前端校验、显示服务端当前域名 | Cloudflare Worker |
| `worker-v1.0.js` | v1.0 | Cloudflare Worker（订阅 + 上报 + 面板） | Cloudflare 控制台 |
| `selfnodes-v1.0.yaml` | v1.0 | 76 个优选 IP 节点（域名已替换） | 客户端导入 |
| `install-v1.0.sh` | v1.0 | 隧道 agent 安装（Worker 内嵌用） | 服务器 |
| `deploy-v1.0.sh` | v1.0 | 同上，独立版 | 服务器 |
| `onekey-v1.0.sh` | v1.0 | 一键建节点 + 装隧道 | 服务器 |
| `onekey-standalone-v2.0.sh` | v2.0 | 零交互一键建节点 | 服务器 |
| `install-standalone-v1.0.sh` | v1.0 | 零交互装隧道 agent | 服务器 |
| `agent/tunnel-agent.sh` | — | 隧道 agent 本体 | 被内嵌 |
| `client/client-speed-watch.sh` | — | 路由器掉速检测 | 路由器 |

## 当前在用

- 服务器（NAT 机）：`sb-v30.sh` → 需换成 `sb-tunnel-v1.0.sh`
- 路由器：mihomo 配置 + `qoswatch.sh` + `client-speed-watch.sh`
- Cloudflare：`worker-v1.0.js`（线上仍是旧版，未更新）

## 校验

```sh
md5sum sb-tunnel-v1.0.sh   # e4ac982af0edec3d58c2f2b6e8e426d7
md5sum tt-v1.0.sh          # decde459399ee5d6ee681bb9b44183c7
md5sum worker-v1.0.js      # 86c6d8ffacac68a79b2ace22322a5c94
```
