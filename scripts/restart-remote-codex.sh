#!/bin/bash
# 重启远程服务器上的 codex app-server（桌面端重连后自动拉起新进程）。
# 用途：模型清单/skills 更新后、或 app-server 卡住时，让它重新加载配置。
# 用法: restart-remote-codex.sh [探测用 SSH 别名] [--status]
set -uo pipefail
ROOT="${FERRET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done

HOST="${1:-${CODEX_PROBE_HOST:-my-server}}"
MODE="${2:-restart}"
SSH() { /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
                      -o ControlMaster=no -o ControlPath=none "$HOST" "$@"; }

list_servers() {
  SSH "ps -eo pid,lstart,cmd | grep -E '[c]odex .*app-server' | head -5" 2>/dev/null
}

echo "服务器: $HOST"
echo "--- 当前 app-server ---"
before=$(list_servers)
if [ -z "$before" ]; then
  echo "  （没有运行中的 app-server；桌面端连接时会自动拉起）"
else
  echo "$before" | sed 's/^/  /'
fi

if [ "$MODE" = "--status" ]; then
  exit 0
fi

echo "--- 发送重启 ---"
SSH "pkill -f '[c]odex .*app-server' 2>/dev/null || true; sleep 1; echo '  已结束旧进程'" || {
  echo "  重启命令执行失败（检查 SSH 连接）" >&2; exit 1; }

# 桌面端通常几秒内自动重连并拉起新进程
for i in $(seq 1 10); do
  sleep 1
  after=$(list_servers)
  if [ -n "$after" ]; then
    echo "--- 新 app-server ---"
    echo "$after" | sed 's/^/  /'
    echo "完成：远端 codex 已重启"
    exit 0
  fi
done

echo "完成：旧进程已结束；新进程会在桌面端重连时自动拉起"
echo "（如果没有自动出现，在桌面端重新打开一次远程工作区即可）"
