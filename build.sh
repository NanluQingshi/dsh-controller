#!/bin/zsh
# Build, bundle, install and relaunch DSH Controller.
# Usage: ./build.sh [APP_PATH]   (default /Applications/DSH Controller.app)
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-/Applications/DSH Controller.app}"

echo "▸ swiftc"
swiftc -O -o DSHController dsh-controller.swift

echo "▸ bundle → $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp DSHController "$APP/Contents/MacOS/DSHController"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/menubar-whale.png "$APP/Contents/Resources/menubar-whale.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleName</key><string>DSH Controller</string>
	<key>CFBundleDisplayName</key><string>DSH Controller</string>
	<key>CFBundleIdentifier</key><string>local.dsh.controller</string>
	<key>CFBundleExecutable</key><string>DSHController</string>
	<key>CFBundleShortVersionString</key><string>1.1.0</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ ad-hoc codesign"
codesign --force -s - "$APP"

echo "▸ relaunch"
osascript -e 'tell application "DSH Controller" to quit' >/dev/null 2>&1 || true
sleep 0.5
open "$APP"

echo "✓ done — menu bar item: whale ●"
