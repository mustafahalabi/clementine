#!/usr/bin/env bash
# Builds build/Clementine.app from the Swift package.
# Usage: scripts/bundle.sh [debug|release]
#   UNIVERSAL=1   build an arm64 + x86_64 binary (pair it with `scripts/fetch-tools.sh universal`)
#   NO_SIGN=1     skip the ad-hoc signature (scripts/release.sh signs the bundle itself)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BUILD_FLAGS=(-c "$CONFIG")
[[ -n "${UNIVERSAL:-}" ]] && BUILD_FLAGS+=(--arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Clementine"

APP="build/Clementine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Clementine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Sparkle (auto-updates). The binary finds it through its @executable_path/../Frameworks rpath.
# ditto keeps the framework's symlinks and its nested XPC services intact.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "error: Sparkle.framework not found in $BIN_DIR" >&2
  exit 1
fi

# Anything in vendor/bin (static ffmpeg, ffprobe, cwebp, img2webp; see scripts/fetch-tools.sh) ships inside the
# app and takes priority over Homebrew.
if compgen -G "vendor/bin/*" > /dev/null; then
  cp vendor/bin/* "$APP/Contents/Resources/bin/"
  chmod +x "$APP/Contents/Resources/bin/"*
fi

# Ad-hoc signature for local use. For distribution, use scripts/release.sh (Developer ID + notarization).
if [[ -z "${NO_SIGN:-}" ]]; then
  codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"
fi
echo "Built $APP"
