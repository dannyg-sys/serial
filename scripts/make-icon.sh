#!/usr/bin/env bash
# Render the app icon master and pack it into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
MASTER="$WORK/icon_1024.png"
ISET="$WORK/AppIcon.iconset"
mkdir -p "$ISET" Resources

echo "Rendering master…"
swift scripts/make_icon.swift "$MASTER"

echo "Building iconset…"
gen() { sips -z "$1" "$1" "$MASTER" --out "$ISET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$MASTER" "$ISET/icon_512x512@2x.png"

iconutil -c icns "$ISET" -o Resources/AppIcon.icns
cp "$MASTER" Resources/AppIcon.png

# Bundle a copy for runtime Dock icon (loaded via Bundle.module).
mkdir -p Sources/SerialTerminal/Resources
cp "$MASTER" Sources/SerialTerminal/Resources/AppIcon.png

echo "Done → Resources/AppIcon.icns  (+ Resources/AppIcon.png preview)"
rm -rf "$WORK"
