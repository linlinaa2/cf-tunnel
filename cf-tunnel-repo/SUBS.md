# 订阅链接（2026-11-24 生成，已写入线上 KV 并回读验证）

面板入口：https://sub.336948.xyz/   （custom domain → sub-gen，已确认 HTTP 200 / 20281B / 含「多台服务器管理」）
备用入口：https://sub-gen.shenllinya.workers.dev/  （本机代理拦截，手机/路由器可开）

## 单机订阅（不合并）

**US-洛杉矶 / u8544-birw96f2（port 36087，9 个优选IP）**
```
https://sub.336948.xyz/sub/9ce3b7a1-cac2-450a-ad16-f98e4c2ca462?key=7a22893d657f8d3154d73ecb1bf665e23fc6cfc6010949f2db8a2b053ee38841
```

**HK-香港 / u8544-0ejmx2w0（port 48050，9 个优选IP）**
```
https://sub.336948.xyz/sub/45ac688e-7717-49c9-a05e-9d35606cbd7f?key=10d3481e15ab62688d03062a5a5e07344d7aa20006ebb33c30886cdea0afe75c
```

## 合并订阅（两台 × 9 IP = 18 节点）
```
https://sub.336948.xyz/sub/9e23b1d4-039d-4db6-bb00-eef813ae9c9a?key=468f6c7c26d8ee60aea903a8614fdec63704130481f3892bb2801604484f188e
```

## 客户端格式
- Clash / mihomo / Stash：链接后加 `&clash=1`（或 `?clash=1`），返回 YAML
- v2rayN / v2rayNG / 小火箭：直接粘，返回 base64 的 vless 列表（已解码验证，sni+ws path ed=2560 都在）

## 域名自动跟随
`kind:"multi"` 订阅在每次请求时实时读 `tunnel_nodes`，所以机器换隧道后订阅**不用重新生成**，客户端刷新即生效。
