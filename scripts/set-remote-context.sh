#!/bin/bash
# 读取/设置远端 codex 的上下文相关配置：
#   model_auto_compact_token_limit（顶层整数）
#   model_context_window（顶层整数）
#   [features.async_compaction] enabled（布尔）
# 用法:
#   set-remote-context.sh --get [--host H]
#   set-remote-context.sh --apply [--limit N] [--window N] [--async 0|1] [--host H]
#   set-remote-context.sh --reset [--host H]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done
HOST="${CODEX_PROBE_HOST:-my-server}"
MODE="get"; LIMIT=""; WINDOW=""; ASYNC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --get) MODE="get" ;;
    --apply) MODE="apply" ;;
    --reset) MODE="reset" ;;
    --limit) LIMIT="${2:?}"; shift ;;
    --window) WINDOW="${2:?}"; shift ;;
    --async) ASYNC="${2:?}"; shift ;;
    --host) HOST="${2:?}"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
  -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none "$HOST" \
  "MODE='$MODE' LIMIT='$LIMIT' WINDOW='$WINDOW' ASYNC='$ASYNC' python3 -" <<'PY'
import json, os, re, shutil, sys, time

path = os.path.expanduser('~/.codex/config.toml')
mode = os.environ.get('MODE', 'get')
limit = os.environ.get('LIMIT', '').strip()
window = os.environ.get('WINDOW', '').strip()
async_v = os.environ.get('ASYNC', '').strip()

try:
    text = open(path).read()
except FileNotFoundError:
    text = ''

def find_top(key):
    m = re.search(r'(?m)^%s\s*=\s*(.*)$' % re.escape(key), text)
    return m.group(1).strip() if m else None

if mode == 'get':
    # async compaction 的 enabled
    sec = re.search(r'(?ms)^\[features\.async_compaction\]\s*\n(.*?)(?=^\[|\Z)', text)
    enabled = None
    if sec:
        m = re.search(r'(?m)^\s*enabled\s*=\s*(true|false)', sec.group(1))
        enabled = m.group(1) if m else None
    print(json.dumps({
        'model_auto_compact_token_limit': find_top('model_auto_compact_token_limit') or 'unset',
        'model_context_window': find_top('model_context_window') or 'unset',
        'async_compaction': enabled if enabled else 'unset',
    }))
    sys.exit(0)

shutil.copy2(path, path + '.bak-context-' + time.strftime('%Y%m%d-%H%M%S')) if os.path.exists(path) else None

def set_top(key, value):
    global text
    if value == '':
        return
    line = '%s = %s' % (key, value)
    if re.search(r'(?m)^%s\s*=' % re.escape(key), text):
        text = re.sub(r'(?m)^%s\s*=.*$' % re.escape(key), line, text)
    else:
        # 插到第一个 [table] 之前，保持顶层键
        m = re.search(r'(?m)^\[', text)
        if m:
            text = text[:m.start()] + line + '\n' + text[m.start():]
        else:
            text = text.rstrip('\n') + '\n' + line + '\n'

def set_async(value):
    global text
    if value not in ('0', '1'):
        return
    want = 'true' if value == '1' else 'false'
    sec = re.search(r'(?ms)^\[features\.async_compaction\]\s*\n(.*?)(?=^\[|\Z)', text)
    if sec:
        body = sec.group(1)
        if re.search(r'(?m)^\s*enabled\s*=', body):
            body = re.sub(r'(?m)^\s*enabled\s*=.*$', 'enabled = ' + want, body)
        else:
            body = body.rstrip('\n') + '\n' + 'enabled = ' + want + '\n'
        text = text[:sec.start(1)] + body + text[sec.end(1):]
    else:
        text = text.rstrip('\n') + '\n\n[features.async_compaction]\nenabled = ' + want + '\n'

if mode == 'reset':
    text = re.sub(r'(?m)^model_auto_compact_token_limit\s*=.*\n?', '', text)
    text = re.sub(r'(?m)^model_context_window\s*=.*\n?', '', text)
    text = re.sub(r'(?ms)^\[features\.async_compaction\]\s*\n(?:[^\[].*\n?)*', '', text)
else:
    if limit:
        try:
            n = int(limit)
            if n < 1000: raise ValueError
        except ValueError:
            print('invalid limit', file=sys.stderr); sys.exit(2)
        set_top('model_auto_compact_token_limit', str(n))
    if window:
        try:
            n = int(window)
            if n < 1000: raise ValueError
        except ValueError:
            print('invalid window', file=sys.stderr); sys.exit(2)
        set_top('model_context_window', str(n))
    set_async(async_v)

text = re.sub(r'\n{3,}', '\n\n', text)
open(path, 'w').write(text)
print('applied')
PY
