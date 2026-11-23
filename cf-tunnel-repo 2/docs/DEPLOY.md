# 部署指南

## 前置

- Cloudflare 账号（免费）
- 一台 Linux 服务器（Alpine / Debian / Ubuntu 都行，root 权限）
- 能上外网

## 第一步：Worker

1. Cloudflare 控制台 → Workers & Pages → 创建 → Pages → 直接上传 / 或选「兼容性」模板
2. 把 `worker.js` 全部内容贴进编辑器（608KB，粘贴可能卡顿，耐心等）
3. Settings → Functions → KV namespace bindings → 变量名填 `SUB_KV`，选一个命名空间（没有就新建）
4. Settings → Environment variables → 添加 `REPORT_TOKEN`，值为任意随机串
5. 保存并部署

**验证**：浏览器打开 `https://你的项目.pages.dev/api/current`，应返回 `{"host":null}`。

## 第二步：服务器

```sh
curl -LfsS https://你的项目.pages.dev/one -o /tmp/ok.sh && sh /tmp/ok.sh
```

全程无人值守。结束后会打印节点端口和隧道域名。

**如果 one 失败**，回退到手动两步：

```sh
# 装节点（交互式，选 [2] → [1] → 一路回车）
curl -LfsS https://你的项目.pages.dev/sb -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && sb

# 接管隧道
curl -LfsS https://你的项目.pages.dev/tunnel.js -o /tmp/i.sh && sh /tmp/i.sh
```

## 第三步：验证

```sh
/opt/tunnel-agent/tunnel-agent.sh status
curl -s https://你的项目.pages.dev/api/current
```

## 第四步：订阅

浏览器打开 Worker 首页，生成订阅，导入客户端。

## 定时任务

安装脚本会自动加：

```cron
*/15 * * * * /opt/tunnel-agent/tunnel-agent.sh health
```

## 排查

| 现象 | 检查 |
|---|---|
| `/api/current` 返回 null | agent 没上报，看 `/opt/tunnel-agent/agent.log` |
| 上报了但订阅没变 | 等 60 秒（KV 一致性）；或清洗浏览器缓存 |
| 节点连不上 | `cloudflared` 是否在跑；后端端口对不对（`tunnel-agent.sh probe`） |
| 隧道频繁掉 | 换 `--proto http2`；检查 UDP 7844 是否被封 |
