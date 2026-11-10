#!/bin/bash
# 读取/设置远端 codex 的 model_auto_compact_token_limit
# 用法: set-remote-context.sh [--get] [--set N] [--reset] [--host <别名>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done
HOST="${CODEX_PROBE_HOST:-my-server}"
MODE="get"; VALUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --get) MODE="get" ;;
    --set) MODE="set"; VALUE="${2:?}"; shift ;;
    --reset) MODE="reset" ;;
    --host) HOST="${2:?}"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
  -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none "$HOST" "MODE='$MODE' VALUE='$VALUE' python3 -" <<'PY'
import os, re, shutil, sys, time
path = os.path.expanduser('~/.codex/config.toml')
key = 'model_auto_compact_token_limit'
mode = os.environ.get('MODE', 'get')
value = os.environ.get('VALUE', '')

try:
    text = open(path).read()
except FileNotFoundError:
    if mode == 'get':
        print('unset'); sys.exit(0)
    text = ''

m = re.search(r'(?m)^%s\s*=\s*(.*)$' % key, text)
current = m.group(1).strip() if m else 'unset'

if mode == 'get':
    print(current); sys.exit(0)

shutil.copy2(path, path + '.bak-context-' + time.strftime('%Y%m%d-%H%M%S'))

if mode == 'reset':
    text = re.sub(r'(?m)^%s\s*=.*\n?' % key, '', text)
    open(path, 'w').write(text)
    print('unset'); sys.exit(0)

# mode == set
try:
    n = int(value)
except ValueError:
    print('invalid: 必须是整数', file=sys.stderr); sys.exit(2)
if n < 1000:
    print('invalid: 至少 1000', file=sys.stderr); sys.exit(2)

line = '%s = %d' % (key, n)
if m:
    text = re.sub(r'(?m)^%s\s*=.*$' % key, line, text)
else:
    # 插到文件最前面的普通键区域
    if text and not text.endswith('\n'):
        text += '\n'
    text = line + '\n' + text
open(path, 'w').write(text)
print('%s = %d' % (key, n))
PY
