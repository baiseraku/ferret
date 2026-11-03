#!/bin/bash
# 管理常驻隧道（launchd user agent）。支持多台服务器，每台一个 launchd 任务。
#   resident.sh install|start|stop|status|uninstall [sshHost]
#   sshHost 默认 my-tunnel；对应的 launchd label 为 local.remotetunnel.tunnel-<host>
set -uo pipefail
ROOT="${CODEX_REMOTE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MODE="${1:-status}"
HOST="${2:-${CODEX_TUNNEL_HOST:-my-tunnel}}"
SLUG=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9-' '-' )
LABEL="local.remotetunnel.tunnel-$SLUG"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$ROOT/log/tunnel-resident-$HOST.log"
UID_NUM="$(id -u)"

say(){ printf '  %s\n' "$*"; }
is_loaded() { /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; }
pid_of() { /bin/launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/pid = /{print $3; exit}'; }

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/log" "$HOME/.local/bin"
  cp "$ROOT/scripts/tunnel-resident.sh" "$HOME/.local/bin/remote-tunnel-resident"
  chmod +x "$HOME/.local/bin/remote-tunnel-resident"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HOME/.local/bin/remote-tunnel-resident</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_REMOTE_ROOT</key><string>$ROOT</string>
    <key>CODEX_TUNNEL_HOST</key><string>$HOST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$ROOT/log/tunnel-resident.out</string>
  <key>StandardErrorPath</key><string>$ROOT/log/tunnel-resident.err</string>
</dict>
</plist>
PLIST
  /usr/bin/plutil -lint "$PLIST" >/dev/null || { echo "plist 校验失败" >&2; return 1; }
}

probe() {
  /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes \
    -o ControlMaster=no -o ControlPath=none "${CODEX_PROBE_HOST:-my-server}" \
    'bash -lc "curl -s -o /dev/null -m 6 -w %{http_code} --noproxy \"*\" http://127.0.0.1:3425/v1/models"' 2>/dev/null
}

start() {
  is_loaded && { echo "常驻隧道已在运行（${HOST}）"; return 0; }
  [ -f "$PLIST" ] || write_plist || return 1
  /bin/launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null
  /bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>&1 | sed 's/^/  /'
  /bin/launchctl kickstart -k "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
  sleep 3
  is_loaded && echo "常驻隧道已启动（${HOST}）" || { echo "启动失败，见 $LOG" >&2; return 1; }
}

stop() {
  if is_loaded; then
    /bin/launchctl bootout "gui/$UID_NUM/$LABEL" 2>&1 | sed 's/^/  /'
    echo "常驻隧道已停止（${HOST}）"
  else
    echo "常驻隧道未在运行（${HOST}）"
  fi
}

status() {
  local rc=0
  if is_loaded; then say "launchd($HOST): 已加载（${LABEL}）"; else say "launchd($HOST): 未加载"; rc=1; fi
  local pid; pid=$(pid_of)
  [ -n "${pid:-}" ] && say "ssh 进程: $pid" || say "ssh 进程: 未找到"
  local ports; ports=$(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none my-server 'ss -lnt 2>/dev/null | grep -cE "127.0.0.1:(3425|58922)\b"' 2>/dev/null)
  say "远端端口监听数: ${ports:-?} / 2"
  [ "${ports:-0}" = "2" ] || rc=1
  local code; code=$(probe)
  say "3425/v1/models = ${code:-?}"
  [ "${code:-0}" = "200" ] || rc=1
  return $rc
}

case "$MODE" in
  install)
    write_plist || exit 1
    /usr/bin/ssh -O exit my-server >/dev/null 2>&1
    sleep 1
    start || exit 1
    sleep 2
    status
    ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  uninstall)
    /bin/launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    echo "已卸载常驻隧道（${HOST}）"
    ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
