#!/bin/bash
# 编译 Codex 隧道.app（Swift + AppKit，无需 Xcode 工程）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/远程隧道.app"
mkdir -p "$ROOT/build" "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -O "$ROOT/src/main.swift" -o "$APP/Contents/MacOS/RemoteTunnel" -framework Cocoa
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>远程隧道</string>
  <key>CFBundleDisplayName</key><string>远程隧道</string>
  <key>CFBundleIdentifier</key><string>local.remotetunnel.app</string>
  <key>CFBundleExecutable</key><string>RemoteTunnel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - "$APP" 2>&1 | tail -1
echo "已构建: $APP"
