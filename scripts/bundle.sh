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

# Shortcuts actions (App Intents) need metadata that Xcode generates at build time and SwiftPM doesn't. Ask the
# compiler for the same "const values" Xcode does (the protocol list is Xcode's SWIFT_EMIT_CONST_VALUE_PROTOCOLS
# default); appintentsmetadataprocessor turns them into Metadata.appintents below.
mkdir -p .build
PROTOCOLS="$PWD/.build/appintents-protocols.json"
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' > "$PROTOCOLS"
BUILD_FLAGS+=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS")

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

# App Intents metadata (see the build flags above). Without it Shortcuts doesn't see Clementine's actions.
LISTS="$(mktemp -d)"
trap 'rm -rf "$LISTS"' EXIT
find "$PWD/Sources/Clementine" -name '*.swift' | sort > "$LISTS/sources"
if [[ -n "${UNIVERSAL:-}" ]]; then
  # xcbuild's layout; the arm64 values describe the same Swift types as the x86_64 ones.
  find "$PWD/.build/apple" -name '*.swiftconstvalues' -path '*/Clementine.build/*' -path '*arm64*' > "$LISTS/consts"
else
  # Whole-module (release) builds write Clementine.swiftconstvalues; debug builds one file per source. Skip
  # leftovers from deleted sources.
  for file in "$BIN_DIR/Clementine.build/"*.swiftconstvalues; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file" .swiftconstvalues)"
    if [[ "$base" == Clementine ]] || grep -q "/$base\$" "$LISTS/sources"; then echo "$file"; fi
  done > "$LISTS/consts"
fi
[[ -s "$LISTS/consts" ]] || { echo "error: the compiler wrote no const values for App Intents" >&2; exit 1; }
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)" || {
  echo "error: appintentsmetadataprocessor not found; App Intents metadata needs Xcode (xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
}
ARCH="$(uname -m)"; [[ -n "${UNIVERSAL:-}" ]] && ARCH=arm64
"$PROCESSOR" --output "$APP/Contents/Resources" \
  --toolchain-dir "$(xcrun --find swiftc | sed 's|/usr/bin/swiftc$||')" \
  --module-name Clementine \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS --deployment-target 14.0 --target-triple "$ARCH-apple-macos14.0" \
  --binary-file "$APP/Contents/MacOS/Clementine" \
  --source-file-list "$LISTS/sources" --swift-const-vals-list "$LISTS/consts" \
  --compile-time-extraction --deployment-aware-processing --validate-assistant-intents \
  --no-app-shortcuts-localization 2>&1 | grep -Ev '^[0-9-]+ [0-9:.]+ appintentsmetadataprocessor\[[0-9:]+\] (Starting|Writing|Metadata root|Extracting|Using)' || true
ACTIONS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
grep -q '"ConvertWithClementineIntent"' "$ACTIONS" 2>/dev/null || {
  echo "error: App Intents metadata is missing from the app ($ACTIONS)" >&2
  exit 1
}

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
