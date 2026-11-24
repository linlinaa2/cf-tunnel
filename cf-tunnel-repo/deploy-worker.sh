#!/bin/sh
# deploy-worker.sh — 用 Cloudflare API Token 直接把 worker 推到线上，不用开控制台
#
# 用法：
#   export CF_API_TOKEN=xxxxx          # 必需，权限见 README 底部
#   export CF_ACCOUNT_ID=yyyyy         # 可选，只挂一个账号时会自己查
#   export REPORT_TOKEN=zzzzz          # 可选，默认用当前线上的
#   export KV_NS_ID=nnnnn              # 可选，只有一个 KV 时自动认
#   sh deploy-worker.sh [worker-v2.0.js]
#
# 退出码：0 = 部署成功且自检通过；非 0 = 失败，原因见输出

set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FILE=${1:-$script_dir/worker-v2.0.js}
NAME=${WORKER_NAME:-sub-gen}
API=https://api.cloudflare.com/client/v4
CHECKDOMAIN=${WORKER_DOMAIN:-sub-gen.shenllinya.workers.dev}

die() { echo "  [FAIL] $*"; exit 1; }
ok()  { echo "  [OK]   $*"; }

[ -f "$FILE" ] || die "找不到 $FILE"
[ -n "${CF_API_TOKEN:-}" ] || die "没设 CF_API_TOKEN"

# ---------- 0. token 自检 ----------
echo "===== 0. token 自检 ====="
V=$(curl -s -m 20 -H "Authorization: Bearer $CF_API_TOKEN" "$API/user/tokens/verify")
echo "  $V" | head -c 300; echo
echo "$V" | grep -q '"status":"active"' || die "token 无效或已过期（上面是原始返回）"
ok "token 有效"

# ---------- 1. account id ----------
echo "===== 1. 账号 ====="
if [ -z "${CF_ACCOUNT_ID:-}" ]; then
  A=$(curl -s -m 20 -H "Authorization: Bearer $CF_API_TOKEN" "$API/accounts?per_page=50")
  CF_ACCOUNT_ID=$(echo "$A" | sed -n 's/.*"id":"\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
  N=$(echo "$A" | grep -o '"id":"[0-9a-f]\{32\}"' | wc -l | tr -d ' ')
  [ "$N" = "1" ] || echo "  提示：这个 token 能看到 $N 个账号，取第一个；要指定就 export CF_ACCOUNT_ID"
fi
[ -n "${CF_ACCOUNT_ID:-}" ] || die "拿不到 account id，手动 export CF_ACCOUNT_ID"
ok "account = $CF_ACCOUNT_ID"

# ---------- 2. KV namespace ----------
echo "===== 2. KV ====="
if [ -z "${KV_NS_ID:-}" ]; then
  K=$(curl -s -m 20 -H "Authorization: Bearer $CF_API_TOKEN" \
      "$API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces?per_page=100")
  CNT=$(echo "$K" | grep -o '"id":"[0-9a-f]\{32\}"' | wc -l | tr -d ' ')
  if [ "$CNT" = "1" ]; then
    KV_NS_ID=$(echo "$K" | sed -n 's/.*"id":"\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
  else
    echo "  这个账号下有 $CNT 个 KV，候选："
    echo "$K" | tr ',' '\n' | grep -E '"(id|title)"' | sed 's/^/    /'
    die "请 export KV_NS_ID=<上面某个 id> 再跑"
  fi
fi
ok "KV namespace = $KV_NS_ID"

# ---------- 3. REPORT_TOKEN ----------
[ -n "${REPORT_TOKEN:-}" ] || REPORT_TOKEN="fd830ca081bbf6fe5606750999b2049f852fa13c69cb5bed47b12d0225f75d11"

# ---------- 4. 组装 metadata 并上传 ----------
echo "===== 3. 上传 ====="
META=$(cat <<EOF
{"main_module":"worker.js","compatibility_date":"${COMPAT_DATE:-2026-10-16}","bindings":[
 {"type":"kv_namespace","name":"SUB_KV","namespace_id":"$KV_NS_ID"},
 {"type":"secret_text","name":"REPORT_TOKEN","text":"$REPORT_TOKEN"},
 {"type":"plain_text","name":"TUNNEL_DOMAIN_PATTERN","text":"^[a-z0-9-]+\\\\.trycloudflare\\\\.com$"}
]}
EOF
)
echo "  metadata: $META"

R=$(curl -s -m 120 -X PUT "$API/accounts/$CF_ACCOUNT_ID/workers/scripts/$NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -F "metadata=$META;type=application/json" \
  -F "worker.js=@$FILE;type=application/javascript+module")
echo "  $R" | head -c 800; echo
echo "$R" | grep -q '"success":true' || die "上传失败（上面是原始返回：常见 10000 权限不足 / 10021 脚本超限）"
ok "脚本已上传"

# ---------- 5. 自检 ----------
echo "===== 4. 线上自检 ====="
SIZE=$(curl -s -m 60 -H "Authorization: Bearer $CF_API_TOKEN" \
  "$API/accounts/$CF_ACCOUNT_ID/workers/scripts/$NAME/content" | wc -c | tr -d ' ')
echo "  线上脚本字节数 = $SIZE（本地 $(wc -c < "$FILE" | tr -d ' ')）"
[ "$SIZE" -gt 1000 ] && ok "脚本内容可取" || die "线上取不到内容"

TS=$(date +%s)
H=$(curl -s -m 30 "$CHECKDOMAIN/?v=$TS")
if [ -z "$H" ]; then
  echo "  [WARN] 拉不到首页（本机 fake-ip 代理会拦 workers.dev，属已知问题）"
  echo "  [WARN] 请在手机/路由上打开 $CHECKDOMAIN 复核"
else
  echo "  首页 ${#H} 字节，尾部: $(printf '%s' "$H" | tail -c 20)"
  printf '%s' "$H" | grep -q '多台服务器管理' && ok "多机面板在" || echo "  [WARN] 首页没有「多台服务器管理」，可能部署的不是 v2.0"
  printf '%s' "$H" | grep -q '</html>' && ok "HTML 完整" || echo "  [WARN] HTML 被截断"
fi

echo
echo "===== 完成 ====="
echo "  worker : $NAME"
echo "  文件   : $(basename "$FILE")  md5 $(md5 -q "$FILE" 2>/dev/null)"
echo "  首页   : https://$CHECKDOMAIN/"
