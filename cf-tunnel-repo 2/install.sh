#!/bin/sh
# ============================================================================
# deploy.sh —— 一行命令部署 tunnel-agent（自包含，无需其他文件）
#
# 用法（在 NAT 机 / VPS 上，root 执行）：
#   一条命令（推荐，参数自动注入）：
#     curl -LfsS https://你的项目.pages.dev/install.sh -o /tmp/i.sh && sh /tmp/i.sh
#   手动指定：
#     sh install.sh --api https://你的项目.pages.dev --token 你的REPORT_TOKEN
#
# 可选参数：
#   --node jp-nat1     这台机器的名字，默认取 hostname
#   --port 44615       后端端口，默认自动探测 sing-box/xray
#   --proto quic       隧道协议，默认 http2
#   --age 259200       隧道最长存活秒数，默认 3 天
#   --no-start         只安装不启动
#
# 它做的事：
#   1. 装 cloudflared（没有才装）
#   2. 写 /opt/tunnel-agent/tunnel-agent.sh
#   3. 写 /opt/tunnel-agent/agent.conf
#   4. 注册开机自启（OpenRC / systemd 自动识别）
#   5. 加 cron：每 15 分钟健康检查
#   6. 探测后端端口 -> 起隧道 -> 上报 Worker
#
# 换服务器：同一条命令拷过去再跑一遍，只改 --node 的值。
# ============================================================================

set -u

API_BASE="__API_BASE__"
REPORT_TOKEN="__REPORT_TOKEN__"
NODE_ID=""
BACKEND_PORT="auto"
CF_PROTOCOL="http2"
MAX_AGE="259200"
DO_START=1

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --api)      [ $# -ge 2 ] || die "--api 缺参数";   API_BASE="${2%/}"; shift 2 ;;
        --token)    [ $# -ge 2 ] || die "--token 缺参数"; REPORT_TOKEN="$2"; shift 2 ;;
        --node)     [ $# -ge 2 ] || die "--node 缺参数";  NODE_ID="$2"; shift 2 ;;
        --port)     [ $# -ge 2 ] || die "--port 缺参数";  BACKEND_PORT="$2"; shift 2 ;;
        --proto)    [ $# -ge 2 ] || die "--proto 缺参数"; CF_PROTOCOL="$2"; shift 2 ;;
        --age)      [ $# -ge 2 ] || die "--age 缺参数";   MAX_AGE="$2"; shift 2 ;;
        --no-start) DO_START=0; shift ;;
        -h|--help)  sed -n '2,23p' "$0" 2>/dev/null || sed -n '2,23p' /tmp/deploy.sh; exit 0 ;;
        *)          die "未知参数: $1" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "必须 root 执行"
[ "$API_BASE" = "__API_BASE__" ] && die "这个脚本要从你的 Worker 域名下载才带默认参数：curl -LfsS https://你的项目.pages.dev/install.sh -o /tmp/i.sh && sh /tmp/i.sh"
[ -n "$API_BASE" ] || die "缺少 --api https://你的项目.pages.dev"
[ -n "$REPORT_TOKEN" ] || die "缺少 --token（Worker 的 REPORT_TOKEN）"
[ -z "$NODE_ID" ] && NODE_ID=$(hostname 2>/dev/null || echo node1)

PREFIX=/opt/tunnel-agent
mkdir -p "$PREFIX" /var/lib/tunnel-agent

# ---------------------------------------------------------------------------
# 0. 基础依赖
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        say "安装 curl 与证书"
        apk add --no-cache curl ca-certificates >/dev/null 2>&1 || die "apk add 失败"
    else
        die "缺少 curl/wget"
    fi
fi
if [ -d /etc/apk ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    apk add --no-cache ca-certificates >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# 1. cloudflared
# ---------------------------------------------------------------------------
if command -v cloudflared >/dev/null 2>&1; then
    say "cloudflared 已存在: $(cloudflared --version 2>/dev/null | head -1)"
else
    say "下载 cloudflared"
    case "$(uname -m)" in
        x86_64|amd64)  A=amd64 ;;
        aarch64|arm64) A=arm64 ;;
        armv7l|armv7)  A=arm ;;
        *) die "不支持的架构 $(uname -m)" ;;
    esac
    U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A"
    if command -v curl >/dev/null 2>&1; then
        curl -fL# "$U" -o /usr/local/bin/cloudflared || die "下载失败"
    else
        wget -qO /usr/local/bin/cloudflared "$U" || die "下载失败"
    fi
    chmod +x /usr/local/bin/cloudflared
    say "已安装 $(cloudflared --version 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------------------
# 2. 主程序
# ---------------------------------------------------------------------------
say "写入 $PREFIX/tunnel-agent.sh"
cat > "$PREFIX/tunnel-agent.sh" <<'__AGENT_SH__'
#!/bin/sh
# ============================================================================
# tunnel-agent.sh — 通用 Cloudflare Quick Tunnel 自动轮换 agent
#
# 设计目标：换服务器不用改代码，只改 agent.conf 四个值。
#
# 子命令:
#   start          启动隧道（已有则不动）
#   rotate         轮换：新建隧道 -> 验证 -> 上报 Worker -> 杀旧隧道
#   health         cron 用。检查存活 / 隧道年龄 / 云端低速标记，任一异常则 rotate
#   status         查看状态
#   stop           停止
#   probe          只探测后端端口，不启隧道（换服务器后先用它确认端口）
#
# 兼容 busybox ash / dash / bash，Alpine 与 Debian 系通用。
# ============================================================================

set -u

SELF="$0"
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)

CONF="${AGENT_CONF:-$SELF_DIR/agent.conf}"
if [ ! -f "$CONF" ]; then
    echo "[fatal] 找不到配置文件: $CONF" >&2
    echo "        复制 agent.conf.example 为 agent.conf 并填写" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

# ---------- 默认值 ----------
NODE_ID="${NODE_ID:-$(hostname 2>/dev/null || echo node1)}"
STATE_DIR="${STATE_DIR:-/var/lib/tunnel-agent}"
CF_BIN="${CF_BIN:-cloudflared}"
CF_PROTOCOL="${CF_PROTOCOL:-http2}"
CF_EDGE_IP="${CF_EDGE_IP:-4}"
CF_REGION="${CF_REGION:-}"
METRICS_PORT="${METRICS_PORT:-20241}"
BACKEND_PORT="${BACKEND_PORT:-auto}"
MAX_TUNNEL_AGE="${MAX_TUNNEL_AGE:-259200}"      # 秒，默认 3 天
HOST_WAIT_SECONDS="${HOST_WAIT_SECONDS:-80}"
# 探测后端时排除的端口（告警/监控/nginx 等）与进程关键词
PORT_BLACKLIST="${PORT_BLACKLIST:-8080 8443 9090 80 443}"
PROC_HINTS="${PROC_HINTS:-sing-box xray v2ray hysteria}"

: "${API_BASE:?agent.conf 里必须设置 API_BASE}"
: "${REPORT_TOKEN:?agent.conf 里必须设置 REPORT_TOKEN}"
API_BASE="${API_BASE%/}"

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

LOG="$STATE_DIR/agent.log"
PID_FILE="$STATE_DIR/active.pid"
HOST_FILE="$STATE_DIR/active.host"
TS_FILE="$STATE_DIR/active.ts"
PORT_FILE="$STATE_DIR/active.port"
MISS_FILE="$STATE_DIR/miss.count"

log() { printf '[%s][%s] %s\n' "$(date '+%F %T')" "$NODE_ID" "$*" >> "$LOG"; }
say() { printf '%s\n' "$*"; log "$*"; }

# ---------------------------------------------------------------------------
# 后端端口探测
#   优先级: ss -lntp 匹配进程名 > /proc/net/tcp 扫 127.0.0.1 监听端口
#   任何情况下都排除黑名单端口
# ---------------------------------------------------------------------------
is_blacklisted() {
    for p in $PORT_BLACKLIST; do
        [ "$1" = "$p" ] && return 0
    done
    # cloudflared 自身 metrics 端口段
    case "$1" in 2024[0-9]|2025[0-9]) return 0 ;; esac
    return 1
}

probe_ports_ss() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -lntp 2>/dev/null | while read -r _ _ _ addr proc; do
        case "$addr" in
            127.0.0.1:*|0.0.0.0:*|\[::1\]:*) ;;
            *) continue ;;
        esac
        port=${addr##*:}
        is_blacklisted "$port" && continue
        # 进程名命中则排前面
        hit=9
        for h in $PROC_HINTS; do
            case "$proc" in *"$h"*) hit=0 ;; esac
        done
        printf '%s %s\n' "$hit" "$port"
    done | sort -k1,1n -k2,2n | awk '{print $2}' | awk '!seen[$0]++'
}

probe_ports_proc() {
    [ -r /proc/net/tcp ] || return 1
    awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp | while read -r a; do
        ip=${a%%:*}; hex=${a##*:}
        case "$ip" in
            0100007F|00000000|00000000000000000000000001000000) ;;
            *) continue ;;
        esac
        printf '%d\n' "0x$hex"
    done | sort -n | uniq
}

resolve_backend_port() {
    if [ "$BACKEND_PORT" != "auto" ]; then
        echo "$BACKEND_PORT"
        return 0
    fi
    if [ -f "$PORT_FILE" ]; then
        cached=$(cat "$PORT_FILE" 2>/dev/null)
        if [ -n "$cached" ] && port_alive "$cached"; then
            echo "$cached"
            return 0
        fi
    fi
    list=$(probe_ports_ss 2>/dev/null)
    [ -n "${list:-}" ] || list=$(probe_ports_proc 2>/dev/null)
    [ -n "${list:-}" ] || return 1
    for p in $list; do
        if port_alive "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

port_alive() {
    # 本地能建立 TCP 连接即认为端口在用
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
    fi
    curl -s -o /dev/null -m 3 "http://127.0.0.1:$1/" 2>/dev/null
    # curl 返回 0(2xx/3xx) 或 22(4xx) / 52(空响应) 都说明端口有服务
    rc=$?
    case "$rc" in
        0|22|52|56) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 隧道进程管理
# ---------------------------------------------------------------------------
tunnel_running() {
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "${pid:-}" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

kill_tunnel() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "${pid:-}" ]; then
            kill "$pid" 2>/dev/null
            i=0
            while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1; i=$((i+1))
            done
            kill -9 "$pid" 2>/dev/null
            log "已停止隧道 pid=$pid"
        fi
        rm -f "$PID_FILE"
    fi
}

extract_host() {
    grep -ohE '[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$1" 2>/dev/null | head -1
}

spawn_tunnel() {
    port=$1
    logf="$STATE_DIR/cloudflared.log"
    : > "$logf"

    set -- tunnel --url "http://127.0.0.1:$port" \
        --no-autoupdate \
        --protocol "$CF_PROTOCOL" \
        --edge-ip-version "$CF_EDGE_IP" \
        --metrics "127.0.0.1:$METRICS_PORT"
    [ -n "$CF_REGION" ] && set -- "$@" --region "$CF_REGION"

    nohup "$CF_BIN" "$@" >> "$logf" 2>&1 &
    echo $! > "$PID_FILE"
    log "启动隧道 pid=$(cat "$PID_FILE") 后端=127.0.0.1:$port proto=$CF_PROTOCOL"

    waited=0
    host=""
    while [ $waited -lt "$HOST_WAIT_SECONDS" ]; do
        sleep 2
        waited=$((waited+2))
        host=$(extract_host "$logf")
        [ -n "$host" ] && break
        if ! kill -0 "$(cat "$PID_FILE" 2>/dev/null || echo 0)" 2>/dev/null; then
            log "cloudflared 提前退出，日志尾部:"
            tail -8 "$logf" >> "$LOG"
            return 1
        fi
    done

    if [ -z "$host" ]; then
        log "等域名超时(${HOST_WAIT_SECONDS}s)，日志尾部:"
        tail -8 "$logf" >> "$LOG"
        return 1
    fi
    echo "$host"
}

verify_host() {
    host=$1
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' \
        -H 'User-Agent: Mozilla/5.0' "https://$host/" 2>/dev/null)
    log "验证 https://$host/ -> HTTP ${code:-000}"
    case "$code" in
        000|520|521|522|523|524|530) return 1 ;;
        *) return 0 ;;
    esac
}

report_host() {
    host=$1
    body=$(printf '{"host":"%s","node":"%s","port":"%s","ts":%s}' \
        "$host" "$NODE_ID" "$(cat "$PORT_FILE" 2>/dev/null || echo '')" "$(date +%s)")
    resp=$(curl -s -m 15 -X POST "$API_BASE/api/report" \
        -H "Authorization: Bearer $REPORT_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$body" 2>/dev/null)
    log "上报 $body -> ${resp:-<空>}"
    printf '%s' "$resp" | grep -q '"ok":true'
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
cmd_start() {
    if tunnel_running; then
        say "隧道已在运行 pid=$(cat "$PID_FILE") host=$(cat "$HOST_FILE" 2>/dev/null)"
        return 0
    fi
    port=$(resolve_backend_port) || {
        say "无法确定后端端口，请把 agent.conf 的 BACKEND_PORT 设为具体值"
        return 1
    }
    echo "$port" > "$PORT_FILE"
    host=$(spawn_tunnel "$port") || { say "隧道创建失败"; return 1; }
    echo "$host" > "$HOST_FILE"
    date +%s > "$TS_FILE"
    say "隧道就绪 host=$host 后端端口=$port"
    if report_host "$host"; then
        say "已上报 Worker，订阅即刻生效"
    else
        say "上报失败，但隧道可用；检查 API_BASE / REPORT_TOKEN / 网络"
    fi
}

# ---------------------------------------------------------------------------
# rotate：新建 -> 验证 -> 上报 -> 杀旧（无感切换）
# ---------------------------------------------------------------------------
cmd_rotate() {
    say "===== 开始轮换 ====="
    port=$(resolve_backend_port) || { say "无可用后端端口，放弃轮换"; return 1; }

    old_pid=""
    old_host=""
    if tunnel_running; then
        old_pid=$(cat "$PID_FILE")
        old_host=$(cat "$HOST_FILE" 2>/dev/null)
        # 先摘掉 pid 文件，避免新隧道覆盖时误杀
        mv "$PID_FILE" "$STATE_DIR/old.pid" 2>/dev/null
    fi

    echo "$port" > "$PORT_FILE"
    host=$(spawn_tunnel "$port")
    if [ -z "${host:-}" ]; then
        say "新隧道创建失败，回滚到旧隧道"
        [ -f "$STATE_DIR/old.pid" ] && mv "$STATE_DIR/old.pid" "$PID_FILE"
        return 1
    fi
    echo "$host" > "$HOST_FILE"
    date +%s > "$TS_FILE"

    if ! verify_host "$host"; then
        say "新隧道验证不通，回滚"
        kill_tunnel
        if [ -f "$STATE_DIR/old.pid" ]; then
            mv "$STATE_DIR/old.pid" "$PID_FILE"
            say "旧隧道已恢复 host=$old_host"
        fi
        return 1
    fi

    if ! report_host "$host"; then
        say "上报失败，回滚以防客户端拿到坏域名"
        kill_tunnel
        if [ -f "$STATE_DIR/old.pid" ]; then
            mv "$STATE_DIR/old.pid" "$PID_FILE"
            say "旧隧道已恢复 host=$old_host"
        fi
        return 1
    fi

    # 成功：杀掉旧隧道（KV 最长 60 秒传播，旧隧道多留 90 秒兜底）
    if [ -f "$STATE_DIR/old.pid" ]; then
        op=$(cat "$STATE_DIR/old.pid" 2>/dev/null)
        if [ -n "${op:-}" ]; then
            # nohup 防 cron 退出时被 SIGHUP 带走
            nohup sh -c "sleep 90; kill $op 2>/dev/null" >/dev/null 2>&1 &
        fi
        rm -f "$STATE_DIR/old.pid"
    fi
    say "轮换成功 host=$host（旧隧道 90 秒后回收）"
    return 0
}

# ---------------------------------------------------------------------------
# health：给 cron 调
# ---------------------------------------------------------------------------
cmd_health() {
    # 1) 进程存活
    if ! tunnel_running; then
        say "主隧道进程不在，触发 start"
        cmd_start
        return $?
    fi

    # 2) 隧道年龄
    now=$(date +%s)
    born=$(cat "$TS_FILE" 2>/dev/null || echo 0)
    age=$((now - born))
    if [ "$age" -ge "$MAX_TUNNEL_AGE" ]; then
        say "隧道已运行 ${age}s >= ${MAX_TUNNEL_AGE}s，到期轮换"
        cmd_rotate
        return $?
    fi

    # 3) 域名可达性（连续失败 2 次才动，避免瞬时抖动误判）
    host=$(cat "$HOST_FILE" 2>/dev/null)
    if [ -n "${host:-}" ]; then
        code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' \
            -H 'User-Agent: Mozilla/5.0' "https://$host/" 2>/dev/null)
        case "$code" in
            000|520|521|522|523|524|530)
                prev_miss=$(cat "$MISS_FILE" 2>/dev/null)
                case "${prev_miss:-}" in ''|*[!0-9]*) prev_miss=0 ;; esac
                miss=$((prev_miss + 1))
                echo "$miss" > "$MISS_FILE"
                say "域名不可达 HTTP $code（连续 $miss 次）"
                if [ "$miss" -ge 2 ]; then
                    echo 0 > "$MISS_FILE"
                    cmd_rotate
                    return $?
                fi
                ;;
            *)
                echo 0 > "$MISS_FILE"
                ;;
        esac
    fi

    # 4) 云端低速标记（客户端上报的）
    flag=$(curl -s -m 12 -H "Authorization: Bearer $REPORT_TOKEN" \
        "$API_BASE/api/flag" 2>/dev/null)
    if printf '%s' "$flag" | grep -q '"rotate":true'; then
        spd=$(printf '%s' "$flag" | sed -n 's/.*"speed_kb":\([0-9]*\).*/\1/p')
        say "收到低速标记（${spd:-?} KB/s），触发轮换"
        cmd_rotate
        return $?
    fi

    say "健康 年龄=${age}s host=$host"
    return 0
}

cmd_status() {
    say "----- tunnel-agent 状态 -----"
    say "node        : $NODE_ID"
    say "config      : $CONF"
    say "state dir   : $STATE_DIR"
    say "backend     : $(cat "$PORT_FILE" 2>/dev/null || resolve_backend_port 2>/dev/null || echo 未探测)"
    say "protocol    : $CF_PROTOCOL (edge-ipv$CF_EDGE_IP)"
    if tunnel_running; then
        say "tunnel      : RUNNING pid=$(cat "$PID_FILE")"
    else
        say "tunnel      : STOPPED"
    fi
    h=$(cat "$HOST_FILE" 2>/dev/null)
    say "host        : ${h:-未就绪}"
    ts=$(cat "$TS_FILE" 2>/dev/null)
    if [ -n "${ts:-}" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
        say "age         : $(( $(date +%s) - ts ))s / ${MAX_TUNNEL_AGE}s"
    fi
    cloud_raw=$(curl -s -m 10 "$API_BASE/api/current" 2>/dev/null)
    cloud_host=$(printf '%s' "$cloud_raw" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')
    case "${cloud_host:-}" in
        ""|null) say "cloud       : 未设置（订阅使用节点原始域名）" ;;
        *)       say "cloud       : $cloud_host" ;;
    esac
}

cmd_probe() {
    say "探测 127.0.0.1 上的候选后端端口（已排除 $PORT_BLACKLIST 与 metrics 段）"
    if [ "$BACKEND_PORT" != "auto" ]; then
        say "agent.conf 写死 BACKEND_PORT=$BACKEND_PORT"
    fi
    list=$(probe_ports_ss 2>/dev/null)
    [ -n "${list:-}" ] || list=$(probe_ports_proc 2>/dev/null)
    if [ -z "${list:-}" ]; then
        say "未发现监听端口（缺 ss 且 /proc/net/tcp 不可读）"
        return 1
    fi
    for p in $list; do
        if port_alive "$p"; then
            say "  $p  <- 可用"
        else
            say "  $p  <- 连接失败"
        fi
    done
    say "选定: $(resolve_backend_port 2>/dev/null || echo 无)"
}

case "${1:-}" in
    start)  cmd_start ;;
    rotate) cmd_rotate ;;
    health) cmd_health ;;
    status) cmd_status ;;
    probe)  cmd_probe ;;
    stop)   kill_tunnel; say "已停止" ;;
    *)      sed -n '2,20p' "$SELF"; exit 1 ;;
esac
__AGENT_SH__

chmod +x "$PREFIX/tunnel-agent.sh"

# ---------------------------------------------------------------------------
# 3. 配置文件
# ---------------------------------------------------------------------------
say "写入 $PREFIX/agent.conf"
cat > "$PREFIX/agent.conf" <<EOF
NODE_ID="$NODE_ID"
API_BASE="$API_BASE"
REPORT_TOKEN="$REPORT_TOKEN"
BACKEND_PORT="$BACKEND_PORT"
PORT_BLACKLIST="8080 8443 9090 80 443"
PROC_HINTS="sing-box xray v2ray hysteria"
CF_PROTOCOL="$CF_PROTOCOL"
CF_EDGE_IP="4"
CF_REGION=""
CF_BIN="cloudflared"
METRICS_PORT="20241"
MAX_TUNNEL_AGE="$MAX_AGE"
HOST_WAIT_SECONDS="80"
STATE_DIR="/var/lib/tunnel-agent"
EOF
chmod 600 "$PREFIX/agent.conf"

# ---------------------------------------------------------------------------
# 4. 开机自启
# ---------------------------------------------------------------------------
if command -v rc-update >/dev/null 2>&1; then
    say "注册 OpenRC 服务"
    cat > /etc/init.d/tunnel-agent <<'EOF'
#!/sbin/openrc-run
name="tunnel-agent"
description="Cloudflare Quick Tunnel auto-rotate agent"
command="/opt/tunnel-agent/tunnel-agent.sh"
command_args="start"
command_background="yes"
pidfile="/run/tunnel-agent.pid"
output_log="/var/log/tunnel-agent.out"
error_log="/var/log/tunnel-agent.err"
respawn_delay=10

depend() { need net; after firewall; }
start_pre() { mkdir -p /var/lib/tunnel-agent; }
EOF
    chmod +x /etc/init.d/tunnel-agent
    rc-update add tunnel-agent default >/dev/null 2>&1
    say "已注册 tunnel-agent"
elif command -v systemctl >/dev/null 2>&1; then
    say "注册 systemd 服务"
    cat > /etc/systemd/system/tunnel-agent.service <<'EOF'
[Unit]
Description=Cloudflare Quick Tunnel auto-rotate agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/tunnel-agent/tunnel-agent.sh start
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tunnel-agent >/dev/null 2>&1
    say "已注册 tunnel-agent.service"
else
    warn "无 OpenRC/systemd，跳过服务注册"
fi

# ---------------------------------------------------------------------------
# 5. cron 健康检查
# ---------------------------------------------------------------------------
CRON_LINE="*/15 * * * * $PREFIX/tunnel-agent.sh health >/dev/null 2>&1"
for f in /etc/crontabs/root /var/spool/cron/crontabs/root; do
    [ -d "$(dirname "$f")" ] || continue
    if [ -f "$f" ] && grep -qF "tunnel-agent.sh health" "$f" 2>/dev/null; then
        say "cron 已存在"
        break
    fi
    printf '%s\n' "$CRON_LINE" >> "$f"
    say "已加 cron: $f"
    rc-service crond restart >/dev/null 2>&1 || systemctl restart cron >/dev/null 2>&1
    break
done

# ---------------------------------------------------------------------------
# 6. 停掉官方脚本起的同后端 cloudflared，避免抢隧道
# ---------------------------------------------------------------------------
say "清理可能冲突的旧 cloudflared"
OLD=$(pgrep -f 'cloudflared tunnel --url http://127.0.0.1:' 2>/dev/null | head -20)
if [ -n "${OLD:-}" ]; then
    for p in $OLD; do
        if [ "$p" != "$$" ]; then
            kill "$p" 2>/dev/null && say "  已停止 pid=$p"
        fi
    done
    sleep 2
fi

# ---------------------------------------------------------------------------
# 7. 探测 + 启动
# ---------------------------------------------------------------------------
say "探测后端端口"
"$PREFIX/tunnel-agent.sh" probe || warn "探测失败，稍后手动改 BACKEND_PORT"

if [ "$DO_START" = "1" ]; then
    echo
    "$PREFIX/tunnel-agent.sh" start
    echo
    "$PREFIX/tunnel-agent.sh" status
    echo
    say "完成。之后可用这些命令："
    echo "     状态  $PREFIX/tunnel-agent.sh status"
    echo "     轮换  $PREFIX/tunnel-agent.sh rotate"
    echo "     日志  tail -f /var/lib/tunnel-agent/agent.log"
else
    say "已安装未启动。运行 $PREFIX/tunnel-agent.sh start 开始"
fi
