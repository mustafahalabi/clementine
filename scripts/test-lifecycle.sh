#!/usr/bin/env bash
# Process lifecycle: SIGINT/SIGTERM during a run stop the tools and leave nothing behind, tools that crash or die
# from a signal are failures (not quiet cancellations), the Mac is kept awake while a job runs, and `--set` values
# are checked against each parameter's definition. Fake tools are put in front of Homebrew's through the Settings
# tools folder, set in a scratch defaults suite (debug-build override).
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
WORK="$(mktemp -d /tmp/clementine-lifecycle.XXXXXX)"
F="$WORK/fixtures"
FAKE="$WORK/fake-tools"
mkdir -p "$F" "$FAKE"
export CLEMENTINE_DEFAULTS_SUITE="app.clementine.tests.lifecycle.$$"
export CLEMENTINE_SUPPORT_DIR="$WORK/support"
cleanup() {
  defaults delete "$CLEMENTINE_DEFAULTS_SUITE" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$CLEMENTINE_DEFAULTS_SUITE.plist"
}
trap cleanup EXIT
q() { ffmpeg -loglevel error -y "$@"; }

echo "Fixtures in $F"
# Long enough that a VP9 encode is still running seconds after it starts.
q -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=r=44100 -t 30 -c:v libx264 -preset ultrafast -c:a aac "$F/long.mp4"
q -f lavfi -i "sine=r=44100" -t 2 "$F/tone.wav"
q -f lavfi -i testsrc=size=120x80 -frames:v 1 "$F/photo.png"

PASS=0; FAIL=0; FAILED=()
ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1: $2"); echo "  ✗ $1 — $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-assertion failed}"; fi; }
listing() { ls -A "$F" | sort; }

use_fake_tools() { defaults write "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory -string "$FAKE"; }
use_real_tools() { defaults delete "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory >/dev/null 2>&1; }
fake_ffmpeg() { printf '#!/bin/bash\n%s\n' "$1" > "$FAKE/ffmpeg"; chmod +x "$FAKE/ffmpeg"; }

# Waits up to 10 s for a child of $1 named $2 (fake tools exec perl, so they're found by name "perl"); prints its pid.
child_of() {
  local i pid
  for i in $(seq 100); do
    pid="$(pgrep -P "$1" "$2" | head -1)"; [[ -n "$pid" ]] && { echo "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}
# Waits up to $2 seconds for pid $1 to exit.
gone_within() {
  local i
  for i in $(seq $(($2 * 10))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

# interrupt <name> <signal> <expected exit>: starts a long encode, signals the CLI mid-run, then checks that the
# tool is gone, nothing new is in the folder and the exit status is 128 + signal.
interrupt() {
  local name="$1" sig="$2" expected="$3" before cli tool status
  before="$(listing)"
  "$BIN" --run convert.media.webm "$F/long.mp4" >"$WORK/out.txt" 2>"$WORK/err.txt" &
  cli=$!
  if ! tool="$(child_of $cli ffmpeg)"; then bad "$name" "ffmpeg never started"; kill -9 $cli; return; fi
  sleep 1
  check "$name: output is being written before the signal" '[[ -e "$F/long.webm" ]]'
  if [[ "$sig" == TERM ]]; then
    # Captured first: `pmset | grep -q` fails at random under pipefail when grep exits early.
    local assertions; assertions="$(pmset -g assertions)"
    check "$name: Mac kept awake while the job runs" '[[ "$assertions" == *"pid $cli(Clementine)"*"Clementine is converting files"* ]]'
  fi
  kill -"$sig" $cli
  wait $cli; status=$?
  check "$name: exits $expected" '[[ $status -eq $expected ]]' "exit $status"
  check "$name: ffmpeg stopped" '! kill -0 $tool 2>/dev/null' "pid $tool still running"
  check "$name: no output or partial file left" '[[ "$(listing)" == "$before" ]]' "new: $(comm -13 <(echo "$before") <(listing) | tr '\n' ' ')"
  check "$name: reports the file as cancelled" 'grep -q "cancelled: long.mp4" "$WORK/err.txt"' "$(cat "$WORK/err.txt")"
  check "$name: prints no output path" '[[ ! -s "$WORK/out.txt" ]]'
}

echo "Interrupting a run"
interrupt "SIGTERM" TERM 143
interrupt "SIGINT" INT 130
interrupt "SIGHUP" HUP 129

echo "Tools that ignore SIGTERM"
use_fake_tools
fake_ffmpeg 'exec perl -e '"'"'$SIG{TERM} = "IGNORE"; sleep 60'"'"
before="$(listing)"
start=$SECONDS
"$BIN" --run convert.media.mp3 "$F/tone.wav" >/dev/null 2>"$WORK/err.txt" &
cli=$!
tool="$(child_of $cli perl)" || bad "stubborn tool started" "no child"
sleep 0.5
kill -TERM $cli
wait $cli; status=$?
check "stubborn tool: exits 143" '[[ $status -eq 143 ]]' "exit $status"
check "stubborn tool: killed after the grace period" '! kill -0 $tool 2>/dev/null' "pid $tool still running"
check "stubborn tool: done within 8 s" '(( SECONDS - start <= 8 ))' "took $((SECONDS - start)) s"
check "stubborn tool: nothing left behind" '[[ "$(listing)" == "$before" ]]'

"$BIN" --run convert.media.mp3 "$F/tone.wav" >/dev/null 2>&1 &
cli=$!
tool="$(child_of $cli perl)" || bad "second signal: tool started" "no child"
sleep 0.5
start=$SECONDS
kill -TERM $cli; sleep 0.3; kill -INT $cli
wait $cli; status=$?
check "second signal: exits at once with 128 + its number" '[[ $status -eq 130 ]] && (( SECONDS - start <= 2 ))' "exit $status after $((SECONDS - start)) s"
check "second signal: tool killed" 'gone_within $tool 2' "pid $tool still running"

echo "Tools that fail on their own"
fake_ffmpeg 'echo "about to crash" >&2; kill -SEGV $$'
before="$(listing)"
out="$("$BIN" --run convert.media.mp3 "$F/tone.wav" 2>&1)"; status=$?
check "crashing tool: exits 1, not 0" '[[ $status -eq 1 ]]' "exit $status: $out"
check "crashing tool: says it crashed" '[[ "$out" == *"ffmpeg failed"*"stopped unexpectedly (Segmentation fault"* ]]' "$out"
check "crashing tool: nothing left behind" '[[ "$(listing)" == "$before" ]]'

fake_ffmpeg 'kill -KILL $$'
out="$("$BIN" --run convert.media.mp3 "$F/tone.wav" 2>&1)"; status=$?
check "tool killed from outside: a failure, exit 1" '[[ $status -eq 1 && "$out" == *"stopped unexpectedly (Killed"* ]]' "exit $status: $out"

fake_ffmpeg 'echo "Conversion failed!" >&2; echo "Invalid data found when processing input" >&2; exit 255'
out="$("$BIN" --run convert.media.mp3 "$F/tone.wav" 2>&1)"; status=$?
check "tool exiting 255 by itself: a failure, exit 1" '[[ $status -eq 1 && "$out" == *"Invalid data found"* ]]' "exit $status: $out"
use_real_tools

echo "Exit status"
out="$("$BIN" --run convert.media.mp3 "$F/tone.wav" "$F/photo.png" 2>&1)"; status=$?
check "one failure among successes exits 1" '[[ $status -eq 1 ]]' "exit $status"
rm -f "$F/tone.mp3"

echo "--set validation"
# expect_usage <name> <message substring> -- <--run args…>: must exit 2, print the message and create nothing.
expect_usage() {
  local name="$1" needle="$2"; shift 3
  local before out status; before="$(listing)"
  out="$("$BIN" --run "$@" 2>&1)"; status=$?
  if [[ $status -ne 2 ]]; then bad "$name" "exit $status: $out"; return; fi
  if [[ "$out" != *"$needle"* ]]; then bad "$name" "unexpected message: $out"; return; fi
  if [[ "$(listing)" != "$before" ]]; then bad "$name" "created files"; return; fi
  ok "$name"
}
expect_usage "choice index too high" "0 = 0.25×" -- tool.media.speed --set speed=99 "$F/tone.wav"
expect_usage "negative choice index" "not a valid choice" -- tool.media.speed --set speed=-1 "$F/tone.wav"
expect_usage "unknown choice label" "7 = 4×" -- tool.media.speed --set speed=fast "$F/tone.wav"
expect_usage "compress level -1" "not a valid choice" -- tool.compress --set level=-1 "$F/photo.png"
expect_usage "number not numeric" "not a number" -- tool.fit --set megabytes=abc "$F/photo.png"
expect_usage "number nan" "not a number" -- tool.fit --set megabytes=nan "$F/photo.png"
expect_usage "number inf" "not a number" -- tool.fit --set megabytes=inf "$F/photo.png"
expect_usage "number empty" "not a number" -- tool.fit --set megabytes= "$F/photo.png"
expect_usage "slider out of range" "between -2 and 2" -- tool.image.adjust --set exposure=5 "$F/photo.png"
expect_usage "--set empty" "--set needs key=value" -- tool.fit --set "" "$F/photo.png"
expect_usage "--set without =" "--set needs key=value" -- tool.fit --set megabytes "$F/photo.png"
expect_usage "trailing --set" "--set needs key=value" -- tool.fit "$F/photo.png" --set
expect_usage "unknown key lists valid ones" "valid keys: megabytes" -- tool.fit --set size=1 "$F/photo.png"
expect_usage "unknown option" "unknown option --recrod" -- tool.fit --recrod "$F/photo.png"

out="$("$BIN" --render-wheel "$WORK/wheel.png" "$F/photo.png" --hover 2>&1)"; status=$?
check "trailing --hover is a usage error, not a crash" '[[ $status -eq 2 && "$out" == *"--hover needs"* ]]' "exit $status: $out"
out="$("$BIN" --render-wheel "$WORK/wheel.png" --hover x "$F/photo.png" 2>&1)"; status=$?
check "non-numeric --hover is a usage error" '[[ $status -eq 2 ]]' "exit $status: $out"

# Valid values still work: labels (any case), indexes, typed numbers outside the slider-style bounds.
out="$("$BIN" --run tool.media.speed --set speed=2× "$F/tone.wav" 2>/dev/null)"; status=$?
check "choice label accepted" '[[ $status -eq 0 && "$out" == *"(2×).wav" ]]' "exit $status: $out"
out="$("$BIN" --run tool.media.speed --set speed=7 "$F/tone.wav" 2>/dev/null)"; status=$?
check "last choice index accepted" '[[ $status -eq 0 && -f "$out" ]]' "exit $status: $out"
out="$("$BIN" --run tool.image.adjust --set exposure=-2 --set saturation=2 "$F/photo.png" 2>/dev/null)"; status=$?
check "slider bounds are inclusive" '[[ $status -eq 0 && -f "$out" ]]' "exit $status: $out"

echo
echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
