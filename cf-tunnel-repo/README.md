# CF Tunnel

一条命令在任意 Linux 服务器上部署 **Argo 临时隧道节点 + 自动轮换 + 订阅分发**。
所有脚本由同一个 Cloudflare Worker 提供，不依赖 GitHub Raw，不会被墙、不会因上游删库失效。

## 仓库

<https://github.com/linlinaa2/cf-tunnel>

## 一行安装

装隧道 agent（用 Worker 域名，参数自动注入，推荐）：

```sh
(curl -LfsS https://你的项目.pages.dev/one -o /tmp/ok.sh && sh /tmp/ok.sh)
```

从本仓库直装（需要先改 `install-standalone.sh` 顶部两行填你自己的 API 和 token）：

```sh
(curl -LfsS https://raw.githubusercontent.com/linlinaa2/cf-tunnel/main/install-standalone.sh \
  -o /usr/local/bin/tunnel || wget -q https://raw.githubusercontent.com/linlinaa2/cf-tunnel/main/install-standalone.sh \
  -O /usr/local/bin/tunnel) && chmod +x /usr/local/bin/tunnel && tunnel
```

拉 Worker 源码：

```sh
curl -LfsS https://raw.githubusercontent.com/linlinaa2/cf-tunnel/main/worker.js -o worker.js
```

装完之后，路由器上的订阅地址填：

```
https://你的项目.pages.dev/sub/<你的订阅ID>
```

订阅里的 `*.trycloudflare.com` 会被自动替换成当前隧道域名 —— **隧道换了，订阅不用重导**。

## 它解决什么问题

Argo Quick Tunnel 的域名是临时的，重启就换。传统做法是每次换域名都要重新生成订阅、重新导入客户端。

这套方案把「当前隧道域名」存进 Cloudflare KV，Worker 在返回订阅时动态替换。客户端只需要一个固定订阅地址，永远不用改。

## Worker 提供的全部路径

| 路径 | 内容 |
|---|---|
| `/` | 订阅生成页 |
| `/sub/{id}` | 订阅（域名自动替换） |
| `/one` `/1` `/go` `/onekey` `/ok` `/init` `/setup` `/new` | 一键：建节点 + 换隧道 + 上报 |
| `/tunnel.js` `/install.sh` `/i.sh` | 只安装隧道 agent |
| `/sb` `/sb.sh` | singbox-lite 管理脚本（内置） |
| `/panel` `/admin` | 管理面板 |
| `POST /api/report` | 上报隧道域名（Bearer 鉴权） |
| `GET /api/current` | 读取当前隧道域名 |
| `POST /api/flag` | 请求轮换 |

## 架构

```
                          ┌──────────────────────┐
  客户端 ──订阅请求──────▶ │  Cloudflare Worker   │
                          │  KV: tunnel_current  │
                          └──────────┬───────────┘
                                     │ 返回订阅时把
                                     │ *.trycloudflare.com
                                     │ 替换成当前域名
                                     ▼
  ┌──────────────────────────────────────────────┐
  │  NAT 机 / VPS (Alpine/Debian/...)            │
  │                                              │
  │  sing-box  ◀── 127.0.0.1:44615               │
  │                    ▲                          │
  │                    │                          │
  │  cloudflared ──────┘  tunnel --url           │
  │       │                                       │
  │       └──▶ POST /api/report {host}           │
  │                                              │
  │  tunnel-agent  ── 每 15 分钟健康检查          │
  │                    不可达/超龄 → 换新隧道     │
  └──────────────────────────────────────────────┘
```

## 部署步骤

### 1. 部署 Worker

把 `worker.js` 内容贴进 Cloudflare Pages / Workers 项目，然后：

1. 绑定 KV 命名空间，变量名 **`SUB_KV`**
2. 添加环境变量 **`REPORT_TOKEN`**（随便一串随机字符串，自己记住）
3. 部署

### 2. 在服务器上跑

```sh
curl -LfsS https://你的项目.pages.dev/one -o /tmp/ok.sh && sh /tmp/ok.sh
```

脚本自动完成：下载 sb → 创建 Argo 节点 → 读端口和域名 → 部署 tunnel-agent → 上报。
参数 `API_BASE` 和 `REPORT_TOKEN` 由 Worker 在返回脚本时自动注入，**不用手填**。

### 3. 验证

```sh
/opt/tunnel-agent/tunnel-agent.sh status
curl -s https://你的项目.pages.dev/api/current
```

期望：`{"host":"xxx-yyy.trycloudflare.com","ts":...}`

### 4. 生成订阅

访问 `https://你的项目.pages.dev/`，按页面提示生成订阅地址，导入客户端。

## 手动控制

```sh
/opt/tunnel-agent/tunnel-agent.sh status    # 状态
/opt/tunnel-agent/tunnel-agent.sh health    # 健康检查（cron 每 15 分钟跑这个）
/opt/tunnel-agent/tunnel-agent.sh rotate    # 强制换隧道
/opt/tunnel-agent/tunnel-agent.sh probe     # 探测后端端口
/opt/tunnel-agent/tunnel-agent.sh stop      # 停止
```

## 常见问题

**Q: 隧道换了，客户端要重导订阅吗？**
不用。订阅地址不变，Worker 每次返回时读 KV 里的最新域名替换。

**Q: 上报后多久生效？**
KV 最终一致性，最多 60 秒。

**Q: 换服务器怎么办？**
新服务器重跑一次 `/one` 就行。Worker 和 KV 不用动，订阅不用改。

**Q: cloudflared 用 quic 还是 http2？**
默认 `http2`。quic 走 UDP 7844，国内常被封/QoS，一旦断开所有节点全废。除非确认 UDP 通畅，否则别用。

**Q: 轮换太频繁会被 Cloudflare 限流吗？**
会。红线：创建间隔 ≥ 30 秒、轮换周期 ≥ 3 天、同时存活隧道 ≤ 5 条。

**Q: 这套能解决「先快后慢」吗？**
不能。它解决的是「隧道挂了/变很慢之后自动恢复」，不能解决服务商出口限速导致的降速。检测周期 15 分钟 = 慢最多持续 15 分钟。

## 回滚

删掉 KV 里的 `tunnel_current` 键即可，订阅会退回使用节点原始域名。

## 第三方组件

- `sb`（singbox-lite）来自 <https://github.com/0xdabiaoge/singbox-lite>，由本仓库的 Worker 内嵌提供。该仓库**未声明开源许可证**，此处仅为个人自用场景的内网镜像分发。如需公开分发请自行取得作者授权，或改用 `/tunnel.js` 只装隧道。
- cloudflared、sing-box、Xray 均从各自官方渠道安装。

## 许可

除第三方组件外，本仓库代码 MIT。
