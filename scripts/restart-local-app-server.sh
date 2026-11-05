#!/bin/bash
# 重启本机（Mac）上的 codex app-server：Codex 桌面端/本地会话卡住时用。
# 用法: restart-local-app-server.sh [--status]
set -uo pipefail
MODE="${1:-restart}"

list_servers() {
  /bin/ps -eo pid,lstart,command | grep -E '[c]odex([[:space:]].*)?[[:space:]]app-server' | grep -v 'restart-local' | head -5
}

echo "本机 app-server"
before=$(list_servers)
if [ -z "$before" ]; then
  echo "  （没有运行中的 app-server：Codex 桌面端没开，或还没建立本地连接）"
else
  echo "$before" | sed 's/^/  /'
fi

[ "$MODE" = "--status" ] && exit 0

if [ -z "$before" ]; then
  echo "无需重启。"
  exit 0
fi

echo "--- 发送重启 ---"
pkill -f '[c]odex([[:space:]].*)?[[:space:]]app-server' 2>/dev/null || true
sleep 2

for i in $(seq 1 8); do
  sleep 1
  after=$(list_servers)
  if [ -n "$after" ]; then
    echo "--- 新 app-server ---"
    echo "$after" | sed 's/^/  /'
    echo "完成：本机 codex app-server 已重启"
    exit 0
  fi
done

echo "旧进程已结束；桌面端下次连接时会自动拉起新进程。"
