#!/bin/bash
# 深度健康检查：隧道端口 / 模型网关 / 出网出口 / 封禁迹象（并行执行，约 1-3 秒）
# 用法: health-check.sh [探测用 SSH 别名]，输出一行 JSON
set -uo pipefail
ROOT="${FERRET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done
HOST="${1:-${CODEX_PROBE_HOST:-my-server}}"

out=$(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes \
                   -o ControlMaster=no -o ControlPath=none "$HOST" 'bash -ls' <<'REMOTE' 2>/dev/null
tmp=$(mktemp -d)
( ss -lnt 2>/dev/null | grep -cE '127\.0\.0\.1:(3425|58922)\b' > "$tmp/ports" ) &
( curl -s -o /dev/null -m 4 -w '%{http_code}' --noproxy '*' http://127.0.0.1:3425/v1/models > "$tmp/models" ) &
( curl -s -o /dev/null -m 6 -w '%{http_code}' https://api.openai.com/v1/models > "$tmp/openai" ) &
( curl -s -m 6 https://chatgpt.com/cdn-cgi/trace > "$tmp/trace" ) &
( curl -s -o /dev/null -m 6 -w '%{http_code}' https://chatgpt.com/backend-api/me > "$tmp/me" ) &
( curl -s -m 5 --noproxy '*' https://ifconfig.me/ip > "$tmp/server_ip" ) &
wait
exit_ip=$(awk -F= '/^ip=/{print $2}' "$tmp/trace" 2>/dev/null)
loc=$(awk -F= '/^loc=/{print $2}' "$tmp/trace" 2>/dev/null)
printf '{"ports":%s,"models":"%s","openai":"%s","me":"%s","exit":"%s","loc":"%s","server_ip":"%s"}\n' \
  "$(cat "$tmp/ports" 2>/dev/null || echo 0)" \
  "$(cat "$tmp/models" 2>/dev/null || echo 000)" \
  "$(cat "$tmp/openai" 2>/dev/null || echo 000)" \
  "$(cat "$tmp/me" 2>/dev/null || echo 000)" \
  "${exit_ip:-}" "${loc:-}" "$(cat "$tmp/server_ip" 2>/dev/null || true)"
rm -rf "$tmp"
REMOTE
)

if [ -z "$out" ]; then
  echo '{"ports":0,"models":"000","openai":"000","me":"000","exit":"","loc":"","server_ip":"","error":"ssh"}'
else
  echo "$out" | tail -1
fi
