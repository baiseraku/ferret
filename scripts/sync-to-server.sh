#!/bin/bash
# 把本机 magpie 的「模型目录 / MCP / skills」同步到远程服务器（拓扑 A）
#
# 用法: sync-to-server.sh [--models] [--mcp] [--skills] [--all] [--host <ssh别名>]
# 默认 --all；任何一项都可单独跑。脚本幂等，改前会在服务器备份 config.toml。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done
ALIAS="${CODEX_PROBE_HOST:-my-server}"
MODELS=0 MCP=0 SKILLS=0 RESTART_APP=0 AGENTS=0 AGENTS_PULL=0 FORCE=0
[ $# -eq 0 ] && set -- --all
while [ $# -gt 0 ]; do
  case "$1" in
    --models) MODELS=1 ;;
    --mcp) MCP=1 ;;
    --skills) SKILLS=1 ;;
    --all) MODELS=1; MCP=1; SKILLS=1 ;;   # AGENTS.md 需显式 --agents
    --host) ALIAS=${2:?}; shift ;;
    --restart-app-server) RESTART_APP=1 ;;
    --agents) AGENTS=1 ;;
    --agents-pull) AGENTS_PULL=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done
SSH=/usr/bin/ssh
SCP=/usr/bin/scp
SSHOPT=(-o BatchMode=yes -o ConnectTimeout=10)
rc=0

say() { printf '  %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1" >&2; exit 1; }; }
need ssh; need scp; need tar

sync_agents_push() {
  echo "== AGENTS.md（本机 → 服务器）=="
  local remote_home remote_user tmp
  remote_home=$("$SSH" "${SSHOPT[@]}" "$ALIAS" 'echo $HOME' 2>/dev/null)
  remote_user=$(basename "$remote_home")
  if [ -z "$remote_home" ]; then echo "  读取远程 HOME 失败" >&2; rc=1; return; fi
  tmp=$(mktemp)
  "$SSH" "${SSHOPT[@]}" "$ALIAS" 'cat ~/.codex/AGENTS.md 2>/dev/null' > "$tmp" || true

  # 路径归一化后比较，忽略本机/服务器 HOME 差异
  if ! diff -q <(sed -e "s#/Users/[^/]*#__HOME__#g" "$HOME/.codex/AGENTS.md")                 <(sed -e "s#/home/[^/]*#__HOME__#g" "$tmp") >/dev/null 2>&1; then
    if [ "$FORCE" != "1" ]; then
      echo "  两份 AGENTS.md 存在路径之外的差异，未自动覆盖。差异摘要："
      diff -u <(sed -e "s#/home/[^/]*#__HOME__#g" "$tmp")               <(sed -e "s#/Users/[^/]*#__HOME__#g" "$HOME/.codex/AGENTS.md") | sed -n '1,25p' | sed 's/^/    /'
      echo "  合并后重试；或加 --force 强制用本机版本覆盖（会先备份远端）。"
      rc=1; rm -f "$tmp"; return
    fi
    echo "  --force：用本机版本覆盖"
  fi

  # 生成远端版本：把本机 HOME 换成远端 HOME
  sed -e "s#/Users/$USER#${remote_home}#g" "$HOME/.codex/AGENTS.md" > "$tmp.new"
  "$SSH" "${SSHOPT[@]}" "$ALIAS" 'cp ~/.codex/AGENTS.md ~/.codex/AGENTS.md.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true'
  "$SCP" -q "${SSHOPT[@]}" "$tmp.new" "$ALIAS:.codex/AGENTS.md" || { rc=1; return; }
  local a b
  a=$(md5 -q "$tmp.new" 2>/dev/null || md5sum "$tmp.new" | cut -d' ' -f1)
  b=$("$SSH" "${SSHOPT[@]}" "$ALIAS" 'md5sum ~/.codex/AGENTS.md | cut -d" " -f1' 2>/dev/null)
  say "已推送 $(wc -l < "$tmp.new" | tr -d ' ') 行（$( [ "$a" = "$b" ] && echo 校验一致 || echo "校验不一致 $a/$b" )）"
  rm -f "$tmp" "$tmp.new"
}

sync_agents_pull() {
  echo "== AGENTS.md（服务器 → 本机）=="
  local remote_home tmp
  remote_home=$("$SSH" "${SSHOPT[@]}" "$ALIAS" 'echo $HOME' 2>/dev/null)
  tmp=$(mktemp)
  "$SSH" "${SSHOPT[@]}" "$ALIAS" 'cat ~/.codex/AGENTS.md 2>/dev/null' > "$tmp" || true
  if [ ! -s "$tmp" ]; then echo "  服务器没有 AGENTS.md" >&2; rc=1; return; fi
  sed -e "s#${remote_home}#/Users/$USER#g" "$tmp" > "$tmp.new"
  if ! diff -q "$HOME/.codex/AGENTS.md" "$tmp.new" >/dev/null 2>&1 && [ "$FORCE" != "1" ] && [ -f "$HOME/.codex/AGENTS.md" ]; then
    echo "  本机 AGENTS.md 将发生变化，差异摘要："
    diff -u "$HOME/.codex/AGENTS.md" "$tmp.new" | sed -n '1,25p' | sed 's/^/    /'
  fi
  cp "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  cp "$tmp.new" "$HOME/.codex/AGENTS.md"
  say "已拉取 $(wc -l < "$HOME/.codex/AGENTS.md" | tr -d ' ') 行（本机旧版已备份）"
  rm -f "$tmp" "$tmp.new"
}

[ -f "$HOME/.codex/magpie-models.json" ] || { echo "找不到 $HOME/.codex/magpie-models.json（magpie 是否在跑？）" >&2; exit 1; }

sync_models() {
  echo "== 模型目录 =="
  local before after
  before=$("$SSH" "${SSHOPT[@]}" "$ALIAS" 'md5sum ~/.codex/magpie-models.json 2>/dev/null | cut -d" " -f1' 2>/dev/null || true)
  "$SCP" -q "${SSHOPT[@]}" "$HOME/.codex/magpie-models.json" "$ALIAS:.codex/magpie-models.json" || { rc=1; return; }
  say "已上传 $(python3 -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.codex/magpie-models.json')))['models']))") 个模型"
  after=$("$SSH" "${SSHOPT[@]}" "$ALIAS" 'md5sum ~/.codex/magpie-models.json 2>/dev/null | cut -d" " -f1' 2>/dev/null || true)
  if [ -n "$before" ] && [ "$before" != "$after" ]; then
    MODELS_CHANGED=1
    say "清单已变化（旧 ${before:0:8} → 新 ${after:0:8}）"
  fi
  # 确保服务器 config.toml 的 provider 指向 magpie + 本机清单，base_url 是 3425
  "$SSH" "${SSHOPT[@]}" "$ALIAS" 'python3 -' <<'PY' || rc=1
import json, os, re, shutil, subprocess, sys
home = os.path.expanduser('~')
p = os.path.join(home, '.codex', 'config.toml')
if not os.path.exists(p):
    print('  服务器没有 ~/.codex/config.toml，先手工建一个再同步'); sys.exit(1)
shutil.copy2(p, p + '.bak-sync')
s = open(p).read()
orig = s
s = re.sub(r'(?m)^model_provider\s*=.*$', 'model_provider = "magpie"', s, count=1) if re.search(r'(?m)^model_provider', s) else 'model_provider = "magpie"\n' + s
catalog = os.path.join(home, '.codex', 'magpie-models.json')
s = re.sub(r'(?m)^model_catalog_json\s*=.*$', 'model_catalog_json = "%s"' % catalog, s, count=1) if re.search(r'(?m)^model_catalog_json', s) else 'model_catalog_json = "%s"\n' % catalog + s
if '[model_providers.magpie]' not in s:
    s = s.rstrip('\n') + '''

[model_providers.magpie]
name = "magpie"
base_url = "http://127.0.0.1:3425/v1"
wire_api = "responses"
experimental_bearer_token = "magpie"
http_headers = { "x-openai-actor-authorization" = "magpie" }
requires_openai_auth = false
'''
else:
    s = re.sub(r'(?m)^(\s*)base_url\s*=.*$', r'\1base_url = "http://127.0.0.1:3425/v1"', s)
if 'requires_openai_auth = true' in s:
    s = s.replace('requires_openai_auth = true', 'requires_openai_auth = false')
if s != orig:
    open(p, 'w').write(s)
    print('  config.toml 已更新（备份 config.toml.bak-sync）')
else:
    print('  config.toml 无需改动')
PY
}

sync_mcp() {
  echo "== MCP =="
  "$SSH" "${SSHOPT[@]}" "$ALIAS" 'python3 -' <<'PY' || rc=1
import os, re, shutil, sys
home = os.path.expanduser('~')
p = os.path.join(home, '.codex', 'config.toml')
s = open(p).read()
hub = 'http://127.0.0.1:3425/mcp/magpie/hub'
if '[mcp_servers.magpie]' not in s:
    shutil.copy2(p, p + '.bak-sync')
    s = s.rstrip('\n') + '\n\n[mcp_servers.magpie]\nurl = "%s"\n' % hub
    open(p, 'w').write(s)
    print('  已加单条 hub：%s' % hub)
else:
    print('  hub 条目已在')
others = re.findall(r'(?m)^\[mcp_servers\.([^\].]+)\]', s)
others = [n for n in others if n not in ('magpie', 'magpie.env')]
if others:
    print('  注意：还有其它 MCP 条目（hub 模式下通常应删掉）: %s' % ', '.join(sorted(set(others))))
PY
}

sync_skills() {
  echo "== skills =="
  local src="$HOME/.config/magpie/library/skills"
  [ -d "$src" ] || { echo "  找不到 $src" >&2; rc=1; return; }
  local n; n=$(ls -1 "$src" | wc -l | tr -d ' ')
  tar czf - -C "$src" --exclude '.DS_Store' . 2>/dev/null \
    | "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none "$ALIAS" 'tar xzf - -C ~/.codex/skills 2>/dev/null' || { rc=1; return; }
  say "已同步 $n 个 skill → ~/.codex/skills（保留服务器 .system）"
}

verify() {
  echo "== 验收 =="
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none "$ALIAS" 'bash -ls' <<'REMOTE' || rc=1
set -u
echo -n "  models:  "; curl -s -o /dev/null -m 8 -w "%{http_code}\n" http://127.0.0.1:3425/v1/models
echo -n "  hub:     "; curl -s -o /dev/null -m 10 -w "%{http_code}\n" -X POST http://127.0.0.1:3425/mcp/magpie/hub \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"p","version":"0"}}}'
echo -n "  skills:  "; ls ~/.codex/skills | grep -v '^\.' | wc -l
echo -n "  base_url: "; grep -m1 'base_url' ~/.codex/config.toml
REMOTE
}

[ "$MODELS" = 1 ] && sync_models
[ "$MCP" = 1 ] && sync_mcp
[ "$SKILLS" = 1 ] && sync_skills
verify
[ $rc -eq 0 ] && if [ "$AGENTS" = "1" ]; then sync_agents_push; fi
if [ "$AGENTS_PULL" = "1" ]; then sync_agents_pull; fi

if [ "${MODELS_CHANGED:-0}" = "1" ]; then
  echo
  echo "提示：服务器上常驻的 codex app-server 在启动时读取模型清单。"
  echo "      已运行的远程工作区需要重连（或重启 app-server）才能看到新模型。"
  if [ "$RESTART_APP" = "1" ]; then
    echo "      正在重启服务器 app-server…"
    "$SSH" "${SSHOPT[@]}" "$ALIAS" "pkill -f '[c]odex .*app-server' 2>/dev/null; sleep 1; echo '  已发送重启，桌面端重连后自动拉起新进程'" || rc=1
  else
    echo "      可加 --restart-app-server 让脚本自动重启它。"
  fi
fi


echo "完成" || echo "有步骤失败，见上" >&2
exit $rc
