#!/bin/bash
# 本机 → 服务器的同步：skills / 模型目录 / AGENTS.md（路径均可自定义）
# 用法:
#   sync-to-server.sh [--skills] [--models] [--agents] [--agents-pull] [--all]
#                     [--host <探测别名>] [--force] [--no-mirror]
#                     [--skills-src P] [--skills-dest P]
#                     [--models-src P] [--models-dest P]
#                     [--agents-src P] [--agents-dest P]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for _f in "$ROOT/scripts/local.env" "$HOME/.config/ferret/local.env"; do
  [ -f "$_f" ] && . "$_f" && break
done

ALIAS="${CODEX_PROBE_HOST:-my-server}"
DO_MODELS=0 DO_SKILLS=0 DO_AGENTS=0 DO_PULL=0 FORCE=0 MIRROR=1
SKILLS_SRC="${SKILLS_SRC:-$HOME/.agents/skills}"
SKILLS_DEST="${SKILLS_DEST:-~/.codex/skills}"
MODELS_SRC="${MODELS_SRC:-$HOME/.codex/magpie-models.json}"
MODELS_DEST="${MODELS_DEST:-~/.codex/magpie-models.json}"
AGENTS_SRC="${AGENTS_SRC:-$HOME/.codex/AGENTS.md}"
AGENTS_DEST="${AGENTS_DEST:-~/.codex/AGENTS.md}"

[ $# -eq 0 ] && set -- --all
while [ $# -gt 0 ]; do
  case "$1" in
    --skills) DO_SKILLS=1 ;;
    --models) DO_MODELS=1 ;;
    --agents) DO_AGENTS=1 ;;
    --agents-pull) DO_PULL=1 ;;
    --all) DO_MODELS=1; DO_SKILLS=1 ;;
    --host) ALIAS="${2:?}"; shift ;;
    --force) FORCE=1 ;;
    --no-mirror) MIRROR=0 ;;
    --skills-src) SKILLS_SRC="${2:?}"; shift ;;
    --skills-dest) SKILLS_DEST="${2:?}"; shift ;;
    --models-src) MODELS_SRC="${2:?}"; shift ;;
    --models-dest) MODELS_DEST="${2:?}"; shift ;;
    --agents-src) AGENTS_SRC="${2:?}"; shift ;;
    --agents-dest) AGENTS_DEST="${2:?}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

expand_local() { case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
SKILLS_SRC=$(expand_local "$SKILLS_SRC")
MODELS_SRC=$(expand_local "$MODELS_SRC")
AGENTS_SRC=$(expand_local "$AGENTS_SRC")

SSH=/usr/bin/ssh
SCP=/usr/bin/scp
SSHOPT=(-o BatchMode=yes -o ConnectTimeout=10)
rc=0
say() { printf '  %s\n' "$*"; }

remote_home=$("$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" 'echo $HOME' 2>/dev/null || true)
if [ -z "$remote_home" ]; then
  echo '{"error":"ssh"}'
  echo "连不上服务器（$ALIAS）" >&2
  exit 1
fi
expand_remote() { case "$1" in "~/"*) printf '%s/%s' "$remote_home" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

# ---------- skills ----------
sync_skills() {
  echo "== skills =="
  local src="$SKILLS_SRC" dest; dest=$(expand_remote "$SKILLS_DEST")
  [ -d "$src" ] || { echo "  找不到来源目录: $src" >&2; rc=1; return; }
  local keep n tmp
  keep=$(cd "$src" && find -L . -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null \
         | grep -vE '^\.(git|DS_Store)$' | sort | paste -sd, -)
  n=$(printf '%s' "$keep" | tr ',' '\n' | grep -c .)
  tmp=$(mktemp)
  COPYFILE_DISABLE=1 tar czhf "$tmp" --no-mac-metadata --no-xattrs \
      --exclude '.DS_Store' --exclude '.git' --exclude 'node_modules' --exclude '__pycache__' --exclude '._*' \
      -C "$src" . 2>/dev/null || { rc=1; rm -f "$tmp"; return; }
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" \
    "mkdir -p '$dest' && tar --warning=no-unknown-keyword --overwrite -xzf - -C '$dest'" < "$tmp" \
    || { echo "  写入 $SKILLS_DEST 失败" >&2; rc=1; }
  rm -f "$tmp"
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "find '$dest' -maxdepth 1 -name '._*' -delete 2>/dev/null || true" || true

  if [ "$MIRROR" = "1" ]; then
    local removed
    removed=$("$SSH" "${SSHOPT[@]}" "$ALIAS" "KEEP='$keep' DEST='$dest' python3 -" <<'PY' 2>/dev/null
import os, shutil
base = os.path.expanduser(os.environ['DEST'])
keep = set(x for x in os.environ.get('KEEP', '').split(',') if x)
removed = []
if os.path.isdir(base):
    for n in sorted(os.listdir(base)):
        p = os.path.join(base, n)
        if n == '.system' or not os.path.isdir(p) or os.path.islink(p):
            continue
        if n not in keep:
            shutil.rmtree(p); removed.append(n)
print(','.join(removed))
PY
)
    [ -n "$removed" ] && say "已删除服务器多余技能: $(printf '%s' "$removed" | tr ',' ' ')"
  fi
  say "已同步 $n 个 skill → $SKILLS_DEST"
}

# ---------- 模型目录 ----------
sync_models() {
  echo "== 模型目录 =="
  local src="$MODELS_SRC" dest; dest=$(expand_remote "$MODELS_DEST")
  [ -f "$src" ] || { echo "  找不到来源文件: $src" >&2; rc=1; return; }
  "$SCP" -q "${SSHOPT[@]}" "$src" "$ALIAS:$dest" || { echo "  上传失败" >&2; rc=1; return; }
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "DEST='$dest' python3 -" <<'PY' || rc=1
import os, re, shutil, time
dest = os.environ['DEST']
cfg = os.path.expanduser('~/.codex/config.toml')
if os.path.exists(cfg):
    shutil.copy2(cfg, cfg + '.bak-sync-' + time.strftime('%Y%m%d-%H%M%S'))
    text = open(cfg).read()
    if re.search(r'(?m)^model_catalog_json\s*=', text):
        text = re.sub(r'(?m)^model_catalog_json\s*=.*$', 'model_catalog_json = "%s"' % dest, text)
    else:
        text = 'model_catalog_json = "%s"\n' % dest + text
    open(cfg, 'w').write(text)
PY
  local n; n=$(python3 -c "import json,sys;print(len(json.load(open('$src'))['models']))" 2>/dev/null || echo '?')
  say "已上传 $n 个模型 → $MODELS_DEST"
}

# ---------- AGENTS.md ----------
norm() { sed -e "s#/Users/[^/]*#__HOME__#g" -e "s#/home/[^/]*#__HOME__#g" "$1"; }

sync_agents_push() {
  echo "== AGENTS.md（本机 → 服务器）=="
  local src="$AGENTS_SRC" dest; dest=$(expand_remote "$AGENTS_DEST")
  [ -f "$src" ] || { echo "  找不到来源文件: $src" >&2; rc=1; return; }
  local tmp; tmp=$(mktemp)
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "cat '$dest' 2>/dev/null" > "$tmp" || true
  if [ -s "$tmp" ] && ! diff -q <(norm "$src") <(norm "$tmp") >/dev/null 2>&1; then
    if [ "$FORCE" != "1" ]; then
      echo "  存在路径之外的差异，未覆盖。差异摘要："
      diff -u <(norm "$tmp") <(norm "$src") | sed -n '1,20p' | sed 's/^/    /'
      echo "  确认要覆盖请加 --force（会先备份远端）"
      rc=1; rm -f "$tmp"; return
    fi
  fi
  sed -e "s#/Users/$USER#${remote_home}#g" "$src" > "$tmp.new"
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "cp '$dest' '$dest.bak-$(date +%Y%m%d-%H%M%S)' 2>/dev/null || true" || true
  "$SCP" -q "${SSHOPT[@]}" "$tmp.new" "$ALIAS:$dest" || { echo "  上传失败" >&2; rc=1; }
  say "已同步 AGENTS.md → $AGENTS_DEST"
  rm -f "$tmp" "$tmp.new"
}

sync_agents_pull() {
  echo "== AGENTS.md（服务器 → 本机）=="
  local src="$AGENTS_SRC" dest; dest=$(expand_remote "$AGENTS_DEST")
  local tmp; tmp=$(mktemp)
  "$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "cat '$dest' 2>/dev/null" > "$tmp" || true
  [ -s "$tmp" ] || { echo "  服务器上没有 AGENTS.md" >&2; rc=1; return; }
  sed -e "s#${remote_home}#/Users/$USER#g" "$tmp" > "$tmp.new"
  [ -f "$src" ] && cp "$src" "$src.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  mkdir -p "$(dirname "$src")"
  cp "$tmp.new" "$src"
  say "已拉取 AGENTS.md → $src"
  rm -f "$tmp" "$tmp.new"
}

# ---------- 验收 ----------
report() {
  echo "== 验收 =="
  local models hub skills base
  models=$("$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" 'curl -s -o /dev/null -m 6 -w "%{http_code}" --noproxy "*" http://127.0.0.1:3425/v1/models' 2>/dev/null)
  hub=$("$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" 'curl -s -o /dev/null -m 8 -w "%{http_code}" -X POST http://127.0.0.1:3425/mcp/magpie/hub -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"' 2>/dev/null)
  skills=$("$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "find $(expand_remote "$SKILLS_DEST") -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l" 2>/dev/null)
  base=$("$SSH" "${SSHOPT[@]}" -o ClearAllForwardings=yes "$ALIAS" "grep -m1 'base_url' ~/.codex/config.toml 2>/dev/null" 2>/dev/null)
  say "models:  ${models:-?}"
  say "hub:     ${hub:-?}"
  say "skills:  ${skills:-?}"
  say "base_url: ${base:-?}"
}

[ "$DO_MODELS" = 1 ] && sync_models
[ "$DO_SKILLS" = 1 ] && sync_skills
[ "$DO_AGENTS" = 1 ] && sync_agents_push
[ "$DO_PULL" = 1 ] && sync_agents_pull
report
[ "$rc" = 0 ] && echo "完成" || echo "部分失败"
exit "$rc"
