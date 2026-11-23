#!/bin/sh
# ============================================================================
# install-agent.sh — 一键安装 tunnel-agent
#
# 用法：
#   sh install-agent.sh                     交互式安装（推荐）
#   sh install-agent.sh --conf /path/agent.conf   使用已有配置（换服务器时用这个）
#
# 自动识别 OpenRC(Alpine) / systemd(Debian/Ubuntu)，装 cloudflared、服务、cron。
# ============================================================================

set -u

PREFIX=/opt/tunnel-agent
CONF_SRC=""
INTERACTIVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_SRC="$2"; INTERACTIVE=0; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "未知参数 $1"; exit 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "需要 root"; exit 1; }

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------- 0. 基础依赖 ----------
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "缺少 curl 和 wget，无法继续"
    if command -v apk >/dev/null 2>&1; then
        say "尝试 apk add curl"
        apk add --no-cache curl ca-certificates || exit 1
    else
        say "请先安装 curl"; exit 1
    fi
fi
# Alpine 常见坑：缺 ca-certificates 导致 cloudflared TLS 握手失败
if [ -d /etc/apk ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    say "安装 ca-certificates"
    apk add --no-cache ca-certificates >/dev/null 2>&1
fi

# ---------- 1. cloudflared ----------
if command -v cloudflared >/dev/null 2>&1; then
    say "cloudflared 已存在: $(command -v cloudflared) ($(cloudflared --version 2>/dev/null | head -1))"
else
    say "未找到 cloudflared，开始下载"
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  cfarch=amd64 ;;
        aarch64|arm64) cfarch=arm64 ;;
        armv7l)        cfarch=arm ;;
        *) warn "未知架构 $arch，请手动安装 cloudflared"; exit 1 ;;
    esac
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfarch}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o /usr/local/bin/cloudflared || { warn "下载失败: $url"; exit 1; }
    else
        wget -qO /usr/local/bin/cloudflared "$url" || { warn "下载失败: $url"; exit 1; }
    fi
    chmod +x /usr/local/bin/cloudflared
    say "已安装 $(cloudflared --version 2>/dev/null | head -1)"
fi

# ---------- 2. 脚本与配置 ----------
mkdir -p "$PREFIX"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
cp -f "$SELF_DIR/tunnel-agent.sh" "$PREFIX/tunnel-agent.sh"
chmod +x "$PREFIX/tunnel-agent.sh"
say "主程序 -> $PREFIX/tunnel-agent.sh"

if [ ! -f "$PREFIX/agent.conf" ]; then
    if [ -n "$CONF_SRC" ]; then
        cp -f "$CONF_SRC" "$PREFIX/agent.conf"
        say "使用指定配置 $CONF_SRC"
    elif [ "$INTERACTIVE" = "1" ]; then
        cp -f "$SELF_DIR/agent.conf.example" "$PREFIX/agent.conf"
        say "请编辑 $PREFIX/agent.conf 填写 NODE_ID / API_BASE / REPORT_TOKEN"
        printf "现在打开编辑器？[Y/n] "
        read -r ans
        case "${ans:-Y}" in
            [Yy]*) ${EDITOR:-vi} "$PREFIX/agent.conf" ;;
        esac
    else
        cp -f "$SELF_DIR/agent.conf.example" "$PREFIX/agent.conf"
    fi
else
    say "已存在 $PREFIX/agent.conf，保持不变"
fi
chmod 600 "$PREFIX/agent.conf"

# ---------- 3. 开机自启服务 ----------
if command -v rc-update >/dev/null 2>&1; then
    say "检测到 OpenRC，安装 init 脚本"
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

start_pre() {
    mkdir -p /var/lib/tunnel-agent
}
EOF
    chmod +x /etc/init.d/tunnel-agent
    rc-update add tunnel-agent default >/dev/null 2>&1
    say "已注册 OpenRC 服务 tunnel-agent"
elif command -v systemctl >/dev/null 2>&1; then
    say "检测到 systemd，安装 unit"
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
# cloudflared 由 agent 自行守护，这里只负责拉起

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tunnel-agent >/dev/null 2>&1
    say "已注册 systemd 服务 tunnel-agent"
else
    warn "既无 OpenRC 也无 systemd，跳过服务安装，需自行加入开机脚本"
fi

# ---------- 4. cron：每 15 分钟健康检查 ----------
CRON_LINE="*/15 * * * * $PREFIX/tunnel-agent.sh health >/dev/null 2>&1"

for f in /etc/crontabs/root /var/spool/cron/crontabs/root /etc/cron.d/tunnel-agent; do
    d=$(dirname "$f")
    [ -d "$d" ] || continue
    if [ -f "$f" ] && grep -qF "tunnel-agent.sh health" "$f" 2>/dev/null; then
        say "cron 已存在，跳过"
        break
    fi
    printf '%s\n' "$CRON_LINE" >> "$f"
    say "已写入 cron: $f"
    if [ "$f" = "/etc/crontabs/root" ] || [ "$f" = "/var/spool/cron/crontabs/root" ]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service crond restart >/dev/null 2>&1
        else
            systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
        fi
    fi
    break
done

# ---------- 5. 首次探测与启动 ----------
say "探测后端端口"
"$PREFIX/tunnel-agent.sh" probe || warn "探测失败，请手动在 agent.conf 填 BACKEND_PORT"

printf "\n现在启动隧道？[Y/n] "
read -r ans
case "${ans:-Y}" in
    [Yy]*)
        "$PREFIX/tunnel-agent.sh" start
        echo
        "$PREFIX/tunnel-agent.sh" status
        ;;
    *)
        say "已跳过。稍后执行: $PREFIX/tunnel-agent.sh start"
        ;;
esac

say "安装完成。日志: /var/lib/tunnel-agent/agent.log"
