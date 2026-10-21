#!/usr/bin/env bash
# The engine side of the waveform editors: channel layouts and gains, bleeps on audio and video,
# trim times in the editors' format, and (debug builds) the editors rendered offscreen with real peaks.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
WORK="$(mktemp -d /tmp/clementine-waveform.XXXXXX)"
F="$WORK/fixtures"
mkdir -p "$F"
q() { ffmpeg -loglevel error -y "$@"; }
probe() { ffprobe -v error -of csv=p=0 "$@"; }

echo "Fixtures in $F"
q -f lavfi -i "sine=f=440:r=44100" -t 3 -ac 1 "$F/mono.wav"
# Stereo with sound on the left only.
q -f lavfi -i "sine=f=440:r=44100" -f lavfi -i "anullsrc=r=44100:cl=mono" -filter_complex "[0][1]amerge=inputs=2" -t 3 "$F/left only.wav"
q -i "$F/mono.wav" -c:a libmp3lame "$F/mono.mp3"
q -f lavfi -i "sine=f=440:r=48000" -t 3 -ac 2 -c:a aac "$F/stereo.m4a"
q -f lavfi -i "sine=f=440:r=48000" -t 3 -ac 6 "$F/surround.wav"
# Video with a silent soundtrack, so any sound in the output is the bleep.
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/quiet clip.mp4"
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 3 -c:v libx264 -pix_fmt yuv420p -c:a libopus "$F/quiet.mkv"
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 3 -c:v libvpx-vp9 -c:a libopus "$F/quiet.webm"
q -f lavfi -i testsrc=size=320x240:rate=25 -t 3 -c:v libx264 -pix_fmt yuv420p "$F/no sound.mp4"
# Speech-like bursts with silence at both ends, for the editor renders.
q -f lavfi -i "anoisesrc=d=8:c=pink:r=44100:a=0.8" \
  -af "volume='pow(abs(sin(2*PI*2*t)),1.5)':eval=frame,adelay=1500|1500,apad=pad_dur=1.5" -t 11 -ac 2 "$F/speech.wav"
q -f lavfi -i testsrc2=size=640x360:rate=25 -i "$F/speech.wav" -t 11 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$F/speech.mp4"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }

# expect <name> <assertion-command…> -- <action args…>: action must succeed and the assertion (given $OUT) must pass.
expect() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out
  if ! out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "$out"; return; fi
  OUT="$(echo "$out" | head -1)"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} (output: $OUT)"; fi
}
# expect_error <name> <substring> -- <action args…>: action must fail with a readable message containing substring.
expect_error() {
  local name="$1" needle="$2"; shift 3
  local out
  if out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  if [[ "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name" "unexpected message: $out"; fi
}
dur() { probe -show_entries format=duration "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.3}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
channels() { probe -select_streams a:0 -show_entries stream=channels "$1"; }
# rms <file> <channel 1-based> [ffmpeg input args…]: RMS level in dB of one channel (-inf for silence → -999).
rms() {
  local file="$1" ch="$2"; shift 2
  ffmpeg -nostdin "$@" -i "$file" -map 0:a:0 -af "astats=measure_overall=none:measure_perchannel=RMS_level" -f null - 2>&1 \
    | awk -v ch="$ch" '/Channel:/{c=$NF} /RMS level dB/{if (c==ch) {v=$NF; if (v=="-inf") v=-999; print v; exit}}'
}
louder() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a > b)}'; }
video_md5() { ffmpeg -nostdin -loglevel error -i "$1" -map 0:v:0 -c copy -f md5 - 2>/dev/null; }

echo "Channels"
expect "default is still mono" '[[ "$(channels "$OUT")" == 1 ]]' -- tool.audio.channels "$F/stereo.m4a"
expect "old choice index 1 → stereo" '[[ "$(channels "$OUT")" == 2 ]]' -- tool.audio.channels --set channels=1 "$F/mono.wav"
expect "mono → stereo keeps level" 'near "$(rms "$OUT" 1)" "$(rms "$F/mono.wav" 1)" 0.5 && near "$(rms "$OUT" 2)" "$(rms "$F/mono.wav" 1)" 0.5' -- tool.audio.channels --set channels=stereo "$F/mono.wav"
expect "mono → mono with gains averages them" '[[ "$(channels "$OUT")" == 1 ]] && near "$(rms "$OUT" 1)" "$(awk -v r="$(rms "$F/mono.wav" 1)" "BEGIN{print r-6.02}")" 0.5' -- tool.audio.channels --set left=0 "$F/mono.wav"
expect "mp3 → mono" '[[ "$(channels "$OUT")" == 1 ]]' -- tool.audio.channels "$F/mono.mp3"
expect "stereo → mono keeps level" 'near "$(rms "$OUT" 1)" "$(rms "$F/stereo.m4a" 1)" 0.5' -- tool.audio.channels --set channels=mono "$F/stereo.m4a"
expect "swap by name moves sound right" '[[ "$(channels "$OUT")" == 2 ]] && [[ "$(rms "$OUT" 1)" == -999 ]] && louder "$(rms "$OUT" 2)" -30' -- tool.audio.channels --set channels=swap "$F/left only.wav"
expect "swap names output 'swapped'" '[[ "$OUT" == *"(swapped"*.wav ]]' -- tool.audio.channels --set channels=2 "$F/left only.wav"
expect "left gain 0 silences left" '[[ "$(rms "$OUT" 1)" == -999 ]] && near "$(rms "$OUT" 2)" "$(rms "$F/stereo.m4a" 2)" 0.5' -- tool.audio.channels --set channels=stereo --set left=0 "$F/stereo.m4a"
expect "right gain 0.5 is -6 dB" 'near "$(rms "$OUT" 2)" "$(awk -v r="$(rms "$F/stereo.m4a" 2)" "BEGIN{print r-6.02}")" 0.5' -- tool.audio.channels --set channels=stereo --set right=0.5 "$F/stereo.m4a"
expect "swap with gains applies to output sides" 'louder "$(rms "$OUT" 2)" -30 && near "$(rms "$OUT" 2)" "$(awk -v r="$(rms "$F/left only.wav" 1)" "BEGIN{print r-6.02}")" 0.5' -- tool.audio.channels --set channels=swap --set right=0.5 "$F/left only.wav"
expect "mono of left-only with left 2× is full level" 'near "$(rms "$OUT" 1)" "$(rms "$F/left only.wav" 1)" 0.5' -- tool.audio.channels --set channels=mono --set left=2 "$F/left only.wav"
expect "5.1 → swapped stereo" '[[ "$(channels "$OUT")" == 2 ]]' -- tool.audio.channels --set channels=swap "$F/surround.wav"

echo "Bleep on video"
expect_list() { local name="$1" needle="$2"; shift 2; if "$BIN" --list "$@" | grep -q "$needle"; then ok "$name"; else bad "$name" "$needle not offered"; fi; }
expect_list "video offers Bleep" tool.audio.bleep "$F/quiet clip.mp4"
expect "mp4 bleep copies the picture" '[[ "$OUT" == *"(bleeped).mp4" && "$(video_md5 "$OUT")" == "$(video_md5 "$F/quiet clip.mp4")" ]]' -- tool.audio.bleep --set "ranges=1-2" "$F/quiet clip.mp4"
expect "mp4 bleep: tone inside, silence outside" 'louder "$(rms "$OUT" 1 -ss 1.2 -t 0.6)" -40 && [[ "$(rms "$OUT" 1 -ss 2.5 -t 1)" == -999 ]]' -- tool.audio.bleep --set "ranges=1-2" "$F/quiet clip.mp4"
expect "mp4 bleep keeps length" 'near "$(dur "$OUT")" 4.0' -- tool.audio.bleep --set "ranges=0:00.5-0:01, 3-3.5" "$F/quiet clip.mp4"
expect "mkv bleep keeps video + audio" '[[ "$(probe -show_entries stream=codec_type "$OUT" | sort | tr "\n" " ")" == "audio video " ]]' -- tool.audio.bleep --set "ranges=1-1.5" "$F/quiet.mkv"
expect "webm bleep uses opus" '[[ "$(probe -select_streams a -show_entries stream=codec_name "$OUT")" == opus ]]' -- tool.audio.bleep --set "ranges=1-1.5" "$F/quiet.webm"
expect_error "video without sound explains" "no audio track" -- tool.audio.bleep --set "ranges=1-2" "$F/no sound.mp4"
expect "editor-style ranges (ms precision)" '[[ -f "$OUT" ]]' -- tool.audio.bleep --set "ranges=0:01.250-0:01.900, 0:02.000-0:02.500" "$F/mono.wav"

echo "Trim times from the editor"
expect "start/end with milliseconds" 'near "$(dur "$OUT")" 1.75 0.1' -- tool.media.trim --set start=0:01.500 --set end=0:03.250 "$F/speech.wav"
expect "start only runs to the end" 'near "$(dur "$OUT")" 9.0 0.1' -- tool.media.trim --set start=0:02.000 "$F/speech.wav"
expect "video trim with editor times" 'near "$(dur "$OUT")" 2.5 0.2' -- tool.media.trim --set start=0:01.000 --set end=0:03.500 "$F/speech.mp4"

echo "Editors (offscreen render)"
if "$BIN" --render-ui "$WORK/renders" "$F/speech.wav" "$F/speech.wav" "$F/speech.mp4" >/dev/null 2>&1; then
  for name in trim-audio trim-video bleep channels-swap; do
    for mode in light dark; do
      png="$WORK/renders/$name-$mode.png"
      if [[ -f "$png" && $(stat -f%z "$png") -gt 20000 ]]; then ok "$name ($mode) rendered"; else bad "$name ($mode)" "missing or empty render"; fi
    done
  done
else
  echo "  (skipped: --render-ui needs a debug build)"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
