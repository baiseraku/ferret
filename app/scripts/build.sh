#!/bin/bash
# 编译 Codex 隧道.app（Swift + AppKit，无需 Xcode 工程）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ferret.app"
mkdir -p "$ROOT/build" "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -O "$ROOT/src/main.swift" -o "$APP/Contents/MacOS/Ferret" -framework Cocoa

# 图标：没有 assets/AppIcon.icns 时先生成
mkdir -p "$ROOT/assets"
if [ ! -f "$ROOT/assets/AppIcon.icns" ]; then
  /usr/bin/swiftc -O "$ROOT/scripts/makeicon.swift" -o "$ROOT/build/makeicon"
  "$ROOT/build/makeicon" "$ROOT/build/AppIcon.iconset"
  /usr/bin/iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/assets/AppIcon.icns"
fi
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ferret</string>
  <key>CFBundleDisplayName</key><string>Ferret</string>
  <key>CFBundleIdentifier</key><string>local.ferret.app</string>
  <key>CFBundleExecutable</key><string>Ferret</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - "$APP" 2>&1 | tail -1
echo "已构建: $APP"
