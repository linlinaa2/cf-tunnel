#!/bin/sh
# ============================================================================
# onekey-standalone —— 零交互、零依赖菜单：任何 Linux 一行装好 Argo 节点
#
#   curl -LfsS <本文件直链> -o /tmp/ok.sh && sh /tmp/ok.sh
#
# 做的事：
#   1. 装 sing-box（GitHub releases，自动识别架构）
#   2. 生成随机 UUID / 端口 / WS 路径，写独立配置（不碰已有服务）
#   3. 后台起 sing-box
#   4. 起 cloudflared 临时隧道，抓 trycloudflare 域名
#   5. 上报 Worker，换掉订阅里的旧域名
#   6. 打印 vless 链接
#
# 参数：
#   --port N     本地监听端口（默认 2080）
#   --name NAME  节点名（默认 hostname）
#   --api URL    覆盖 Worker 地址
#   --token T    覆盖上报 token
#   --no-report  只建节点不报 Worker
# ============================================================================
set -u

API_BASE="https://sub-gen.shenllinya.workers.dev"
REPORT_TOKEN="fd830ca081bbf6fe5606750999b2049f852fa13c69cb5bed47b12d0225f75d11"
PORT=2080
NODE_NAME=""
DO_REPORT=1
NODE_DIR=/opt/onekey-node

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)  PORT="$2"; shift 2 ;;
    --name)  NODE_NAME="$2"; shift 2 ;;
    --api)   API_BASE="${2%/}"; shift 2 ;;
    --token) REPORT_TOKEN="$2"; shift 2 ;;
    --no-report) DO_REPORT=0; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "必须 root 执行"
[ -z "$NODE_NAME" ] && NODE_NAME=$(hostname 2>/dev/null || echo node)

# ---- 架构 ----
case "$(uname -m)" in
  x86_64|amd64)  SB_ARCH="amd64" ;;
  aarch64|arm64) SB_ARCH="arm64" ;;
  armv7l)        SB_ARCH="armv7" ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac
say "架构: $SB_ARCH"

mkdir -p "$NODE_DIR" || die "无法创建 $NODE_DIR"

# ---- 工具 ----
need() { command -v "$1" >/dev/null 2>&1; }
dl() { # dl <URL> <OUTFILE>
  if need curl; then curl -LfsS --max-time 300 -o "$2" "$1"
  else wget -q --timeout=300 -O "$2" "$1"; fi
}
FETCH=""
if need curl; then FETCH="curl -LfsS --max-time 180"
elif need wget; then FETCH="wget -q -O - --timeout=180"
else
  say "安装 curl"
  if need apk; then apk add --no-cache curl >/dev/null 2>&1
  elif need apt-get; then apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1
  elif need yum; then yum install -y -q curl >/dev/null 2>&1
  fi
  need curl || die "缺少 curl/wget"
  FETCH="curl -LfsS --max-time 180"
fi

# ---- 1. sing-box ----
SB_BIN="$NODE_DIR/sing-box"
if [ -x /usr/local/bin/sing-box ]; then
  SB_BIN=/usr/local/bin/sing-box
  say "复用已装的 sing-box"
elif [ -x "$SB_BIN" ]; then
  say "复用已有 sing-box（$NODE_DIR）"
else
  say "查询 sing-box 最新版本"
  TAG=$($FETCH https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*"\(v[^"]*\)"$/\1/')
  [ -n "${TAG:-}" ] || TAG=v1.11.15
  VER=${TAG#v}
  say "下载 sing-box $TAG ($SB_ARCH)"
  URL="https://github.com/SagerNet/sing-box/releases/download/$TAG/sing-box-$VER-linux-$SB_ARCH.tar.gz"
  TMPT=$(mktemp -d) || die "mktemp 失败"
  dl "$URL" "$TMPT/sb.tgz" || die "下载 sing-box 失败: $URL"
  [ -s "$TMPT/sb.tgz" ] || die "sing-box 下载为空"
  tar -xzf "$TMPT/sb.tgz" -C "$TMPT" || die "解压失败"
  FOUND=$(find "$TMPT" -type f -name 'sing-box' | head -1)
  [ -n "$FOUND" ] || die "压缩包里没找到 sing-box"
  cp "$FOUND" "$SB_BIN" && chmod +x "$SB_BIN" || die "安装失败"
  rm -rf "$TMPT"
fi
"$SB_BIN" version >/dev/null 2>&1 || die "sing-box 无法运行"
say "sing-box: $("$SB_BIN" version 2>/dev/null | head -1)"

# ---- 2. 配置 ----
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")
[ -n "$UUID" ] || UUID=$($FETCH https://www.uuidgenerator.net/api/version4 2>/dev/null | tr -d '\r\n')
[ -n "$UUID" ] || UUID="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')"

WS_PATH="/ok$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CFG="$NODE_DIR/config.json"
cat > "$CFG" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [ { "uuid": "$UUID", "flow": "" } ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "max_early_data": 2560,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

"$SB_BIN" check -c "$CFG" >/dev/null 2>&1 || die "配置校验不通过"
say "配置已写: $CFG (port=$PORT path=$WS_PATH)"

# ---- 3. 起 sing-box ----
if [ -f "$NODE_DIR/singbox.pid" ] && kill -0 "$(cat "$NODE_DIR/singbox.pid" 2>/dev/null)" 2>/dev/null; then
  kill "$(cat "$NODE_DIR/singbox.pid")" 2>/dev/null; sleep 1
fi
nohup "$SB_BIN" run -c "$CFG" > "$NODE_DIR/singbox.log" 2>&1 &
echo $! > "$NODE_DIR/singbox.pid"
sleep 3
if ! kill -0 "$(cat "$NODE_DIR/singbox.pid")" 2>/dev/null; then
  tail -20 "$NODE_DIR/singbox.log" >&2
  die "sing-box 启动失败"
fi
say "sing-box 已启动 pid=$(cat "$NODE_DIR/singbox.pid")"

# ---- 4. cloudflared ----
CF_BIN=""
for c in /usr/local/bin/cloudflared /usr/bin/cloudflared /opt/tunnel-agent/cloudflared; do
  [ -x "$c" ] && { CF_BIN="$c"; break; }
done
if [ -z "$CF_BIN" ]; then
  say "下载 cloudflared"
  dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$SB_ARCH" \
    "$NODE_DIR/cloudflared" || die "下载 cloudflared 失败"
  chmod +x "$NODE_DIR/cloudflared"
  CF_BIN="$NODE_DIR/cloudflared"
fi
[ -x "$CF_BIN" ] || die "cloudflared 不可用"

CFLOG="$NODE_DIR/cloudflared.log"
: > "$CFLOG"
if [ -f "$NODE_DIR/cf.pid" ] && kill -0 "$(cat "$NODE_DIR/cf.pid" 2>/dev/null)" 2>/dev/null; then
  kill "$(cat "$NODE_DIR/cf.pid")" 2>/dev/null; sleep 1
fi
METRICS=$((20260 + RANDOM % 30))
nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
  --protocol http2 --edge-ip-version 4 --metrics "127.0.0.1:$METRICS" \
  >> "$CFLOG" 2>&1 &
echo $! > "$NODE_DIR/cf.pid"

say "等待隧道域名（最多 90 秒）"
HOST=""
i=0
while [ $i -lt 45 ]; do
  sleep 2
  i=$((i+1))
  HOST=$(grep -o '[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$CFLOG" 2>/dev/null | head -1)
  [ -n "$HOST" ] && break
  kill -0 "$(cat "$NODE_DIR/cf.pid")" 2>/dev/null || { tail -20 "$CFLOG" >&2; die "cloudflared 提前退出"; }
done
[ -n "$HOST" ] || { tail -20 "$CFLOG" >&2; die "等域名超时"; }
say "隧道: https://$HOST"

# ---- 5. 上报 ----
if [ "$DO_REPORT" = "1" ]; then
  say "上报 Worker"
  if need curl; then
    curl -s -m 20 -X POST "$API_BASE/api/report" \
      -H "Authorization: Bearer $REPORT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"host\":\"$HOST\",\"node\":\"$NODE_NAME\",\"port\":\"$PORT\"}" \
      -o /dev/null -w '  上报 HTTP %{http_code}\n'
  fi
fi

# ---- 6. 输出 ----
cat > "$NODE_DIR/node.env" <<EOF
UUID=$UUID
PORT=$PORT
WS_PATH=$WS_PATH
HOST=$HOST
NODE_NAME=$NODE_NAME
EOF

VLESS="vless://$UUID@$HOST:443?encryption=none&security=tls&sni=$HOST&fp=chrome&type=ws&host=$HOST&path=$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')&ed=2560&eh=Sec-WebSocket-Protocol#$NODE_NAME"

echo
say "完成"
echo
echo "  ┌─ VLESS 链接 ─────────────────────────────────────────────"
echo "  $VLESS"
echo "  └──────────────────────────────────────────────────────────"
echo
echo "  节点目录 : $NODE_DIR"
echo "  配置     : $CFG"
echo "  状态     : kill -0 \$(cat $NODE_DIR/singbox.pid) && echo 运行中"
echo "  重启     : kill \$(cat $NODE_DIR/cf.pid); sh $0"
echo
echo "$VLESS" > "$NODE_DIR/vless.txt"
echo "  链接已存 : $NODE_DIR/vless.txt"
echo
