#!/bin/bash
# 修复"界面已连接但模型超时"：停止常驻隧道 → 清理服务器残留 SSH 会话 → 释放端口 → 重启隧道 → 验证。
# 用法: heal.sh check|heal|status [隧道Host] [探测Host]
set -uo pipefail
ROOT="${FERRET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MODE="${1:-status}"
HOST="${2:-${CODEX_TUNNEL_HOST:-my-tunnel}}"
PROBE="${3:-${CODEX_PROBE_HOST:-my-server}}"
SLUG=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9-' '-')
LABEL="local.ferret.tunnel-$SLUG"
LOG="$ROOT/log/heal.log"
SSH=/usr/bin/ssh
UID_NUM="$(id -u)"

[ -f "$ROOT/scripts/local.env" ] && . "$ROOT/scripts/local.env"

mkdir -p "$ROOT/log"
say(){ printf '  %s\n' "$*"; }
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

remote() { "$SSH" -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
                    -o ControlMaster=no -o ControlPath=none "$PROBE" "$@"; }
probe_model() { remote 'bash -lc "curl -s -o /dev/null -m 6 -w %{http_code} --noproxy \"*\" http://127.0.0.1:3425/v1/models"' 2>/dev/null; }
resident_loaded() { /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; }
resident_pid() { /bin/launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/pid = /{print $3; exit}'; }

stop_resident() {
  if resident_loaded; then /bin/launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null; sleep 1; fi
}

cleanup_stale() {
  # 只杀 @notty 的旧会话（交互终端不动），并排除执行本脚本自身的会话链
  remote 'bash -s' <<'REMOTE'
set -u
me=$$
p=$me
for _ in 1 2 3 4 5; do
  p=$(awk '{print $4}' /proc/$p/stat 2>/dev/null) || break
  [ -z "$p" ] && break
  if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q '^sshd: '; then self=$p; break; fi
done
self=${self:-0}
n=0
for pid in $(pgrep -u "$(id -u)" -f 'sshd: .*@notty' 2>/dev/null); do
  [ "$pid" = "$self" ] && continue
  par=$(awk '{print $4}' /proc/$pid/stat 2>/dev/null)
  [ "$par" = "$self" ] && continue
  kill -TERM "$pid" 2>/dev/null && n=$((n+1))
done
echo "$n"
REMOTE
}

ports_free() {
  remote 'python3 -' <<'PY'
import socket
ok = True
for p in (3425, 58922):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: s.bind(('127.0.0.1', p)); s.listen(1)
    except OSError: ok = False
    finally: s.close()
print('free' if ok else 'busy')
PY
}

wait_model() {  # 最多等 N 秒拿到 200
  local n="${1:-30}" i=0 code
  while [ $i -lt "$n" ]; do
    code=$(probe_model)
    [ "$code" = "200" ] && { echo 200; return 0; }
    sleep 1; i=$((i+1))
  done
  echo "${code:-000}"; return 1
}

health() { [ "$(probe_model)" = "200" ]; }

status() {
  local rc=0
  if resident_loaded; then say "launchd(${HOST}): 已加载（$LABEL）"; else say "launchd(${HOST}): 未加载"; rc=1; fi
  say "ssh 进程: $(resident_pid)"
  local ports; ports=$(remote 'ss -lnt 2>/dev/null | grep -cE "127.0.0.1:(3425|58922)\b"' 2>/dev/null)
  say "远端端口监听数: ${ports:-?} / 2"; [ "${ports:-0}" = "2" ] || rc=1
  local code; code=$(probe_model)
  say "3425/v1/models = ${code:-?}"; [ "${code:-0}" = "200" ] || rc=1
  return $rc
}

do_heal() {
  log "heal($HOST/$PROBE): probe=$(probe_model)"
  echo "1) 停止常驻隧道（释放它持有的会话）"
  stop_resident
  sleep 1
  echo "2) 清理服务器上残留的旧 SSH 会话"
  local killed; killed=$(cleanup_stale 2>/dev/null | tail -1)
  say "清理会话数: ${killed:-0}"
  sleep 2
  echo "3) 检查端口是否释放"
  local f; f=$(ports_free)
  say "端口: $f"
  if [ "$f" = "busy" ]; then
    echo "   端口仍被占用，等待服务器 sshd 回收（最多 15 秒）…"
    local i=0
    while [ $i -lt 15 ] && [ "$(ports_free)" = "busy" ]; do sleep 1; i=$((i+1)); done
    say "端口: $(ports_free)"
  fi
  echo "4) 重启常驻隧道"
  "$ROOT/scripts/resident.sh" start "$HOST" 2>&1 | sed 's/^/  /'
  echo "5) 等待模型接口恢复…"
  local code; code=$(wait_model 40)
  if [ "$code" = "200" ]; then
    echo "修复成功：3425/v1/models = 200"
    log "heal: 成功"
    return 0
  fi
  echo "第一次未恢复（probe=$code），再重试一次…" >&2
  stop_resident; cleanup_stale >/dev/null 2>&1; sleep 2
  "$ROOT/scripts/resident.sh" start "$HOST" >/dev/null 2>&1
  code=$(wait_model 40)
  if [ "$code" = "200" ]; then
    echo "修复成功（重试）：3425/v1/models = 200"
    log "heal: 重试成功"
    return 0
  fi
  echo "修复失败（probe=$code），请检查网络或服务器状态" >&2
  log "heal: 失败 probe=$code"
  return 1
}

case "$MODE" in
  check) health && echo healthy || echo broken ;;
  heal) health && { echo healthy; exit 0; }; do_heal ;;
  status) status ;;
  *) echo "用法: $0 check|heal|status [隧道Host] [探测Host]" >&2; exit 2 ;;
esac
