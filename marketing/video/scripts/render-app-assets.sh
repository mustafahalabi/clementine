#!/bin/bash
# Renders the real Clementine UI used in the film into public/app/: every wheel at every hover index, and the
# editor windows. Uses the debug build's off-screen renderers with tools/render-scale.patch applied temporarily
# (adds CLEMENTINE_RENDER_SCALE for sharp 3x output and CLEMENTINE_RENDER_CLEAR for a transparent wheel backdrop).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; repo="$(cd "$here/../.." && pwd)"
fx="$here/fixtures"; out="$here/public/app"
cd "$repo"
applied=0
if git apply --check "$here/tools/render-scale.patch" 2>/dev/null; then git apply "$here/tools/render-scale.patch"; applied=1; fi
# Render in US English whatever the Mac's region is: a temporary AppleLocale for the unbundled binary's domain.
had_locale=0; defaults read Clementine AppleLocale >/dev/null 2>&1 && had_locale=1
[ $had_locale = 0 ] && defaults write Clementine AppleLocale en_US
cleanup() {
  [ $had_locale = 0 ] && defaults delete Clementine AppleLocale 2>/dev/null
  [ $applied = 1 ] && git -C "$repo" apply -R "$here/tools/render-scale.patch"
  return 0
}
trap cleanup EXIT
swift build 2>&1 | tail -1
BIN="$repo/.build/debug/Clementine"
export CLEMENTINE_DEFAULTS_SUITE=app.clementine.launch-video CLEMENTINE_SUPPORT_DIR="$(mktemp -d)"
mkdir -p "$out/wheels" "$out/ui"
jobs=()
wheel() { # name, count, flags…, file…
  local name=$1 count=$2; shift 2
  jobs+=("$name|none|$*")
  for ((i = 0; i < count; i++)); do jobs+=("$name|$i|$*"); done
}
wheel photo-convert 9 "$fx/Sunset.heic"
wheel photo-tools 12 --tools "$fx/Sunset.heic"
wheel video-convert 9 "$fx/Trip.mov"
wheel video-tools 11 --tools "$fx/Trip.mov"
wheel audio-convert 6 "$fx/Interview.m4a"
wheel audio-tools 11 --tools "$fx/Interview.m4a"
wheel doc-convert 3 "$fx/Notes.docx"
wheel pdf-convert 4 "$fx/Report.pdf"
wheel pdf-tools 6 --tools "$fx/Report.pdf"
wheel pdf2-tools 7 --tools "$fx/Report.pdf" "$fx/Appendix.pdf"
wheel zip-convert 3 "$fx/Photos.zip"
render_one() {
  IFS='|' read -r name hover args <<<"$1"
  mkdir -p "$out/wheels/$name"
  local hv=(); [ "$hover" != none ] && hv=(--hover "$hover")
  # shellcheck disable=SC2086
  CLEMENTINE_RENDER_SCALE=3 CLEMENTINE_RENDER_CLEAR=1 "$BIN" --render-wheel "$out/wheels/$name/$hover.png" "${hv[@]}" $args >/dev/null
}
export -f render_one; export BIN out
printf '%s\n' "${jobs[@]}" | xargs -P 6 -I{} bash -c 'render_one "$@"' _ {}
echo "wheels: $(find "$out/wheels" -name '*.png' | wc -l | tr -d ' ')"
CLEMENTINE_RENDER_SCALE=2 "$BIN" --render-ui "$out/ui" "$fx/photo.png" "$fx/Interview.m4a" "$fx/Trip.mov" >/dev/null
echo "ui: $(ls "$out/ui" | wc -l | tr -d ' ')"
