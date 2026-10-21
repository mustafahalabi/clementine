#!/usr/bin/env bash
# Builds build/Clementine.app from the Swift package.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Clementine"

APP="build/Clementine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/Clementine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Anything in vendor/bin (static ffmpeg, ffprobe, cwebp) ships inside the app and takes priority over Homebrew.
if compgen -G "vendor/bin/*" > /dev/null; then
  cp vendor/bin/* "$APP/Contents/Resources/bin/"
  chmod +x "$APP/Contents/Resources/bin/"*
fi

# Ad-hoc signature for local use. For distribution, sign with a Developer ID and notarize.
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
