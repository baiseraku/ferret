#!/bin/bash
# 安装到 /Applications（先备份旧版本）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Ferret.app"
DST="/Applications/Ferret.app"
STAMP="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$ROOT/.cache/backup"
[ -d "$SRC" ] || { echo "缺少 $SRC，先运行 scripts/build.sh" >&2; exit 1; }
if [ -d "$DST" ]; then ditto "$DST" "$ROOT/.cache/backup/Ferret.app-$STAMP"; fi
ditto "$SRC" "$DST"
/usr/bin/codesign --force --deep --sign - "$DST" >/dev/null 2>&1
/usr/bin/codesign --verify --deep --strict "$DST" && echo "安装完成: $DST"
