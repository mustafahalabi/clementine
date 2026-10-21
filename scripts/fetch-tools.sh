#!/usr/bin/env bash
# Downloads the command-line tools Clementine ships inside the app into vendor/bin (gitignored):
#   ffmpeg, ffprobe  static builds by Martin Riedl (https://ffmpeg.martin-riedl.de), signed and notarized
#                    with Developer ID KU3N25YGLU. GPLv3 builds (x264, x265, lame, opus, vpx, ...).
#   cwebp, img2webp  Google's official libwebp release binaries (BSD-3-Clause).
#
# Usage: scripts/fetch-tools.sh [arm64|x86_64|universal]     (default: this Mac's architecture)
#   FFMPEG_CHANNEL=latest  use the newest release instead of the pinned one (checks the published sha256
#                          and the Developer ID signature, but not the pinned hashes below)
#   FORCE=1                download again even if vendor/bin is already up to date
#
# Every download is verified before anything lands in vendor/bin:
#   - ffmpeg/ffprobe: pinned SHA-256 (also cross-checked against the .sha256 published next to the zip) and
#     a valid code signature from Martin Riedl's Developer ID team.
#   - libwebp: pinned SHA-256, and the MD5 Google Cloud Storage reports for the object.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64|universal) ;;
  amd64|x86-64) ARCH=x86_64 ;;
  *) echo "usage: $0 [arm64|x86_64|universal]" >&2; exit 2 ;;
esac

# ---- pinned versions -------------------------------------------------------------------------------------
FFMPEG_VERSION="9.0.2"
FFMPEG_TEAM_ID="KU3N25YGLU"   # Developer ID Application: Martin Riedl
FFMPEG_BASE="https://ffmpeg.martin-riedl.de"
ffmpeg_build() {               # arch -> build directory on the server
  case "$1" in arm64) echo "arm64/1789931890_9.0.2" ;; x86_64) echo "amd64/1789931006_9.0.2" ;; esac
}
ffmpeg_sha() {                 # arch tool -> sha256 of the zip
  case "$1-$2" in
    arm64-ffmpeg)   echo c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924 ;;
    arm64-ffprobe)  echo fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6 ;;
    x86_64-ffmpeg)  echo 7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4 ;;
    x86_64-ffprobe) echo 2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd ;;
  esac
}

WEBP_VERSION="1.6.0"
WEBP_BASE="https://storage.googleapis.com/downloads.webmproject.org/releases/webp"
webp_name() {                  # arch -> archive base name
  case "$1" in arm64) echo "libwebp-$WEBP_VERSION-mac-arm64" ;; x86_64) echo "libwebp-$WEBP_VERSION-mac-x86-64" ;; esac
}
webp_sha() {
  case "$1" in
    arm64)  echo bc6bf84cc70f3f8574fba797d1e4a7dea4feebe9fa4be919f202413ea2b3b8f2 ;;
    x86_64) echo f112dd83b420ab2a4b27d46610d9827ddf4200216023281de378647ecca31c2a ;;
  esac
}
WEBP_TOOLS=(cwebp img2webp)
# -----------------------------------------------------------------------------------------------------------

DEST="vendor/bin"
MANIFEST="vendor/tools.txt"
STAMP="ffmpeg-$FFMPEG_VERSION-${FFMPEG_CHANNEL:-pinned} libwebp-$WEBP_VERSION $ARCH"
if [[ -z "${FORCE:-}" && -f "$MANIFEST" && "$(head -1 "$MANIFEST")" == "$STAMP" ]] \
   && [[ -x "$DEST/ffmpeg" && -x "$DEST/ffprobe" && -x "$DEST/cwebp" && -x "$DEST/img2webp" ]]; then
  echo "vendor/bin is up to date ($STAMP). FORCE=1 to download again."
  exit 0
fi

WORK="$(mktemp -d /tmp/clementine-tools.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "error: $*" >&2; exit 1; }
# Stalled transfers are abandoned and retried rather than left hanging.
fetch() { curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 20 --speed-limit 50000 --speed-time 20 -o "$2" "$1"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ "$ARCH" == universal ]]; then ARCHES=(arm64 x86_64); else ARCHES=("$ARCH"); fi

# ---- ffmpeg / ffprobe ----
for arch in "${ARCHES[@]}"; do
  if [[ "${FFMPEG_CHANNEL:-}" == latest ]]; then
    server_arch=$([[ $arch == x86_64 ]] && echo amd64 || echo arm64)
    resolved="$(curl -fsS -o /dev/null -w '%{redirect_url}' "$FFMPEG_BASE/redirect/latest/macos/$server_arch/release/ffmpeg.zip")"
    [[ -n "$resolved" ]] || fail "couldn't resolve the latest ffmpeg release"
    build_url="${resolved%/ffmpeg.zip}"
  else
    build_url="$FFMPEG_BASE/download/macos/$(ffmpeg_build "$arch")"
  fi
  for tool in ffmpeg ffprobe; do
    echo "Downloading $tool ($arch) from $build_url"
    zip="$WORK/$arch-$tool.zip"
    fetch "$build_url/$tool.zip" "$zip"
    published="$(curl -fsSL --retry 3 "$build_url/$tool.zip.sha256" | awk '{print $1}')"
    actual="$(sha256 "$zip")"
    [[ "$actual" == "$published" ]] || fail "$tool ($arch): sha256 $actual doesn't match the published $published"
    if [[ "${FFMPEG_CHANNEL:-}" != latest ]]; then
      [[ "$actual" == "$(ffmpeg_sha "$arch" "$tool")" ]] || fail "$tool ($arch): sha256 $actual doesn't match the pinned hash"
    fi
    mkdir -p "$WORK/$arch"
    unzip -q -o "$zip" "$tool" -d "$WORK/$arch"
    codesign --verify --strict "$WORK/$arch/$tool" || fail "$tool ($arch): code signature is invalid"
    team="$(codesign -dv "$WORK/$arch/$tool" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$team" == "$FFMPEG_TEAM_ID" ]] || fail "$tool ($arch): signed by team '$team', expected $FFMPEG_TEAM_ID"
    echo "  ok: sha256 $actual, signed by team $team"
  done
done

# ---- libwebp ----
for arch in "${ARCHES[@]}"; do
  name="$(webp_name "$arch")"
  echo "Downloading $name"
  archive="$WORK/$name.tar.gz"
  fetch "$WEBP_BASE/$name.tar.gz" "$archive"
  actual="$(sha256 "$archive")"
  [[ "$actual" == "$(webp_sha "$arch")" ]] || fail "$name: sha256 $actual doesn't match the pinned hash"
  # Transport check against the MD5 Cloud Storage keeps for the object (base64).
  gcs_md5="$(curl -fsSL "https://storage.googleapis.com/storage/v1/b/downloads.webmproject.org/o/releases%2Fwebp%2F$name.tar.gz?fields=md5Hash" \
             | sed -n 's/.*"md5Hash": *"\([^"]*\)".*/\1/p' || true)"
  if [[ -n "$gcs_md5" ]]; then
    [[ "$(openssl dgst -md5 -binary "$archive" | base64)" == "$gcs_md5" ]] || fail "$name: MD5 doesn't match Cloud Storage"
  fi
  tar -xzf "$archive" -C "$WORK"
  mkdir -p "$WORK/$arch"
  for tool in "${WEBP_TOOLS[@]}"; do cp "$WORK/$name/bin/$tool" "$WORK/$arch/$tool"; done
  echo "  ok: sha256 $actual"
done

# ---- install ----
mkdir -p "$DEST"
for tool in ffmpeg ffprobe "${WEBP_TOOLS[@]}"; do
  rm -f "$DEST/$tool"
  if [[ ${#ARCHES[@]} -gt 1 ]]; then
    lipo -create "$WORK/arm64/$tool" "$WORK/x86_64/$tool" -output "$DEST/$tool"
  else
    cp "$WORK/${ARCHES[0]}/$tool" "$DEST/$tool"
  fi
  chmod 755 "$DEST/$tool"
  xattr -c "$DEST/$tool" 2>/dev/null || true
done

# Smoke check: every tool runs on this Mac.
"$DEST/ffmpeg" -hide_banner -version | head -1
"$DEST/ffprobe" -hide_banner -version | head -1
echo "cwebp $("$DEST/cwebp" -version | head -1)"
"$DEST/img2webp" -version >/dev/null 2>&1 || "$DEST/img2webp" -h >/dev/null 2>&1 || fail "img2webp doesn't run"

{
  echo "$STAMP"
  for tool in ffmpeg ffprobe "${WEBP_TOOLS[@]}"; do
    echo "$tool  $(lipo -archs "$DEST/$tool")  $(sha256 "$DEST/$tool")"
  done
} > "$MANIFEST"
echo "Installed into $DEST ($ARCH). See THIRD_PARTY_NOTICES.md for licensing."
