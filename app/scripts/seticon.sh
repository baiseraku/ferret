#!/bin/bash
# 仅重新生成并替换图标（不重新编译 App）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/assets" "$ROOT/build"
/usr/bin/swiftc -O "$ROOT/scripts/makeicon.swift" -o "$ROOT/build/makeicon"
rm -rf "$ROOT/build/AppIcon.iconset"
"$ROOT/build/makeicon" "$ROOT/build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/assets/AppIcon.icns"
APP="/Applications/远程隧道.app"
if [ -d "$APP" ]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
  echo "已更新图标: $APP（Dock 可能需退出重开或注销后刷新）"
fi
echo "icns: $ROOT/assets/AppIcon.icns"
