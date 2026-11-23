#!/bin/sh
# ============================================================================
# client-speed-watch.sh — 路由器侧「被动」掉速检测（OpenWrt / BusyBox）
#
# 针对「先快后慢」：链路本来能跑 40-100Mbps，用一会儿掉到几百 KB/s。
# 只读 mihomo /traffic 的 down 字节速率，不发起任何下载，零额外流量，
# 不会触发服务商的「禁止测速」风控。
#
# 判定逻辑（三段式，避免刷网页时误判）：
#   1) 每分钟采样 8 秒，取中位速率，记进 history（保留 60 分钟）
#   2) 若「60 分钟内曾达到 PEAK_KB」且「最近连续 LOW_TURNS 轮都 < LOW_KB」
#      → 判定为掉速（能快却变慢）
#   3) 上报 Worker /api/flag，冻结 COOLDOWN 秒（默认 3 小时）
#
# cron: */5 * * * * /etc/mihomo/client-speed-watch.sh >/dev/null 2>&1
# ============================================================================

set -u

MIHOMO_API="${MIHOMO_API:-http://127.0.0.1:9090}"
MIHOMO_SECRET="${MIHOMO_SECRET:-19971997}"
API_BASE="${API_BASE:-https://sub-gen.shenllinya.workers.dev}"
REPORT_TOKEN="${REPORT_TOKEN:--fd830ca081bbf6fe5606750999b2049f852fa13c69cb5bed47b12d0225f75d11}"

PEAK_KB="${PEAK_KB:-1500}"       # 60 分钟内曾达到此速度(约12Mbps)才算「本来能快」
LOW_KB="${LOW_KB:-400}"          # 当前低于此值(约3.2Mbps)算「慢」
LOW_TURNS="${LOW_TURNS:-2}"      # 连续几轮慢才判定
COOLDOWN="${COOLDOWN:-10800}"    # 上报后 3 小时内不再报
SAMPLE_SECONDS="${SAMPLE_SECONDS:-8}"
WINDOW="${WINDOW:-3600}"         # 峰值回看窗口（秒）

STATE_DIR=/tmp/speed-watch
HIST="$STATE_DIR/history"
LOWCNT="$STATE_DIR/lowcount"
COOLDOWN_F="$STATE_DIR/cooldown"
mkdir -p "$STATE_DIR"

now=$(date +%s)

# ---------- 冷却 ----------
if [ -f "$COOLDOWN_F" ]; then
    last=$(cat "$COOLDOWN_F" 2>/dev/null || echo 0)
    [ $((now - last)) -lt "$COOLDOWN" ] && exit 0
fi

# ---------- 采样 ----------
vals=$(curl -s -N -m $((SAMPLE_SECONDS + 4)) \
        -H "Authorization: Bearer $MIHOMO_SECRET" \
        "$MIHOMO_API/traffic" 2>/dev/null \
       | head -n "$SAMPLE_SECONDS" \
       | sed -n 's/.*"down":\([0-9][0-9]*\).*/\1/p')

count=$(printf '%s\n' "$vals" | grep -c '[0-9]' 2>/dev/null || echo 0)
[ "${count:-0}" -lt 4 ] && exit 0

median=$(printf '%s\n' "$vals" | sort -n | awk '{a[NR]=$1} END{ if(NR==0) exit; print a[int((NR+1)/2)] }')
kb=$((median / 1024))

# ---------- 记录历史（时间戳 + KB/s） ----------
printf '%s %s\n' "$now" "$kb" >> "$HIST"
awk -v t="$now" -v w="$WINDOW" '$1 >= t - w' "$HIST" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"

# ---------- 回看窗口内峰值 ----------
peak=$(awk '{ if ($2 > m) m = $2 } END { print m + 0 }' "$HIST" 2>/dev/null)

# ---------- 连续低速计数 ----------
if [ "$kb" -lt "$LOW_KB" ]; then
    c=$(cat "$LOWCNT" 2>/dev/null || echo 0)
    c=$((c + 1))
    echo "$c" > "$LOWCNT"
else
    echo 0 > "$LOWCNT"
    exit 0
fi

c=$(cat "$LOWCNT" 2>/dev/null || echo 0)

# ---------- 判定：本来能快，现在持续慢 ----------
if [ "$peak" -lt "$PEAK_KB" ]; then
    exit 0      # 一直都不快（可能只是刷网页），不误报
fi
if [ "$c" -lt "$LOW_TURNS" ]; then
    exit 0      # 还没连续够轮数
fi

# ---------- 上报 ----------
resp=$(curl -s -m 15 -X POST "$API_BASE/api/flag" \
    -H "Authorization: Bearer $REPORT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"rotate\":true,\"speed_kb\":$kb,\"peak_kb\":$peak,\"low_turns\":$c}" 2>/dev/null)

if printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "$now" > "$COOLDOWN_F"
    echo 0 > "$LOWCNT"
    logger -t speed-watch "掉速已上报: 当前 ${kb}KB/s 峰值 ${peak}KB/s 连续${c}轮" 2>/dev/null
fi
