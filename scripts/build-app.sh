#!/bin/bash
# Builds dist/AgentBoard.app (release, ad-hoc signed). Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="1.0.0"
APP="dist/AgentBoard.app"

swift build -c release 2>&1 | grep -v "xcrun: error" || true
BIN=".build/release/AgentBoard"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentBoard"

if [ ! -f dist/AppIcon.icns ]; then
  rm -rf dist/AppIcon.iconset
  swift scripts/make-icon.swift dist/AppIcon.iconset 2>&1 | grep -v "xcrun: error" || true
  iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns
fi
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentBoard</string>
  <key>CFBundleDisplayName</key><string>AgentBoard</string>
  <key>CFBundleIdentifier</key><string>app.agentboard.mac</string>
  <key>CFBundleExecutable</key><string>AgentBoard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>AgentBoard</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "signed (ad-hoc)"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app "AgentBoard"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/AgentBoard.app
  cp -R "$APP" /Applications/
  echo "installed /Applications/AgentBoard.app"
fi
