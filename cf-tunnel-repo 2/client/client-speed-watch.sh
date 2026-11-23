#!/bin/sh
# ============================================================================
# client-speed-watch.sh — 路由器侧「被动」低速检测
#
# 不发起任何测速下载，只读 mihomo 自己的流量统计，因此不会触发
# 服务商的「禁止测速」风控。
#
# 逻辑：
#   连续采样 N 秒 mihomo 的 total down 速率 -> 取中位数
#   若低于阈值 -> POST /api/flag 通知 NAT 机轮换隧道
#
# 用法：
#   ./client-speed-watch.sh            单次检测
#   ./client-speed-watch.sh --daemon   常驻（每 INTERVAL 秒一次）
#
# 建议放 cron：*/10 * * * * /opt/client-speed-watch.sh
# ============================================================================

set -u

# ---------- 配置 ----------
MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
MIHOMO_SECRET="${MIHOMO_SECRET:?必须设置 mihomo 的 secret}"
TARGET_PROXY="${TARGET_PROXY:-}"     # 留空=统计全部流量；填节点名=只看该节点
THRESHOLD_KB="${THRESHOLD_KB:-2500}" # 低于此值(KB/s)判定为慢，约 20Mbps
SAMPLE_SECONDS="${SAMPLE_SECONDS:-20}"
COOLDOWN="${COOLDOWN:-10800}"        # 报一次后 3 小时内不重复报
API_BASE="${API_BASE:?必须设置 Worker 地址}"
REPORT_TOKEN="${REPORT_TOKEN:?必须设置 REPORT_TOKEN}"
STATE=/tmp/speed-watch.state

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# ---------- 冷却检查 ----------
if [ -f "$STATE" ]; then
    last=$(cat "$STATE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ $((now - last)) -lt "$COOLDOWN" ]; then
        log "冷却中（$(( (COOLDOWN - (now - last)) / 60 )) 分钟后可再报）"
        exit 0
    fi
fi

# ---------- 采样 mihomo 实时速率 ----------
# /traffic 是 SSE 流，每秒一行 {"up":N,"down":N}
sample() {
    curl -s -N -m $((SAMPLE_SECONDS + 5)) \
        -H "Authorization: Bearer $MIHOMO_SECRET" \
        "$MIHOMO_API/traffic" 2>/dev/null \
    | head -n "$SAMPLE_SECONDS" \
    | sed -n 's/.*"down":\([0-9][0-9]*\).*/\1/p'
}

vals=$(sample)
count=$(printf '%s\n' "$vals" | grep -c '[0-9]' 2>/dev/null || echo 0)
if [ "${count:-0}" -lt 5 ]; then
    log "采样失败（只拿到 ${count:-0} 个点），跳过"
    exit 0
fi

# 中位数，避免突发/瞬时抖动误判
median=$(printf '%s\n' "$vals" | sort -n | awk '{a[NR]=$1} END{ if(NR==0) exit; print a[int((NR+1)/2)] }')
mean=$(printf '%s\n' "$vals" | awk '{s+=$1; n++} END{ if(n==0) exit; printf "%d", s/n }')
kb=$((median / 1024))

log "下载速率 中位=${kb}KB/s 均值=$((mean / 1024))KB/s 阈值=${THRESHOLD_KB}KB/s 采样=${count}s"

if [ "$kb" -ge "$THRESHOLD_KB" ]; then
    log "速度正常"
    exit 0
fi

# ---------- 上报低速标记 ----------
body=$(printf '{"rotate":true,"speed_kb":%s,"median_kb":%s,"ts":%s}' \
    "$kb" "$kb" "$(date +%s)")
resp=$(curl -s -m 15 -X POST "$API_BASE/api/flag" \
    -H "Authorization: Bearer $REPORT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>/dev/null)

if printf '%s' "$resp" | grep -q '"ok":true'; then
    date +%s > "$STATE"
    log "已上报低速标记（${kb}KB/s），等待 NAT 机轮换"
else
    log "上报失败: ${resp:-<空>}"
fi
