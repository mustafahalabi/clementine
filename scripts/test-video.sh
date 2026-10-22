#!/usr/bin/env bash
# Video engine: HDR tone-mapping and HDR-keeping edits, VideoToolbox with its software fallback, Join with phone
# rotation and frame rates, GIF options, and edits on TS/FLV/MPG/3GP.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
source scripts/test-lib.sh
test_setup video
test_defaults_suite
q() { ffmpeg -loglevel error -y "$@"; }
probe() { ffprobe -v error -of csv=p=0 "$@"; }

# The ffmpeg Clementine runs (the suite's tools folder, else the usual paths).
tools_dir="$(defaults read "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory 2>/dev/null)"
APP_FFMPEG="${tools_dir:+$tools_dir/ffmpeg}"; [[ -x "$APP_FFMPEG" ]] || APP_FFMPEG="$(command -v ffmpeg)"
has_zscale() { "$1" -hide_banner -filters 2>/dev/null | grep -qE '^ \S+ zscale '; }

echo "Fixtures in $F"
# Real HLG and PQ need zscale to encode; Homebrew's ffmpeg lacks it, the bundled one has it. Without either, the
# fixtures are only tagged HDR (still enough to exercise detection; the brightness checks are loose).
HDRFF=""
for candidate in "$APP_FFMPEG" vendor/bin/ffmpeg "$(command -v ffmpeg)"; do
  if [[ -x "$candidate" ]] && has_zscale "$candidate"; then HDRFF="$candidate"; break; fi
done
hdr_fixture() { # <transfer> <file>
  if [[ -n "$HDRFF" ]]; then
    "$HDRFF" -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=r=48000 -t 2 \
      -vf "zscale=tin=bt709:pin=bt709:min=bt709:t=$1:p=bt2020:m=bt2020nc:npl=100,format=yuv420p10le" \
      -c:v libx265 -x265-params "log-level=error:colorprim=bt2020:transfer=$1:colormatrix=bt2020nc" -tag:v hvc1 \
      -color_primaries bt2020 -color_trc "$1" -colorspace bt2020nc -c:a aac "$2"
  else
    q -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=r=48000 -t 2 -pix_fmt yuv420p10le \
      -c:v libx265 -x265-params "log-level=error" -tag:v hvc1 -color_primaries bt2020 -color_trc "$1" -colorspace bt2020nc \
      -c:a aac "$2"
  fi
}
hdr_fixture arib-std-b67 "$F/hlg.mov"
hdr_fixture smpte2084 "$F/pq.mov"
[[ -n "$HDRFF" ]] && echo "HDR fixtures made with $HDRFF" || echo "HDR fixtures are tagged only (no zscale found)"
q -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=r=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/sdr.mp4"
q -f lavfi -i testsrc=size=360x640:rate=30 -f lavfi -i sine=r=44100 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/portrait.mp4"
q -f lavfi -i testsrc=size=640x360:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/land.mp4"
q -display_rotation 90 -i "$F/land.mp4" -c copy "$F/phone portrait.mp4" # stored landscape, shown portrait
q -f lavfi -i testsrc=size=640x360:rate=24 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/land24.mp4"
q -f lavfi -i testsrc=size=640x360:rate=30000/1001 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/ntsc.mp4"
q -f lavfi -i testsrc2=size=1280x720:rate=30 -t 4 -c:v libx264 -pix_fmt yuv420p "$F/wide.mp4"
q -f lavfi -i testsrc2=size=64x64:rate=30 -t 1 -c:v libx264 -pix_fmt yuv420p "$F/tiny.mp4"
for ext in ts flv 3gp; do
  q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine=r=44100 -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/clip.$ext"
done
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine=r=44100 -t 3 -c:v mpeg2video -c:a mp2 "$F/clip.mpg"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }

# expect <name> <assertion…> -- <action args…>: the action must succeed and the assertion (given $OUT) must pass.
expect() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out err; err="$(mktemp "$WORK/err.XXXXXX")"
  if ! out="$("$BIN" --run "$@" 2>"$err")"; then bad "$name" "$(cat "$err") $out"; rm -f "$err"; return; fi
  rm -f "$err"
  OUT="$(echo "$out" | head -1)"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} (output: $OUT)"; fi
}
expect_error() {
  local name="$1" needle="$2"; shift 3
  local out
  if out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  if [[ "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name" "unexpected message: $out"; fi
}
# codec,pix_fmt,transfer,primaries of the first video stream.
color() { probe -select_streams v:0 -show_entries stream=codec_name,pix_fmt,color_transfer,color_primaries "$1" | head -1 | sed "s/,*$//"; }
vdims() { probe -select_streams v:0 -show_entries stream=width,height "$1" | head -1 | sed "s/,*$//"; }
rate() { probe -select_streams v:0 -show_entries stream=r_frame_rate "$1" | head -1 | sed "s/,*$//"; }
tag() { probe -select_streams v:0 -show_entries stream=codec_tag_string "$1" | head -1 | sed "s/,*$//"; }
frames() { probe -count_frames -select_streams v:0 -show_entries stream=nb_read_frames "$1" | head -1 | sed "s/,*$//"; }
dur() { probe -show_entries format=duration "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.3}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
# Mean luma (8-bit scale) and saturation of the first frame. The SDR reference sits near 125 / 113; HDR passed
# through untouched reads ~100 / 23-39 (flat, washed out).
signal() { ffmpeg -hide_banner -i "$1" -vf "format=yuv420p,signalstats,metadata=print:file=-" -frames:v 1 -f null - 2>/dev/null \
  | awk -F= -v k="lavfi.signalstats.$2" '$1 == k {print $2; exit}'; }
looks_sdr() { # <file>: brightness in range and colours not washed out
  local y s; y="$(signal "$1" YAVG)"; s="$(signal "$1" SATAVG)"
  awk -v y="$y" -v s="$s" 'BEGIN{exit !(y >= 90 && y <= 160 && s >= 60)}' || { echo "    luma $y sat $s" >&2; return 1; }
}
bt709() { [[ "$(color "$1")" == *",bt709,bt709" ]]; }

echo "HDR → SDR"
expect "HLG → mp4 is BT.709 H.264" 'bt709 "$OUT" && [[ "$(color "$OUT")" == h264,yuv420p,* ]] && looks_sdr "$OUT"' -- convert.media.mp4 "$F/hlg.mov"
expect "PQ → mp4 is BT.709 H.264" 'bt709 "$OUT" && looks_sdr "$OUT"' -- convert.media.mp4 "$F/pq.mov"
expect "PQ → mov (software) is BT.709" 'bt709 "$OUT" && looks_sdr "$OUT"' -- convert.media.mov --software "$F/pq.mov"
expect "HLG → webm is 8-bit BT.709" 'bt709 "$OUT" && [[ "$(color "$OUT")" == vp9,yuv420p,* ]] && looks_sdr "$OUT"' -- convert.media.webm "$F/hlg.mov"
expect "PQ → mkv tone-maps" 'bt709 "$OUT" && looks_sdr "$OUT"' -- convert.media.mkv "$F/pq.mov"
expect "HLG → gif keeps colour" 'looks_sdr "$OUT"' -- convert.media.gif "$F/hlg.mov"
expect "PQ snapshot keeps colour" 'looks_sdr "$OUT"' -- tool.video.snapshot "$F/pq.mov"
expect "HLG compress is BT.709" 'bt709 "$OUT" && looks_sdr "$OUT"' -- tool.compress "$F/hlg.mov"
expect "PQ fit is BT.709" 'bt709 "$OUT" && looks_sdr "$OUT"' -- tool.fit --set megabytes=0.04 "$F/pq.mov"
expect "SDR stays untagged" '[[ "$(color "$OUT")" == h264,yuv420p,unknown,unknown ]]' -- convert.media.mov "$F/sdr.mp4"

echo "HDR kept by edits"
hdr() { [[ "$(color "$1")" == "hevc,yuv420p10le,$2,bt2020" && "$(tag "$1")" == hvc1 ]]; }
expect "HLG trim stays HLG HEVC" 'hdr "$OUT" arib-std-b67 && near "$(dur "$OUT")" 1.5' -- tool.media.trim --set start=0.5 "$F/hlg.mov"
expect "PQ trim (software x265) stays PQ" 'hdr "$OUT" smpte2084' -- tool.media.trim --software --set start=0.5 "$F/pq.mov"
expect "PQ rotate stays PQ" 'hdr "$OUT" smpte2084 && [[ "$(vdims "$OUT")" == "360,640" ]]' -- tool.video.rotate "$F/pq.mov"
expect "HLG speed stays HLG" 'hdr "$OUT" arib-std-b67' -- tool.media.speed --set speed=5 "$F/hlg.mov"
expect "join HLG + HLG stays HLG" 'hdr "$OUT" arib-std-b67' -- tool.video.join "$F/hlg.mov" "$F/hlg.mov"
expect "join HLG + SDR is SDR" 'bt709 "$OUT" && looks_sdr "$OUT"' -- tool.video.join "$F/hlg.mov" "$F/sdr.mp4"

# Without zscale (Homebrew's ffmpeg) tone-mapping falls back to lutrgb + colorspace.
plain=""
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [[ -x "$candidate" ]] && ! has_zscale "$candidate" && [[ -x "$(dirname "$candidate")/ffprobe" ]]; then plain="$(dirname "$candidate")"; break; fi
done
if [[ -n "$plain" ]]; then
  echo "HDR → SDR without zscale ($plain)"
  saved="$tools_dir"
  defaults write "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory -string "$plain"
  expect "fallback HLG → mp4" 'bt709 "$OUT" && looks_sdr "$OUT"' -- convert.media.mp4 "$F/hlg.mov"
  expect "fallback PQ → mp4" 'bt709 "$OUT" && looks_sdr "$OUT"' -- convert.media.mp4 "$F/pq.mov"
  if [[ -n "$saved" ]]; then defaults write "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory -string "$saved"
  else defaults delete "$CLEMENTINE_DEFAULTS_SUITE" toolsDirectory; fi
else
  echo "(no zscale-less ffmpeg found; fallback tone-mapping not checked)"
fi

echo "Hardware encoding"
# x264 writes its settings into the stream; VideoToolbox doesn't.
x264() { grep -aq "x264 - core" "$1"; }
if "$APP_FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc=size=640x360 -frames:v 5 -c:v h264_videotoolbox -q:v 65 -f null - 2>/dev/null; then
  echo "(VideoToolbox available)"
  expect "convert uses VideoToolbox" '! x264 "$OUT"' -- convert.media.mov "$F/sdr.mp4"
  expect "trim uses VideoToolbox" '! x264 "$OUT"' -- tool.media.trim --set start=0.5 "$F/sdr.mp4"
  expect "join uses VideoToolbox" '! x264 "$OUT"' -- tool.video.join "$F/sdr.mp4" "$F/land.mp4"
  expect "HLG trim uses VideoToolbox HEVC" '! grep -aq "x265 (build" "$OUT" && hdr "$OUT" arib-std-b67' -- tool.media.trim --set start=0.5 "$F/hlg.mov"
else
  echo "(no VideoToolbox here: hardware requests must fall back to x264)"
  expect "convert falls back to x264" 'x264 "$OUT"' -- convert.media.mov "$F/sdr.mp4"
  expect "join falls back to x264" 'x264 "$OUT"' -- tool.video.join "$F/sdr.mp4" "$F/land.mp4"
fi
expect "--software uses x264" 'x264 "$OUT"' -- convert.media.mov --software "$F/sdr.mp4"
expect "tiny frame encodes either way" '[[ "$(vdims "$OUT")" == "64,64" ]]' -- convert.media.mp4 "$F/tiny.mp4"
expect "compress stays on x264" 'x264 "$OUT"' -- tool.compress "$F/sdr.mp4"
defaults write "$CLEMENTINE_DEFAULTS_SUITE" hardwareEncoding -bool false
expect "Settings toggle off uses x264" 'x264 "$OUT"' -- convert.media.mov "$F/sdr.mp4"
defaults delete "$CLEMENTINE_DEFAULTS_SUITE" hardwareEncoding

echo "Join"
expect "phone portrait + portrait is portrait" '[[ "$(vdims "$OUT")" == "360,640" ]] && near "$(dur "$OUT")" 4.0 0.3' -- tool.video.join "$F/phone portrait.mp4" "$F/portrait.mp4"
expect "landscape first, portrait majority → portrait" '[[ "$(vdims "$OUT")" == "360,640" ]]' -- tool.video.join "$F/land.mp4" "$F/phone portrait.mp4" "$F/portrait.mp4"
expect "tie keeps the first clip's shape" '[[ "$(vdims "$OUT")" == "640,360" ]]' -- tool.video.join "$F/land.mp4" "$F/portrait.mp4"
expect "24 fps clips stay 24 fps" '[[ "$(rate "$OUT")" == 24/1 ]]' -- tool.video.join "$F/land24.mp4" "$F/land24.mp4"
expect "29.97 fps clips stay 29.97" '[[ "$(rate "$OUT")" == 30000/1001 ]]' -- tool.video.join "$F/ntsc.mp4" "$F/ntsc.mp4"
expect "mixed rates take the highest" '[[ "$(rate "$OUT")" == 30/1 ]]' -- tool.video.join "$F/land24.mp4" "$F/land.mp4"

echo "GIF"
gif() { probe -select_streams v:0 -show_entries stream=width,r_frame_rate "$1" | head -1 | sed "s/,*$//"; }
size() { stat -f%z "$1"; }
expect "convert slice: 720 px, 15 fps" '[[ "$(gif "$OUT")" == "720,15/1" ]]' -- convert.media.gif "$F/wide.mp4"
expect "GIF tool defaults match" '[[ "$(gif "$OUT")" == "720,15/1" ]]' -- tool.video.gif "$F/wide.mp4"
expect "GIF 10 fps, 320 px" '[[ "$(gif "$OUT")" == "320,10/1" ]]' -- tool.video.gif --set fps=0 --set width=0 "$F/wide.mp4"
expect "GIF 30 fps, original width" '[[ "$(gif "$OUT")" == "1280,30/1" ]]' -- tool.video.gif --set fps=4 --set width=6 "$F/wide.mp4"
expect "GIF width never upscales" '[[ "$(gif "$OUT")" == "640,15/1" ]]' -- tool.video.gif --set width=5 "$F/sdr.mp4"
expect "GIF under 0.5 MB" '[[ $(size "$OUT") -le 500000 ]]' -- tool.video.gif --set megabytes=0.5 "$F/wide.mp4"
expect "GIF under 0.2 MB" '[[ $(size "$OUT") -le 200000 ]]' -- tool.video.gif --set megabytes=0.2 "$F/wide.mp4"
expect "GIF already under target is untouched" '[[ "$(gif "$OUT")" == "720,15/1" ]]' -- tool.video.gif --set megabytes=50 "$F/wide.mp4"
before="$(ls "$F" | wc -l)"
expect_error "impossible GIF target explains" "under" -- tool.video.gif --set megabytes=0.001 "$F/wide.mp4"
[[ "$(ls "$F" | wc -l)" == "$before" ]] && ok "failed GIF leaves nothing" || bad "failed GIF leaves nothing" "$(ls "$F")"
expect_error "convert slice takes no GIF settings" "takes no parameters" -- convert.media.gif --set fps=1 "$F/wide.mp4"

echo "TS / FLV / MPG / 3GP edits"
for ext in ts flv 3gp; do
  expect "$ext trim is H.264 with frames" '[[ "$(color "$OUT")" == h264,* && $(frames "$OUT") -ge 45 ]] && near "$(dur "$OUT")" 2.0 0.2' -- tool.media.trim --set start=1 "$F/clip.$ext"
  expect "$ext speed is H.264" '[[ "$(color "$OUT")" == h264,* ]] && near "$(dur "$OUT")" 2.4 0.2' -- tool.media.speed --set speed=3 "$F/clip.$ext"
  expect "$ext rotate is H.264" '[[ "$(color "$OUT")" == h264,* && "$(vdims "$OUT")" == "240,320" ]]' -- tool.video.rotate "$F/clip.$ext"
done
mpg_ok() { [[ "$(color "$1")" == mpeg2video,* ]] && (( $(probe -show_entries format=bit_rate "$1") > 300000 )); }
expect "mpg trim is good-quality MPEG-2" 'mpg_ok "$OUT" && near "$(dur "$OUT")" 2.0 0.2' -- tool.media.trim --set start=1 "$F/clip.mpg"
expect "mpg speed" 'mpg_ok "$OUT"' -- tool.media.speed --set speed=3 "$F/clip.mpg"
expect "mpg rotate" 'mpg_ok "$OUT" && [[ "$(vdims "$OUT")" == "240,320" ]]' -- tool.video.rotate "$F/clip.mpg"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf '  failed: %s\n' "${failures[@]}"; exit 1; }
