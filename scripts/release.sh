#!/usr/bin/env bash
# Builds a distributable Clementine: signed app, notarized and stapled, as a versioned .zip and .dmg in dist/.
#
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=clementine-notary \
#   scripts/release.sh
#
# Environment:
#   CODESIGN_IDENTITY  Developer ID Application identity. Unset: ad-hoc signature, artifacts marked -unsigned.
#   NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials). Unset: no notarization.
#   SPARKLE_KEY_FILE   EdDSA private key file for Sparkle's sign_update (optional; see RELEASING.md).
#   UNIVERSAL=1        arm64 + x86_64 app and tools (bigger; default is this Mac's architecture).
#   SKIP_TOOLS=1       don't run scripts/fetch-tools.sh (ship whatever is in vendor/bin, possibly nothing).
#   DMG_LAYOUT=0       skip create-dmg's Finder window layout (plain DMG with an Applications link).
#
# The version comes from CFBundleShortVersionString in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Clementine.app"
DIST="dist"
ENTITLEMENTS="Resources/Clementine.entitlements"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
IDENTITY="${CODESIGN_IDENTITY:-}"

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

if [[ -n "$IDENTITY" ]]; then
  SIGNED=1
  SUFFIX=""
  TIMESTAMP=(--timestamp)
  RUNTIME=(--options runtime)
else
  SIGNED=""
  SUFFIX="-unsigned"
  TIMESTAMP=(--timestamp=none)
  # Hardened runtime's library validation rejects ad-hoc frameworks (no Team ID), so the app couldn't load
  # Sparkle. Ad-hoc builds therefore skip the runtime; Developer ID builds always use it.
  RUNTIME=()
  IDENTITY="-"
  warn "CODESIGN_IDENTITY is not set: building UNSIGNED (ad-hoc) artifacts."
  warn "They run on this Mac, but Gatekeeper will block them on others. Don't publish them."
fi
if [[ -n "${NOTARY_PROFILE:-}" && -z "$SIGNED" ]]; then
  warn "NOTARY_PROFILE is set but there's no CODESIGN_IDENTITY; skipping notarization."
fi
NOTARIZE=""
[[ -n "$SIGNED" && -n "${NOTARY_PROFILE:-}" ]] && NOTARIZE=1

step "Clementine $VERSION ($BUILD_NUMBER)"

if [[ -z "${SKIP_TOOLS:-}" ]]; then
  step "Fetching bundled tools"
  scripts/fetch-tools.sh "$([[ -n "${UNIVERSAL:-}" ]] && echo universal || uname -m)"
fi

step "Building the app"
NO_SIGN=1 scripts/bundle.sh release

# ---- signing, innermost first (no --deep: every nested piece gets the right options) ----
sign() { codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "${TIMESTAMP[@]}" "$@"; }

step "Signing ($([[ -n "$SIGNED" ]] && echo "$IDENTITY" || echo "ad-hoc"))"
for tool in "$APP"/Contents/Resources/bin/*; do
  [[ -f "$tool" ]] || continue
  sign --identifier "app.clementine.Clementine.$(basename "$tool")" "$tool"
done
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  # Sparkle's documented order for re-signing an embedded copy.
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi
sign --entitlements "$ENTITLEMENTS" "$APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Runtime|CodeDirectory)' || true

notarize() { # file
  step "Notarizing $(basename "$1") (this can take a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [[ -n "$NOTARIZE" ]]; then
  SUBMISSION="$(mktemp -d /tmp/clementine-notary.XXXXXX)/Clementine.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION"
  notarize "$SUBMISSION"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# ---- artifacts ----
mkdir -p "$DIST"
ZIP="$DIST/Clementine-$VERSION$SUFFIX.zip"
DMG="$DIST/Clementine-$VERSION$SUFFIX.dmg"
rm -f "$ZIP" "$DMG"

step "Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

step "Packaging $DMG"
STAGE="$(mktemp -d /tmp/clementine-dmg.XXXXXX)"
trap 'rm -rf "$STAGE" "$STAGE.create-dmg.log"' EXIT
ditto "$APP" "$STAGE/Clementine.app"
cp THIRD_PARTY_NOTICES.md "$STAGE/Third-Party Notices.md"
# With create-dmg (brew install create-dmg) the window opens laid out: app on the left, Applications on the right,
# the notices below. Its Finder AppleScript needs a GUI session and Automation permission for Finder; if that
# fails, or DMG_LAYOUT=0, the DMG is built plainly (same contents, default window).
DMG_DONE=""
if [[ "${DMG_LAYOUT:-1}" != 0 ]] && command -v create-dmg >/dev/null; then
  if create-dmg --volname "Clementine $VERSION" --filesystem HFS+ --format UDZO --hdiutil-quiet \
       --window-pos 200 140 --window-size 560 400 --icon-size 112 --text-size 13 \
       --icon "Clementine.app" 150 160 --hide-extension "Clementine.app" --app-drop-link 410 160 \
       --icon "Third-Party Notices.md" 280 310 \
       "$DMG" "$STAGE" >"$STAGE.create-dmg.log" 2>&1; then
    DMG_DONE=1
  else
    tail -20 "$STAGE.create-dmg.log" >&2
    warn "create-dmg failed (output above); building the DMG without a window layout."
    rm -f "$DMG"
  fi
fi
if [[ -z "$DMG_DONE" ]]; then
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Clementine $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
fi
if [[ -n "$SIGNED" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [[ -n "$NOTARIZE" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi
hdiutil verify -quiet "$DMG"

# ---- Sparkle update signature ----
SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
if [[ -n "${SPARKLE_KEY_FILE:-}" && -n "$SIGN_UPDATE" ]]; then
  step "Sparkle signature for $ZIP"
  "$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP" | tee "$ZIP.sparkle.txt"
fi

SHA="$DIST/Clementine-$VERSION$SUFFIX.sha256"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$(basename "$SHA")")

step "Done"
ls -lh "$ZIP" "$DMG" "$SHA"
if [[ -z "$SIGNED" ]]; then
  warn "UNSIGNED build (ad-hoc signature, not notarized). For local testing only."
elif [[ -z "$NOTARIZE" ]]; then
  warn "Signed with Developer ID but NOT notarized (set NOTARY_PROFILE). Gatekeeper will warn on other Macs."
else
  echo "Signed, notarized and stapled. Next: update the appcast (see RELEASING.md)."
fi
