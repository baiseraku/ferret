#!/bin/bash
# 常驻反向隧道进程（launchd 拉起）：持有 RemoteForward，断线自动重连。
# 目标 Host 由 CODEX_TUNNEL_HOST 指定（默认 my-tunnel）。
set -uo pipefail
ROOT="${FERRET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOST="${CODEX_TUNNEL_HOST:-my-tunnel}"
LOG="$ROOT/log/tunnel-resident-$HOST.log"
mkdir -p "$ROOT/log"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

log "启动常驻隧道（${HOST}）"
while true; do
  /usr/bin/ssh -N -T -o BatchMode=yes -o ConnectTimeout=15 \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o ControlMaster=no -o ControlPath=none "$HOST" 2>>"$LOG"
  rc=$?
  log "ssh($HOST) 退出 rc=${rc}，10 秒后重试"
  sleep 10
done
