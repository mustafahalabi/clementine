#!/usr/bin/env bash
# Presets (saved settings as wheel slices) and the ⌃ file actions wheel, headlessly. Runs against a scratch
# defaults suite and support folder, and with CLEMENTINE_FAKE_EFFECTS so Terminal, Finder and AirDrop are only
# described, never opened (all debug-build overrides).
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
source scripts/test-lib.sh
test_defaults_suite   # scratch suite, deleted on exit
test_setup presets-files
export CLEMENTINE_SUPPORT_DIR="$WORK/support"
export CLEMENTINE_FAKE_EFFECTS=1
q() { ffmpeg -loglevel error -y "$@"; }

echo "Fixtures in $F"
mkdir -p "$F/folder" "$F/other dir"
q -f lavfi -i testsrc=size=640x480 -frames:v 1 "$F/photo.png"
q -f lavfi -i testsrc=size=320x240:rate=25 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/clip.mp4"
NOTE="$F/other dir/note's.txt"   # a space and a quote in the path
printf 'hello\n' > "$NOTE"
head -c 6000000 /dev/urandom > "$F/big.bin"
echo hi > "$F/folder/a.txt"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }
# check <name> <assertion…>: the assertion is eval'd.
check() { local name="$1"; shift; if eval "$*"; then ok "$name"; else bad "$name" "assertion failed: $*"; fi; }

# section <Convert|Tools|Files> <file…>: the visible slice ids of one wheel, in order.
section() {
  local name="$1"; shift
  "$BIN" --list "$@" 2>/dev/null | awk -v s="$name" '/^[A-Z]/{on=($1==s); next} on && !/\(hidden\)$/{print $1}'
}
joined() { tr '\n' ' ' | sed 's/ $//'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
# say <args…>: the CLI's stdout and stderr together, whatever its exit status (for grepping messages).
say() { "$BIN" "$@" 2>&1; return 0; }
T=$'\t'; NL=$'\n'
count_files() { find "$F" -type f | wc -l | tr -d ' '; }

echo "File actions wheel (⌃)"
ALL="file.path file.name file.sha256 file.datauri file.terminal file.reveal file.airdrop"
check "--list shows the ⌃ wheel" '"$BIN" --list "$F/photo.png" | grep -qx "Files (⌃)"'
check "a file gets every file action, in catalog order" '[[ "$(section Files "$F/photo.png" | joined)" == "$ALL" ]]'
check "a folder gets no hash or data URI" '[[ "$(section Files "$F/folder" | joined)" == "file.path file.name file.terminal file.reveal file.airdrop" ]]'
check "a file over 5 MB gets no data URI" '! section Files "$F/big.bin" | grep -qx file.datauri'
BEFORE="$(count_files)"
check "SHA-256 prints the hash (image)" '[[ "$("$BIN" --run file.sha256 "$F/photo.png")" == "$(sha "$F/photo.png")" ]]'
check "SHA-256 prints the hash (video)" '[[ "$("$BIN" --run file.sha256 "$F/clip.mp4")" == "$(sha "$F/clip.mp4")" ]]'
check "SHA-256 of 6 MB matches shasum" '[[ "$("$BIN" --run file.sha256 "$F/big.bin")" == "$(sha "$F/big.bin")" ]]'
EXPECTED="$(printf '%s  photo.png\n%s  clip.mp4' "$(sha "$F/photo.png")" "$(sha "$F/clip.mp4")")"
check "several files: shasum-style lines, in order" '[[ "$("$BIN" --run file.sha256 "$F/photo.png" "$F/clip.mp4")" == "$EXPECTED" ]]'
check "SHA-256 of a folder fails cleanly" '! "$BIN" --run file.sha256 "$F/folder" >/dev/null 2>&1'
check "Copy Path prints absolute paths, one per line" '[[ "$("$BIN" --run file.path "$F/photo.png" "$NOTE")" == "$F/photo.png$NL$NOTE" ]]'
check "Copy Name prints the names" '[[ "$("$BIN" --run file.name "$F/photo.png" "$F/folder")" == "photo.png${NL}folder" ]]'
URI="$("$BIN" --run file.datauri "$F/photo.png")"
check "data URI has the image's MIME type" '[[ "$URI" == data:image/png\;base64,* ]]'
check "data URI decodes to the same bytes" '[[ "$(printf %s "${URI#*,}" | base64 -d | shasum -a 256 | cut -d" " -f1)" == "$(sha "$F/photo.png")" ]]'
check "text files get text/plain" '[[ "$("$BIN" --run file.datauri "$NOTE")" == "data:text/plain;base64,aGVsbG8K" ]]'
OUT="$("$BIN" --run file.datauri "$F/big.bin" 2>"$WORK/err.txt")"; STATUS=$?
check "data URI refuses files over 5 MB with a reason" '[[ $STATUS -eq 1 && -z "$OUT" ]] && grep -q "up to 5 MB" "$WORK/err.txt"'
OUT="$("$BIN" --run file.terminal "$F/photo.png" "$F/clip.mp4" "$F/folder" 2>"$WORK/err.txt")"
check "Open in Terminal opens each folder once (the folder itself for folders)" '[[ "$OUT" == "Opened in Terminal: $F, $F/folder" ]] && grep -qx "effect: terminal $F | $F/folder" "$WORK/err.txt"'
OUT="$("$BIN" --run file.reveal "$F/photo.png" 2>"$WORK/err.txt")"
check "Reveal in Finder" '[[ "$OUT" == "Shown in Finder" ]] && grep -qx "effect: reveal $F/photo.png" "$WORK/err.txt"'
OUT="$("$BIN" --run file.airdrop "$F/photo.png" "$F/clip.mp4" 2>"$WORK/err.txt")"
check "AirDrop gets every file at once" '[[ "$OUT" == "AirDrop closed" ]] && grep -qx "effect: airdrop $F/photo.png | $F/clip.mp4" "$WORK/err.txt"'
check "file actions write no files" '[[ "$(count_files)" == "$BEFORE" ]]'
"$BIN" --run file.sha256 --record "$F/clip.mp4" >/dev/null
"$BIN" --run file.sha256 --record "$F/clip.mp4" >/dev/null
check "usage reorders the ⌃ wheel (per kind)" '[[ "$(section Files "$F/clip.mp4" | head -1)" == file.sha256 && "$(section Files "$F/photo.png" | head -1)" == file.path ]]'
check "…and leaves no history (nothing to undo)" '[[ -z "$("$BIN" --history)" ]]'

echo "Presets"
check "none to begin with" '[[ -z "$("$BIN" --list-presets 2>&1)" ]]'
ID="$("$BIN" --save-preset "Half" --action tool.image.resize --set size=1)"
check "--save-preset prints the new id" '[[ "$ID" == preset.* ]]'
check "presets.json goes to the support folder" '[[ -f "$CLEMENTINE_SUPPORT_DIR/presets.json" ]]'
check "choices are stored by label" 'grep -q "\"size\" : \"50%\"" "$CLEMENTINE_SUPPORT_DIR/presets.json"'
check "--list-presets: id, name, action, values" '[[ "$("$BIN" --list-presets)" == "$ID${T}Half${T}tool.image.resize${T}size=50%" ]]'
check "the preset is a slice right after its action" '[[ "$(section Tools "$F/photo.png" | grep -A1 -x tool.image.resize | tail -1)" == "$ID" ]]'
check "…only for files its action accepts" '! section Tools "$F/clip.mp4" | grep -qx "$ID"'
OUT="$("$BIN" --preset half --record "$F/photo.png")"
check "--preset runs by name (any case) with the saved values" '[[ -f "$OUT" && "$(sips -g pixelWidth "$OUT" | awk "/pixelWidth/{print \$2}")" == 320 ]]'
check "history names the preset" '[[ "$("$BIN" --history | head -1 | cut -f2,3)" == "$ID${T}Half" ]]'
OUT="$("$BIN" --run "$ID" "$F/photo.png")"
check "--run <preset id> works too" '[[ -f "$OUT" ]]'
"$BIN" --save-preset "Ten" --action tool.fit --set megabytes=10 >/dev/null
check "numbers are stored plainly" '"$BIN" --list-presets | grep -q "megabytes=10$"'
check "a taken name is refused (any case)" '! "$BIN" --save-preset "half" --action tool.compress 2>/dev/null'
check "an action without settings is refused" 'grep -q "no settings" <<<"$(say --save-preset "PNG" --action convert.image.png)"'
check "an unknown action is refused" '! "$BIN" --save-preset "X" --action tool.nope 2>/dev/null'
check "an unknown key is refused" 'grep -q "valid keys: megabytes" <<<"$(say --save-preset "X" --action tool.fit --set size=1)"'
check "a bad choice is refused" 'grep -q "not a valid choice" <<<"$(say --save-preset "X" --action tool.compress --set level=Huge)"'
check "a typed number out of range is refused" 'grep -q "between 0.05 and 4000" <<<"$(say --save-preset "X" --action tool.fit --set megabytes=0)"'
check "an empty name is refused" '! "$BIN" --save-preset " " --action tool.fit 2>/dev/null'
check "--preset with an unknown name lists the presets" 'grep -q "presets: “Half”, “Ten”" <<<"$(say --preset nope "$F/photo.png")"'
"$BIN" --rename-preset half "Half size"
check "rename keeps the id" '[[ "$("$BIN" --list-presets | cut -f1,2 | head -1)" == "$ID${T}Half size" ]]'
check "…and the old name is gone" '! "$BIN" --preset Half "$F/photo.png" >/dev/null 2>&1'
check "renaming onto a taken name is refused" '! "$BIN" --rename-preset "Half size" Ten 2>/dev/null'
defaults write "$CLEMENTINE_DEFAULTS_SUITE" hiddenActions -array "$ID"
check "a hidden preset leaves the wheel" '! section Tools "$F/photo.png" | grep -qx "$ID" && "$BIN" --list "$F/photo.png" | grep -q "$ID.*(hidden)"'
"$BIN" --delete-preset "Half size"
check "delete removes it" '! "$BIN" --list-presets | grep -q "$ID"'
check "…and forgets that it was hidden" '[[ -z "$(defaults read "$CLEMENTINE_DEFAULTS_SUITE" hiddenActions 2>/dev/null | grep preset)" ]]'

echo "Shortcuts (the ShortcutRunner path)"
check "a file action returns its value as text" '[[ "$("$BIN" --shortcut-run file.sha256 "$F/photo.png" 2>/dev/null)" == "== SHA-256 ==$NL$(sha "$F/photo.png")" ]]'
check "Open in Terminal returns nothing" '[[ -z "$("$BIN" --shortcut-run file.terminal "$F/photo.png" 2>/dev/null)" ]]'
TEN="$("$BIN" --list-presets | awk -F"\t" '$2=="Ten"{print $1}')"
check "a preset runs through Shortcuts" '[[ -n "$TEN" && -f "$("$BIN" --shortcut-run "$TEN" "$F/photo.png" 2>/dev/null)" ]]'

echo "Checked on load"
cat > "$CLEMENTINE_SUPPORT_DIR/presets.json" <<'JSON'
{ "version": 1, "presets": [
  { "id": "preset.good0001", "name": "Smallest", "action": "tool.compress", "values": { "level": "Smallest" } },
  { "id": "preset.bad00001", "name": "Gone", "action": "tool.removed", "values": {} },
  { "id": "preset.bad00002", "name": "Huge", "action": "tool.compress", "values": { "level": "Huge" } },
  { "id": "preset.bad00003", "name": "Zero", "action": "tool.fit", "values": { "megabytes": "0" } },
  { "id": "preset.bad00004", "name": "smallest", "action": "tool.compress", "values": {} },
  { "id": "nope", "name": "Odd id", "action": "tool.compress", "values": {} },
  { "id": "preset.bad00005", "name": "Extra", "action": "tool.compress", "values": { "speed": "2" } }
] }
JSON
"$BIN" --list-presets >"$WORK/out.txt" 2>"$WORK/err.txt"
check "valid presets still load" '[[ "$(cut -f2 "$WORK/out.txt")" == Smallest ]]'
check "each invalid one is skipped with its reason" '[[ $(grep -c "^skipped preset" "$WORK/err.txt") -eq 6 ]]'
check "…unknown action" 'grep -q "“Gone”: there.s no action tool.removed" "$WORK/err.txt"'
check "…bad choice" 'grep -q "“Huge”: level=Huge: not a valid choice" "$WORK/err.txt"'
check "…number out of range" 'grep -q "“Zero”: megabytes=0: must be between" "$WORK/err.txt"'
check "…duplicate name" 'grep -q "“smallest”: another preset has the same name" "$WORK/err.txt"'
check "…unknown key" 'grep -q "“Extra”: tool.compress has no setting \"speed\"" "$WORK/err.txt"'
check "skipped presets stay off the wheel" '[[ "$(section Tools "$F/photo.png" | grep -c "^preset\.")" -eq 1 ]]'
check "--preset on a skipped one says why" 'grep -q "can.t run: level=Huge" <<<"$(say --preset Huge "$F/photo.png")"'
echo '{ not json' > "$CLEMENTINE_SUPPORT_DIR/presets.json"
check "an unreadable file is reported" '"$BIN" --list-presets 2>&1 | grep -q "presets.json can.t be read"'
check "…the wheels still work" '[[ -n "$(section Tools "$F/photo.png")" ]]'
"$BIN" --save-preset "Fresh" --action tool.compress >/dev/null
check "saving moves the unreadable file aside instead of losing it" 'ls "$CLEMENTINE_SUPPORT_DIR" | grep -q "presets (unreadable" && "$BIN" --list-presets | grep -q Fresh'

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
