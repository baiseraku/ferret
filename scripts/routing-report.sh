#!/bin/bash
# 生成"远端代理分流"报告：服务器上 OpenAI 是否走隧道、其余是否直连。
# 用法: scripts/routing-report.sh [ssh别名]   （默认 $CODEX_PROBE_HOST）
ALIAS="${1:-${CODEX_PROBE_HOST:-my-server}}"
SSH=/usr/bin/ssh
TS="$(date '+%F %T')"
out=$("$SSH" -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
      -o ControlMaster=no -o ControlPath=none "$ALIAS" 'bash -ls' <<'REMOTE' 2>/dev/null
set -u
mih=$(systemctl --user is-active mihomo 2>/dev/null || echo inactive)
models=$(curl -s -o /dev/null -m 6 -w '%{http_code}' --noproxy '*' http://127.0.0.1:3425/v1/models)
openai=$(curl -s -o /dev/null -m 12 -w '%{http_code}' https://api.openai.com/v1/models)
github=$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://github.com)
tp=$(curl -s -m 12 https://chatgpt.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{printf "%s", $2} /^colo=/{printf " (%s)", $2}')
td=$(curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{printf "%s", $2} /^colo=/{printf " (%s)", $2}')
echo "MIH=$mih"
echo "MODELS=$models"
echo "OPENAI=$openai"
echo "GITHUB=$github"
echo "TRACE_PROXY=$tp"
echo "TRACE_DIRECT=$td"
echo "HITS_BEGIN"
journalctl --user -u mihomo --since '-10min' --no-pager 2>/dev/null \
  | grep -oE '\-\-> [^ ]+ match .* using [A-Z]+' \
  | sed -E 's/--> ([^ :]+)[^ ]* match.* using ([A-Z]+)/\2 \1/' \
  | sort | uniq -c | sort -rn | head -12
echo "HITS_END"
echo "CONN_BEGIN"
curl -s -m 5 http://127.0.0.1:9090/connections 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("  (mihomo API 无响应)"); raise SystemExit
cs=d.get("connections") or []
if not cs: print("  (当前空闲，无活动连接)")
for c in cs[:10]:
    m=c.get("metadata",{})
    print("  %s:%s  rule=%s/%s  chain=%s" % (m.get("host") or m.get("destinationIP"), m.get("destinationPort"), c.get("rule"), c.get("rulePayload") or "", ",".join(c.get("chains") or [])))
'
echo "CONN_END"
REMOTE
)
get(){ printf '%s' "$out" | sed -n "s/^$1=//p" | head -1; }
section(){ printf '%s' "$out" | sed -n "/^$1$/,/^$2$/p" | sed '1d;$d'; }

mih=$(get MIH); models=$(get MODELS); openai=$(get OPENAI); github=$(get GITHUB)
tp=$(get TRACE_PROXY); td=$(get TRACE_DIRECT)

echo "远端代理分流报告  $TS"
echo "────────────────────────────────────────"
echo "mihomo 服务      : ${mih:-?}"
echo "隧道→模型接口    : ${models:-?}  (127.0.0.1:3425/v1/models)"
echo "OpenAI 可达性    : ${openai:-?}  (401=经隧道到达)"
echo "GitHub 直连      : ${github:-?}  (200=服务器直连)"
echo "chatgpt 出口     : ${tp:-?}   ← 应为你 Mac/机场出口"
echo "cloudflare 出口  : ${td:-?}   ← 应为服务器自身出口"
echo
echo "最近 10 分钟路由命中（PROXY=走隧道 / DIRECT=直连）:"
section HITS_BEGIN HITS_END | sed 's/^/  /'
echo
echo "当前活动连接:"
section CONN_BEGIN CONN_END | sed 's/^/  /'
