#!/usr/bin/env bash
# Build SerialTerminal.app (a double-clickable macOS bundle) from the SPM binary.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="SerialTerminal.app"
BIN_NAME="SerialTerminal"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
# MCP shim for Claude Desktop (stdio → the app's loopback API).
cp "$(dirname "$BIN_PATH")/SerialMCP" "$APP/Contents/MacOS/serial-mcp"

# App icon (build it if missing).
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "Icon not found — rendering…"
  ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Serial Terminal</string>
  <key>CFBundleDisplayName</key>     <string>Serial Terminal</string>
  <key>CFBundleIdentifier</key>      <string>com.local.serialterminal</string>
  <key>CFBundleExecutable</key>      <string>$BIN_NAME</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSBluetoothAlwaysUsageDescription</key> <string>Serial Terminal uses Bluetooth to send keystrokes to the HID keyboard bridge dongle.</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper/network permission prompts behave predictably.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "note: ad-hoc codesign skipped (codesign unavailable)"

echo "Done → $(pwd)/$APP"
echo "Launch:  open \"$APP\"    (or move it to /Applications)"
