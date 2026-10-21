#!/usr/bin/env bash
# Productivity features, headlessly: wheel order from recorded usage, hidden slices, history and undo,
# and parallel batches. Runs against a scratch defaults suite and support folder (debug-build overrides),
# so real settings and history are never touched.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
WORK="$(mktemp -d /tmp/clementine-productivity.XXXXXX)"
F="$WORK/fixtures"
mkdir -p "$F"
export CLEMENTINE_DEFAULTS_SUITE="app.clementine.tests.$$"
export CLEMENTINE_SUPPORT_DIR="$WORK/support"
cleanup() {
  defaults delete "$CLEMENTINE_DEFAULTS_SUITE" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$CLEMENTINE_DEFAULTS_SUITE.plist"
}
trap cleanup EXIT
q() { ffmpeg -loglevel error -y "$@"; }

echo "Fixtures in $F"
q -f lavfi -i testsrc=size=640x480 -frames:v 1 "$F/photo.png"
q -f lavfi -i "sine=r=44100" -t 2 "$F/tone.wav"
mkdir -p "$F/batch" "$F/media" "$F/dups" "$F/subs"
for i in $(seq -w 1 16); do q -f lavfi -i "testsrc=size=900x600,hue=h=$((10#$i * 20))" -frames:v 1 "$F/batch/img$i.png"; done
for i in 1 2 3; do q -f lavfi -i "sine=f=$((200 * i)):r=44100" -t 2 "$F/media/tone$i.wav"; done
q -f lavfi -i testsrc=size=200x200 -frames:v 1 "$F/dups/dup.png"
q -f lavfi -i testsrc=size=200x200 -frames:v 1 "$F/dups/dup.bmp"
q -f lavfi -i testsrc=size=200x200 -frames:v 1 "$F/dups/dup.tiff"
printf '1\n00:00:01,000 --> 00:00:02,000\nHi\n' > "$F/subs/subs.srt"
echo "not an image" > "$F/batch/img08b.png"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }
# check <name> <assertion…>: the assertion is eval'd.
check() { local name="$1"; shift; if eval "$*"; then ok "$name"; else bad "$name" "assertion failed: $*"; fi; }

# wheel <convert|tools> <file…>: the visible slice ids, in wheel order, one per line.
wheel() {
  local section; [[ "$1" == convert ]] && section="Convert" || section="Tools"; shift
  "$BIN" --list "$@" | awk -v s="$section" '/^[A-Z]/{on=($1==s); next} on && !/\(hidden\)$/{print $1}'
}
hidden_listed() { "$BIN" --list "$@" | awk '/\(hidden\)$/{print $1}'; }
record() { "$BIN" --run "$@" --record >/dev/null 2>&1; }
joined() { tr '\n' ' ' | sed 's/ $//'; }

echo "Recents"
BASE_TOOLS="$(wheel tools "$F/photo.png" | joined)"
BASE_CONVERT="$(wheel convert "$F/photo.png" | joined)"
BASE_AUDIO="$(wheel tools "$F/tone.wav" | joined)"
check "fresh wheel is catalog order (compress first)" '[[ "${BASE_TOOLS%% *}" == tool.compress ]]'
record tool.image.qr "$F/photo.png"
record tool.image.qr "$F/photo.png"
record tool.image.crop "$F/photo.png"
EXPECTED="tool.image.qr tool.image.crop $(echo "$BASE_TOOLS" | tr ' ' '\n' | grep -vx 'tool.image.qr\|tool.image.crop' | joined)"
check "most used first, ties keep catalog order" '[[ "$(wheel tools "$F/photo.png" | joined)" == "$EXPECTED" ]]'
check "usage is per kind (audio tools unchanged)" '[[ "$(wheel tools "$F/tone.wav" | joined)" == "$BASE_AUDIO" ]]'
check "usage is per mode (image convert unchanged)" '[[ "$(wheel convert "$F/photo.png" | joined)" == "$BASE_CONVERT" ]]'
LAST="$(echo "$BASE_TOOLS" | tr ' ' '\n' | tail -1)"
for _ in 1 2 3; do record "$LAST" "$F/photo.png"; done
check "last catalog slice used most moves to the front" '[[ "$(wheel tools "$F/photo.png" | head -1)" == "$LAST" ]]'
check "never more than 12 slices" '[[ $(wheel tools "$F/batch/img01.png" "$F/batch/img02.png" | wc -l) -le 12 ]]'
record convert.image.webp "$F/photo.png"
check "convert usage reorders the convert wheel" '[[ "$(wheel convert "$F/photo.png" | head -1)" == convert.image.webp ]]'
defaults write "$CLEMENTINE_DEFAULTS_SUITE" orderByUsage -bool false
check "ordering by usage can be switched off" '[[ "$(wheel tools "$F/photo.png" | joined)" == "$BASE_TOOLS" ]]'
defaults delete "$CLEMENTINE_DEFAULTS_SUITE" orderByUsage

echo "Hidden slices"
defaults write "$CLEMENTINE_DEFAULTS_SUITE" hiddenActions -array tool.image.qr convert.image.heic
check "hidden tool leaves the wheel" '! wheel tools "$F/photo.png" | grep -qx tool.image.qr'
check "hidden convert leaves the wheel" '! wheel convert "$F/photo.png" | grep -qx convert.image.heic'
check "--list marks hidden slices" '[[ "$(hidden_listed "$F/photo.png" | sort | joined)" == "convert.image.heic tool.image.qr" ]]'
check "hidden action still runs from the CLI" '"$BIN" --run tool.image.qr "$F/photo.png" | grep -q "No QR"'
check "other slices unaffected" '[[ $(wheel tools "$F/photo.png" | wc -l) -eq $(( $(echo "$BASE_TOOLS" | wc -w) - 1 )) ]]'
defaults delete "$CLEMENTINE_DEFAULTS_SUITE" hiddenActions

echo "History"
"$BIN" --clear-history
OUT="$("$BIN" --run convert.image.jpeg --record "$F/photo.png")"
check "history.json written to the support folder" '[[ -f "$CLEMENTINE_SUPPORT_DIR/history.json" ]]'
LINE="$("$BIN" --history | head -1)"
field() { cut -f"$1" <<<"$LINE"; }
check "entry has action, title, inputs, outputs" '[[ "$(field 2)" == convert.image.jpeg && "$(field 3)" == "Convert to JPG" && "$(field 4)" == "$F/photo.png" && "$(field 5)" == "$OUT" ]]'
check "history.json is valid JSON with symbol and date" 'python3 -c "import json,sys; e=json.load(open(sys.argv[1]))[0]; sys.exit(0 if e[\"symbol\"] and e[\"date\"] and e[\"outputs\"] else 1)" "$CLEMENTINE_SUPPORT_DIR/history.json"'
check "text-only results aren't recorded" '"$BIN" --run tool.metadata --record "$F/photo.png" >/dev/null && [[ $("$BIN" --history | wc -l) -eq 1 ]]'
for i in $(seq 1 51); do record convert.subtitle.vtt "$F/subs/subs.srt"; done
NEWEST="$("$BIN" --run convert.subtitle.vtt --record "$F/subs/subs.srt")"
check "history is capped at 50" '[[ $("$BIN" --history | wc -l) -eq 50 ]]'
check "newest first" '[[ "$("$BIN" --history | head -1 | cut -f5)" == "$NEWEST" ]]'
check "dates never increase down the list" '"$BIN" --history | cut -f1 | sort -rc'
TRASHED="$("$BIN" --undo)"
check "undo moves the newest outputs to the Trash" '[[ ! -e "$NEWEST" && -n "$TRASHED" && -e "$TRASHED" ]]'
rm -rf "$TRASHED"
check "undo removes the entry" '[[ $("$BIN" --history | wc -l) -eq 49 ]]'
GONE="$("$BIN" --history | head -1 | cut -f5)"; rm -f "$GONE"
NEXT="$("$BIN" --history | sed -n 2p | cut -f5)"
TRASHED="$("$BIN" --undo)"
check "undo skips jobs whose files are already gone" '[[ ! -e "$NEXT" && -e "$TRASHED" ]]'
rm -rf "$TRASHED"
"$BIN" --clear-history
check "clear history" '[[ -z "$("$BIN" --history)" ]]'
check "nothing to undo after clearing" '! "$BIN" --undo 2>/dev/null'

echo "Parallel batches"
CORES=$(sysctl -n hw.activecpu)
IMAGES=("$F"/batch/img??.png)
TRACE="$WORK/trace.txt"
OUT="$(CLEMENTINE_TRACE_CONCURRENCY=1 "$BIN" --run convert.image.jpeg "${IMAGES[@]}" 2>"$TRACE")"
check "all ${#IMAGES[@]} outputs exist" '[[ $(echo "$OUT" | wc -l) -eq ${#IMAGES[@]} ]] && echo "$OUT" | while read -r f; do [[ -s "$f" ]] || exit 1; done'
check "outputs printed in input order" '[[ "$(echo "$OUT" | xargs -n1 basename | sed "s/\.jpg$//" | joined)" == "$(printf "%s\n" "${IMAGES[@]}" | xargs -n1 basename | sed "s/\.png$//" | joined)" ]]'
check "images run several at once (limit = cores/2)" '(( CORES < 4 )) || grep -q "concurrency: [2-9][0-9]* of $((CORES / 2)) for ${#IMAGES[@]}" "$TRACE"'
OUT="$("$BIN" --run convert.image.webp "$F/batch/img01.png" "$F/batch/img08b.png" "$F/batch/img09.png" 2>"$WORK/err.txt")"; STATUS=$?
check "one bad file fails the run" '[[ $STATUS -eq 1 ]] && grep -q "img08b.png" "$WORK/err.txt"'
check "…but the others still finish, in order" '[[ "$(echo "$OUT" | xargs -n1 basename | joined)" == "img01.webp img09.webp" ]]'
OUT="$("$BIN" --run convert.image.jpeg "$F/dups/dup.png" "$F/dups/dup.bmp" "$F/dups/dup.tiff")"
check "same-name outputs never collide" '[[ $(echo "$OUT" | sort -u | wc -l) -eq 3 && $(ls "$F/dups/"*.jpg | wc -l) -eq 3 ]]'
OUT="$(CLEMENTINE_TRACE_CONCURRENCY=1 "$BIN" --run convert.media.mp3 "$F"/media/tone*.wav 2>"$TRACE")"
check "ffmpeg work is capped at 2 at once" 'grep -q "of $(( CORES / 2 < 2 ? 1 : 2 )) for 3" "$TRACE"'
check "media outputs in order" '[[ "$(echo "$OUT" | xargs -n1 basename | joined)" == "tone1.mp3 tone2.mp3 tone3.mp3" ]]'
OUT="$(CLEMENTINE_TRACE_CONCURRENCY=1 "$BIN" --run tool.image.collage "$F/batch/img01.png" "$F/batch/img02.png" "$F/batch/img03.png" 2>"$TRACE")"
check "batch tools still run once with every file" '[[ $(echo "$OUT" | wc -l) -eq 1 && -s "$OUT" ]] && grep -q "for 1 units" "$TRACE"'

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
