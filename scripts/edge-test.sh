#!/usr/bin/env bash
# Edge cases the smoke test doesn't cover: odd names, rotated/odd-sized media, cover art,
# EXIF orientation, unusual color spaces, multi-page PDFs, bad input.
# Each check runs an action and then asserts something about the result.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
source scripts/test-lib.sh
test_setup edge
q() { ffmpeg -loglevel error -y "$@"; }
probe() { ffprobe -v error -of csv=p=0 "$@"; }

echo "Fixtures in $F"
# Grainy, so Compress has something to shrink (it keeps the original when it can't).
q -f lavfi -i "testsrc=size=360x640:rate=30,noise=alls=25:allf=t" -f lavfi -i sine=r=44100 -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/portrait clip.mp4"
q -f lavfi -i testsrc=size=641x361:rate=24 -t 2 -c:v libx264 -pix_fmt yuv444p "$F/odd.mkv"
q -f lavfi -i testsrc=size=640x360:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/rot.mp4"
q -display_rotation 90 -i "$F/rot.mp4" -c copy "$F/rotated.mp4"
q -f lavfi -i "sine=r=22050" -t 4 -ac 1 "$F/mono 22k.wav"
q -f lavfi -i testsrc=size=300x300 -frames:v 1 "$F/cover.png"
q -f lavfi -i "sine=r=44100" -i "$F/cover.png" -t 4 -map 0 -map 1 -c:a libmp3lame -c:v mjpeg -disposition:v attached_pic \
  -metadata title="Song" -metadata artist="Someone" "$F/song with art.mp3"
q -f lavfi -i testsrc=size=400x300 -frames:v 1 -pix_fmt gray "$F/gray.jpg"
q -f lavfi -i testsrc=size=400x300 -frames:v 1 -pix_fmt rgb48be "$F/deep16.png"
q -f lavfi -i testsrc=size=301x201:rate=10 -t 1 "$F/odd anim.gif"
sips -s format jpeg "$F/cover.png" --out "$F/cmyk.jpg" >/dev/null && sips -m "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc" "$F/cmyk.jpg" >/dev/null 2>&1
cp "$F/cover.png" "$F/it's \"quoted\" & ünïcode.png"
cp "$F/cover.png" "$F/-dash.png"

# JPEG with EXIF orientation 6 (rotate 90° CW to display) and GPS.
cat > "$WORK/exif.swift" <<'SWIFT'
import Foundation; import ImageIO; import CoreGraphics
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, "public.jpeg" as CFString, 1, nil)!
let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
  kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                  kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
  kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "TestLens", kCGImagePropertyExifUserComment: "SecretNote",
                                   kCGImagePropertyExifBodySerialNumber: "SN12345"]]
CGImageDestinationAddImage(dest, img, props as CFDictionary); CGImageDestinationFinalize(dest)
SWIFT
q -f lavfi -i testsrc=size=400x200 -frames:v 1 "$WORK/wide.png"
swift "$WORK/exif.swift" "$WORK/wide.png" "$F/oriented.jpg"

# Multi-page PDF (5 pages) from text.
python3 -c "print('\n'.join(f'Line {i} ' + 'word ' * 12 for i in range(400)))" > "$F/long.txt"
"$BIN" --run convert.document.pdf "$F/long.txt" >/dev/null
printf '<html><body><h1>Title</h1><p>Hello <b>bold</b> world</p></body></html>' > "$F/page.html"
printf '{\\rtf1\\ansi {\\b Bold} text}' > "$F/doc.rtf"
printf '# Heading\n\nSome *markdown*.\n' > "$F/readme.md"
printf 'caf\xe9 cr\xe8me\n' > "$F/latin1.txt"
textutil -convert doc "$F/doc.rtf" -output "$F/legacy.doc" >/dev/null
cat > "$F/cues.vtt" <<'VTT'
WEBVTT
Kind: captions

NOTE a comment

intro
00:01.000 --> 00:02.500 align:start position:10%
<v Bob>Hi <c.yellow>there</c></v>

00:01:03.250 --> 00:01:04.000
Two
lines
VTT
printf '1\r\n00:00:01,000 --> 00:00:02,000\r\nWindows line endings\r\n' > "$F/crlf.srt"
mkdir -p "$F/one" && echo solo > "$F/one/solo.txt" && (cd "$F/one" && zip -q ../single.zip solo.txt)
(cd "$F" && mkdir -p "dir with space" && echo x > "dir with space/x.txt" && tar -cjf bz.tar.bz2 "dir with space")
q -f lavfi -i testsrc=size=320x240:rate=30 -f lavfi -i sine=r=48000 -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac \
  -timecode 01:00:00:00 -write_tmcd 1 -metadata com.apple.quicktime.location.ISO6709="+48.85+002.35/" "$F/iphone.mov"
echo "not really a video" > "$F/broken.mp4"
echo "not an image" > "$F/broken.jpg"
: > "$F/empty.txt"
# Text in the encodings Windows tools save: UTF-16 with a BOM (LE and BE), UTF-16 without one, Windows-1252.
utf16() { printf "$1" > "$3"; printf '%s' "$2" | iconv -f utf-8 -t "$4" >> "$3"; }
utf16 '\xff\xfe' $'Grüße 你好 “q” €\n' "$F/utf16le.txt" utf-16le
utf16 '\xfe\xff' $'Grüße 你好 “q” €\n' "$F/utf16be.txt" utf-16be
printf 'caf\xe9 \x93q\x94 \x80\n' > "$F/cp1252.txt"
CUE=$'1\r\n00:00:01,000 --> 00:00:02,000\r\nHéllo 你好\r\n'
utf16 '\xff\xfe' "$CUE" "$F/utf16le.srt" utf-16le
utf16 '\xfe\xff' "$CUE" "$F/utf16be.srt" utf-16be
utf16 '' "$CUE" "$F/utf16nobom.srt" utf-16le
printf '1\r\n00:00:01,000 --> 00:00:02,000\r\ncaf\xe9 \x93q\x94 \x80\r\n' > "$F/cp1252.srt"
mkdir -p "$F/readonly" && cp "$F/long.txt" "$F/readonly/locked.txt" && chmod 555 "$F/readonly"

# HTML that references a server in every way a page can load something. A local listener logs any request;
# converting must make none. `privacy.html` points at it, `deadhost.html` at an unroutable address.
cat > "$WORK/listener.py" <<'PY'
import http.server, sys
class Log(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[1], "a") as f: f.write(self.path + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Log)
with open(sys.argv[2], "w") as f: f.write(str(server.server_address[1]))
server.serve_forever()
PY
: > "$WORK/requests.log"
python3 -I "$WORK/listener.py" "$WORK/requests.log" "$WORK/port" & LISTENER=$!
trap 'kill $LISTENER 2>/dev/null; chmod -R u+w "$F/readonly" 2>/dev/null' EXIT
for _ in $(seq 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
remote_html() {
  local H="$1"
  cat <<HTML
<!DOCTYPE html><html><head><base href="$H/base/">
<meta http-equiv="refresh" content="0; url=$H/refresh">
<link rel="stylesheet" href="$H/link.css"><link rel=icon href=$H/icon><link rel=preload as=image href="$H/preload.png">
<style>@import url($H/import.css); @import "$H/import2.css"; body { background: url('$H/bg.png') }
p { background-image: u\72l($H/escaped.png) } @font-face { font-family: X; src: url($H/font.woff) }</style>
</head><body background="$H/bodybg">
<p style="background:url($H/inline.png)">Offline page text</p>
<img src="$H/pixel.gif"><img src=$H/unquoted.gif><img src="&#104;ttp://${H#http://}/entity.gif"><img src=" $H/space.gif">
<img srcset="$H/srcset1.png 1x, $H/srcset2.png 2x"><img src="//${H#http://}/protocol-relative.gif">
<picture><source srcset="$H/source.png"><img src="cover.png"></picture>
<iframe src="$H/iframe.html"></iframe><iframe srcdoc="<img src=$H/srcdoc.gif>"></iframe>
<object data="$H/object.swf"></object><embed src="$H/embed"><frameset><frame src="$H/frame.html"></frameset>
<video poster="$H/poster.png" src="$H/video.mp4"><source src="$H/video-source.mp4"></video><audio src="$H/audio.mp3"></audio>
<svg><image href="$H/svg-image.png"/><image xlink:href="$H/svg-xlink.png"/><rect fill="url($H/svg-fill#g)"/></svg>
<!-- a comment with a ' quote --><img src="$H/after-comment.gif">
<noscript><img src="$H/noscript.gif"></noscript><script>new Image().src = "$H/script.gif"</script>
<table background="$H/table-bg"><tr><td>cell</td></tr></table><input type=image src="$H/input.png">
<a href="$H/link">a link</a>
</body></html>
HTML
}
remote_html "http://127.0.0.1:$(cat "$WORK/port")" > "$F/privacy.html"
remote_html "http://10.255.255.1" > "$F/deadhost.html"
cat > "$WORK/pdfsize.swift" <<'SWIFT'
import AppKit; import PDFKit
let page = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!.page(at: 0)!.bounds(for: .mediaBox).size
let paper = NSPrintInfo.shared.paperSize
print(abs(page.width - paper.width) < 1 && abs(page.height - paper.height) < 1 ? "ok \(page)" : "page \(page) vs paper \(paper)")
SWIFT
# Names that look like tar/zip options; archived members must stay plain paths. "PWNED" appearing anywhere means
# a name was run as an option.
mkdir -p "$F/dash" "$F/repack"
for n in -m -T.txt "--use-compress-program=touch PWNED"; do echo "$n" > "$F/dash/$n"; done
(cd "$F/dash" && tar -cf ../repack/odd.tar -- ./-m ./-T.txt "./--use-compress-program=touch PWNED")
(cd "$F/dash" && tar -c --format zip -f ../repack/odd.zip -- ./-m ./-T.txt "./--use-compress-program=touch PWNED")
# Links that point out of the archive must not be extracted; a link to a sibling is fine.
mkdir -p "$F/links" && (cd "$F/links" && echo real > real.txt && ln -s /etc/hosts innocent.txt && ln -s ../../outside.txt up \
  && ln -s real.txt ok && ln -s . self && ln -s self/.. via-self && tar -cf ../links.tar real.txt innocent.txt up ok self via-self)
rm -rf "$F/links"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }

# expect <name> <assertion-command…> -- <action args…>: action must succeed and the assertion (given $OUT) must pass.
expect() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out
  # Output paths come from stdout only: system frameworks sometimes log noise to stderr (e.g. on CI VMs).
  local err; err="$(mktemp "$WORK/err.XXXXXX")"
  if ! out="$("$BIN" --run "$@" 2>"$err")"; then bad "$name" "$(cat "$err") $out"; rm -f "$err"; return; fi
  rm -f "$err"
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
dims() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{printf "%s ", $2}' | sed 's/ $//'; }
vdims() { probe -select_streams v:0 -show_entries stream=width,height "$1" | head -1; }
dur() { probe -show_entries format=duration "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.3}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }

echo "Names"
expect "quotes/unicode name → jpg" '[[ -f "$OUT" && "$OUT" == *code.jpg ]]' -- convert.image.jpeg "$F/it's \"quoted\" & ünïcode.png"
expect "leading dash name → webp" '[[ -f "$OUT" ]]' -- convert.image.webp "$F/-dash.png"
expect "spaces → video compress" '[[ -f "$OUT" ]]' -- tool.compress "$F/portrait clip.mp4"

echo "Video"
expect "portrait compress keeps orientation" '[[ "$(vdims "$OUT")" == "360,640" ]]' -- tool.compress --set level=2 "$F/portrait clip.mp4"
expect "portrait fit stays portrait" '[[ $(vdims "$OUT" | cut -d, -f1) -lt $(vdims "$OUT" | cut -d, -f2) ]]' -- tool.fit --set megabytes=0.1 "$F/portrait clip.mp4"
expect "odd size → mp4" '[[ -f "$OUT" ]]' -- convert.media.mp4 "$F/odd.mkv"
expect "odd size → webm" '[[ -f "$OUT" ]]' -- convert.media.webm "$F/odd.mkv"
expect "odd size → wmv" '[[ -f "$OUT" ]]' -- convert.media.wmv "$F/odd.mkv"
expect "odd size → gif" '[[ -f "$OUT" ]]' -- convert.media.gif "$F/odd.mkv"
expect "rotated video → mov upright" '[[ "$(vdims "$OUT")" == "360,640" ]]' -- convert.media.mov "$F/rotated.mp4"
expect "rotated video snapshot upright" '[[ "$(dims "$OUT")" == "360 640" ]]' -- tool.video.snapshot "$F/rotated.mp4"
expect_error "silent video → mp3 explains" "no audio track" -- convert.media.mp3 "$F/rot.mp4"
expect "silent video speed" '[[ -f "$OUT" ]]' -- tool.media.speed "$F/rot.mp4"
expect "silent video fit" '[[ -f "$OUT" && $(stat -f%z "$OUT") -le 100000 ]]' -- tool.fit --set megabytes=0.1 "$F/rot.mp4"
expect "trim end past duration" 'near "$(dur "$OUT")" 2.0' -- tool.media.trim --set start=1 --set end=99 "$F/portrait clip.mp4"
expect_error "trim start past end of file" "after" -- tool.media.trim --set start=50 "$F/portrait clip.mp4"
expect_error "trim garbage time" "time" -- tool.media.trim --set start=abc "$F/portrait clip.mp4"
expect "snapshot -> 10 frames folder" '[[ $(ls "$OUT" | wc -l) -eq 10 ]]' -- tool.video.snapshot --set frames=2 "$F/portrait clip.mp4"
expect "join portrait + odd" 'near "$(dur "$OUT")" 5.0 0.4' -- tool.video.join "$F/portrait clip.mp4" "$F/odd.mkv"
expect "video rotate 180 keeps size" '[[ "$(vdims "$OUT")" == "360,640" ]]' -- tool.video.rotate --set rotation=2 "$F/portrait clip.mp4"
expect "iPhone-style mov (timecode track) strip metadata" '! ffprobe -v error -show_entries format_tags -of csv=p=0 "$OUT" | grep -q 48.85' -- tool.metadata.strip "$F/iphone.mov"
expect "iPhone-style mov split" '[[ -d "$OUT" && $(ls "$OUT" | wc -l) -ge 1 ]]' -- tool.media.split --set seconds=1 "$F/iphone.mov"
expect_error "broken video" "broken.mp4" -- convert.media.mov "$F/broken.mp4"

echo "Audio"
expect "mp3 with art → m4a" '[[ -f "$OUT" ]]' -- convert.media.m4a "$F/song with art.mp3"
expect "mp3 with art → flac" '[[ -f "$OUT" ]]' -- convert.media.flac "$F/song with art.mp3"
expect "mp3 with art → ogg" '[[ -f "$OUT" ]]' -- convert.media.ogg "$F/song with art.mp3"
expect "mp3 with art trim" 'near "$(dur "$OUT")" 2.0' -- tool.media.trim --set start=1 --set end=3 "$F/song with art.mp3"
expect "mp3 with art speed" 'near "$(dur "$OUT")" 2.0' -- tool.media.speed "$F/song with art.mp3"
expect "mp3 with art normalize" '[[ -f "$OUT" ]]' -- tool.audio.normalize "$F/song with art.mp3"
expect "mp3 with art split" '[[ $(ls "$OUT" | wc -l) -ge 2 ]]' -- tool.media.split --set seconds=2 "$F/song with art.mp3"
expect "mp3 with art fit" '[[ $(stat -f%z "$OUT") -le 30000 ]]' -- tool.fit --set megabytes=0.03 "$F/song with art.mp3"
expect "mp3 with art compress" '[[ -f "$OUT" ]]' -- tool.compress --set level=2 "$F/song with art.mp3"
expect "mp3 strip metadata removes tags" '! ffprobe -v error -show_entries format_tags -of csv=p=0 "$OUT" | grep -q Someone' -- tool.metadata.strip "$F/song with art.mp3"
expect "metadata shows artist" '[[ "$("$BIN" --run tool.metadata "$F/song with art.mp3")" == *Someone* ]]' -- tool.metadata "$F/song with art.mp3"
expect "mono bleep" '[[ -f "$OUT" ]]' -- tool.audio.bleep --set ranges=1-2 "$F/mono 22k.wav"
expect_error "bleep bad ranges" "ranges" -- tool.audio.bleep --set ranges=nonsense "$F/mono 22k.wav"
expect "mono → stereo" '[[ "$(probe -show_entries stream=channels "$OUT")" == "2" ]]' -- tool.audio.channels --set channels=1 "$F/mono 22k.wav"
expect "join mono22k + mp3 w/ art" 'near "$(dur "$OUT")" 8.0' -- tool.audio.join "$F/mono 22k.wav" "$F/song with art.mp3"
expect "speed 4x" 'near "$(dur "$OUT")" 1.0' -- tool.media.speed --set speed=7 "$F/mono 22k.wav"
expect "speed 0.25x" 'near "$(dur "$OUT")" 16.0 0.5' -- tool.media.speed --set speed=0 "$F/mono 22k.wav"

echo "Images"
expect "EXIF-rotated jpg → png upright" '[[ "$(dims "$OUT")" == "200 400" ]]' -- convert.image.png "$F/oriented.jpg"
expect "EXIF-rotated compress upright & no double-rotate" '[[ "$(dims "$OUT")" == "200 400" && "$(sips -g orientation "$OUT" | awk "/orientation/{print \$2}")" != "6" ]]' -- tool.compress "$F/oriented.jpg"
expect "redact drops GPS, serial and comment" '"$BIN" --run tool.metadata "$OUT" > "$WORK/redact-meta.txt" && ! grep -qiE "GPS|Latitude|SN12345|SecretNote" "$WORK/redact-meta.txt" && grep -q TestLens "$WORK/redact-meta.txt" && [[ "$(dims "$OUT")" == "200 400" ]]' -- tool.image.redact --set 'boxes=[{"x":0,"y":0,"w":20,"h":20}]' "$F/oriented.jpg"
expect "redact output has no GPS bytes" '! strings "$OUT" | grep -qE "SN12345|SecretNote" && [[ "$(sips -g all "$OUT" | grep -ci gps)" == 0 ]]' -- tool.image.redact --set 'boxes=[{"x":0,"y":0,"w":20,"h":20}]' --set style=black "$F/oriented.jpg"
expect "compress keeps GPS on purpose" '"$BIN" --run tool.metadata "$OUT" | grep -q "Latitude: 48.85"' -- tool.compress "$F/oriented.jpg"
expect "strip removes GPS + lens" '! "$BIN" --run tool.metadata "$OUT" | grep -qiE "GPS|TestLens"' -- tool.metadata.strip "$F/oriented.jpg"
expect "crop on rotated image is square" '[[ "$(dims "$OUT")" == "200 200" ]]' -- tool.image.crop "$F/oriented.jpg"
expect "grayscale → heic" '[[ -f "$OUT" ]]' -- convert.image.heic "$F/gray.jpg"
expect "grayscale adjust" '[[ -f "$OUT" ]]' -- tool.image.adjust --set saturation=0.5 "$F/gray.jpg"
expect "grayscale resize" '[[ "$(dims "$OUT")" == "200 150" ]]' -- tool.image.resize "$F/gray.jpg"
expect "cmyk → png" '[[ -f "$OUT" ]]' -- convert.image.png "$F/cmyk.jpg"
expect "cmyk rotate" '[[ -f "$OUT" ]]' -- tool.image.rotate "$F/cmyk.jpg"
expect "16-bit png → jpg" '[[ -f "$OUT" ]]' -- convert.image.jpeg "$F/deep16.png"
expect "16-bit png resize" '[[ -f "$OUT" ]]' -- tool.image.resize "$F/deep16.png"
expect "odd gif → mp4" '[[ -f "$OUT" ]]' -- convert.image.mp4 "$F/odd anim.gif"
expect "gif → webp" '[[ -f "$OUT" ]]' -- convert.image.webp "$F/odd anim.gif"
expect "webp compress stays webp" '[[ "$OUT" == *.webp ]]' -- tool.compress "$WORK/fixtures/-dash.webp"
expect "fit bigger than file" '[[ -f "$OUT" ]]' -- tool.fit --set megabytes=100 "$F/cover.png"
expect_error "fit impossibly small" "under" -- tool.fit --set megabytes=0.0001 "$F/cover.png"
expect_error "broken image" "broken.jpg" -- convert.image.png "$F/broken.jpg"
expect "collage mixed sizes + rotated" '[[ -f "$OUT" ]]' -- tool.image.collage --set layout=2 "$F/oriented.jpg" "$F/gray.jpg" "$F/cmyk.jpg"
expect "QR none found is a message" '[[ "$("$BIN" --run tool.image.qr "$F/gray.jpg")" == *"No QR"* ]]' -- tool.image.qr "$F/gray.jpg"

echo "Documents & PDF"
expect "long txt → pdf has >1 page" '[[ "$("$BIN" --run tool.metadata "$F/long.pdf" | sed -n 2p)" != "Pages: 1" ]]' -- convert.document.docx "$F/long.txt"
expect "html → pdf" '[[ -f "$OUT" ]]' -- convert.document.pdf "$F/page.html"
expect "html → txt keeps text" 'grep -q "bold world" "$OUT"' -- convert.document.txt "$F/page.html"
expect "rtf → docx" '[[ -f "$OUT" ]]' -- convert.document.docx "$F/doc.rtf"
expect "doc → txt" 'grep -q "Bold text" "$OUT"' -- convert.document.txt "$F/legacy.doc"
expect "md → pdf" '[[ -f "$OUT" ]]' -- convert.document.pdf "$F/readme.md"
expect "latin1 txt → docx → txt keeps accents" '[[ -f "$OUT" ]] && "$BIN" --run convert.document.txt "$OUT" | xargs -I{} grep -q "café" "{}"' -- convert.document.docx "$F/latin1.txt"
expect "empty txt → pdf" '[[ -f "$OUT" ]]' -- convert.document.pdf "$F/empty.txt"
expect "txt → pdf uses the system paper size" '[[ "$(swift "$WORK/pdfsize.swift" "$OUT")" == ok* ]]' -- convert.document.pdf "$F/readme.md"
roundtrip() { cat "$("$BIN" --run convert.document.txt "$1")"; }
expect "utf-16le txt (BOM) → rtf keeps text" '[[ "$(roundtrip "$OUT")" == "Grüße 你好 “q” €" ]]' -- convert.document.rtf "$F/utf16le.txt"
expect "utf-16be txt (BOM) → rtf keeps text" '[[ "$(roundtrip "$OUT")" == "Grüße 你好 “q” €" ]]' -- convert.document.rtf "$F/utf16be.txt"
expect "windows-1252 txt → rtf keeps text" '[[ "$(roundtrip "$OUT")" == "café “q” €" ]]' -- convert.document.rtf "$F/cp1252.txt"

# Read-only folder: must fail fast with a message (the print panel used to hang on a modal alert), leaving nothing.
started=$(python3 -c 'import time; print(time.time())')
if out="$("$BIN" --run convert.document.pdf "$F/readonly/locked.txt" 2>&1)"; then
  bad "pdf into read-only folder fails" "succeeded: $out"
elif ! awk -v a="$started" -v b="$(python3 -c 'import time; print(time.time())')" 'BEGIN{exit !(b-a < 5)}'; then
  bad "pdf into read-only folder fails" "took longer than 5 s"
elif [[ "$(ls -A "$F/readonly")" != "locked.txt" || "$out" != *"isn't writable"* ]]; then
  bad "pdf into read-only folder fails" "left files or unclear message: $(ls -A "$F/readonly") / $out"
else
  ok "pdf into read-only folder fails fast and leaves nothing"
fi

# Privacy: HTML import must never touch the network.
for target in pdf txt docx rtf; do
  expect "html → $target makes no network requests" '[[ ! -s "$WORK/requests.log" ]]' -- convert.document.$target "$F/privacy.html"
done
expect "html → txt keeps the text" 'grep -q "Offline page text" "$OUT" && grep -q "a link" "$OUT"' -- convert.document.txt "$F/privacy.html"
expect "html → pdf keeps local images" '[[ $(grep -ac "/Subtype /Image" "$OUT") -ge 1 ]]' -- convert.document.pdf "$F/privacy.html"
[[ -s "$WORK/requests.log" ]] && echo "    requests made: $(tr '\n' ' ' < "$WORK/requests.log")"
for target in pdf txt; do
  started=$(python3 -c 'import time; print(time.time())')
  expect "html with unreachable host → $target is quick" 'awk -v a="$started" -v b="$(python3 -c "import time; print(time.time())")" "BEGIN{exit !(b-a < 5)}"' -- convert.document.$target "$F/deadhost.html"
done
expect "multi-page pdf → png folder" '[[ -d "$OUT" && $(ls "$OUT" | wc -l) -gt 1 ]]' -- convert.pdf.png "$F/long.pdf"
expect "pages 3-1 reversed" '[[ "$("$BIN" --run tool.metadata "$OUT" | sed -n 2p)" == "Pages: 3" ]]' -- tool.pdf.pages --set pages=3-1 "$F/long.pdf"
expect "pages open-ended 2-" '[[ -f "$OUT" ]]' -- tool.pdf.pages --set pages=2- "$F/long.pdf"
expect_error "pages out of range" "doesn't exist" -- tool.pdf.pages --set pages=99 "$F/long.pdf"
expect_error "pages empty" "pages" -- tool.pdf.pages --set pages= "$F/long.pdf"
expect "pages with spaces around dash" '[[ "$("$BIN" --run tool.metadata "$OUT" | sed -n 2p)" == "Pages: 3" ]]' -- tool.pdf.pages --set "pages=1 - 3" "$F/long.pdf"
expect "pages open start -2" '[[ "$("$BIN" --run tool.metadata "$OUT" | sed -n 2p)" == "Pages: 2" ]]' -- tool.pdf.pages --set pages=-2 "$F/long.pdf"
expect "split multi-page" '[[ $(ls "$OUT" | wc -l) -gt 1 ]]' -- tool.pdf.split "$F/long.pdf"
expect "rotate twice composes" '[[ -f "$OUT" ]]' -- tool.pdf.rotate --set rotation=2 "$F/long.pdf"
expect "image pdf → txt says scan" '[[ 1 ]]' -- convert.pdf.jpeg "$F/long.pdf"

echo "Subtitles"
expect "vtt with header/NOTE/settings/voice → srt" 'grep -q "^Hi there$" "$OUT" && grep -q "00:01:03,250 --> 00:01:04,000" "$OUT" && grep -q "00:00:01,000 --> 00:00:02,500$" "$OUT" && ! grep -q NOTE "$OUT"' -- convert.subtitle.srt "$F/cues.vtt"
expect "crlf srt → vtt" '! grep -q $'"'"'\r'"'"' "$OUT" && grep -q "00:00:01.000" "$OUT"' -- convert.subtitle.vtt "$F/crlf.srt"
expect "utf-16le srt (BOM) → vtt" 'grep -q "00:00:01.000 --> 00:00:02.000" "$OUT" && grep -q "Héllo 你好" "$OUT"' -- convert.subtitle.vtt "$F/utf16le.srt"
expect "utf-16be srt (BOM) → vtt" 'grep -q "00:00:01.000 --> 00:00:02.000" "$OUT" && grep -q "Héllo 你好" "$OUT"' -- convert.subtitle.vtt "$F/utf16be.srt"
expect "utf-16le srt (no BOM) → vtt" 'grep -q "Héllo 你好" "$OUT"' -- convert.subtitle.vtt "$F/utf16nobom.srt"
expect "windows-1252 srt → vtt" 'grep -q "café “q” €" "$OUT"' -- convert.subtitle.vtt "$F/cp1252.srt"

echo "Archives"
expect "single-file zip extracts the file, not a folder" '[[ -f "$OUT" && "$(basename "$OUT")" == solo*.txt ]]' -- convert.archive.extract "$F/single.zip"
expect "tar.bz2 extract with spaces" '[[ -d "$OUT" && -f "$OUT/x.txt" ]]' -- convert.archive.extract "$F/bz.tar.bz2"
expect "tar.bz2 → zip name" '[[ "$(basename "$OUT")" == "bz.zip" ]]' -- convert.archive.zip "$F/bz.tar.bz2"
# grep without -q reads all of tar's output, so pipefail can't trip on SIGPIPE.
expect "tar.bz2 → gzip is bz.tar.gz with the folder" '[[ "$(basename "$OUT")" == "bz.tar.gz" ]] && tar -tzf "$OUT" | grep -x "dir with space/x.txt" >/dev/null' -- convert.archive.gzip "$F/bz.tar.bz2"
expect "single-file zip → gzip of that file" '[[ "$(basename "$OUT")" == solo*.txt.gz && "$(gzip -dc "$OUT")" == solo ]]' -- convert.archive.gzip "$F/single.zip"
expect "zip folder with spaces" 'unzip -Z1 "$OUT" | grep -qx "dir with space/x.txt"' -- archive.zip "$F/dir with space"
expect "zip from different folders stores plain names" '[[ "$(unzip -Z1 "$OUT" | sort | tr "\n" " ")" == "cover.png solo.txt " ]]' -- archive.zip "$F/cover.png" "$F/one/solo.txt"
expect "tar from different folders stores plain names" '[[ "$(tar -tf "$OUT" | sort | tr "\n" " ")" == "cover.png solo.txt " ]]' -- archive.tar "$F/cover.png" "$F/one/solo.txt"
expect "no staging folders left behind" '! ls -a "$F" | grep -q "Being Saved"' -- archive.gzip "$F/cover.png" "$F/one/solo.txt"
expect_error "extract non-archive" "tar" -- convert.archive.extract "$F/broken.mp4"

DASH_NAMES='--use-compress-program=touch PWNED -T.txt -m '
names_are() { [[ "$(cat | grep -v '/$' | LC_ALL=C sort | tr '\n' ' ')" == "$DASH_NAMES" ]]; }
untouched() { [[ ! -e PWNED && -z "$(find "$WORK" -name PWNED)" && -f "$F/dash/-m" && -f "$F/dash/-T.txt" && -f "$F/dash/--use-compress-program=touch PWNED" ]]; }
DASH=("$F/dash/-m" "$F/dash/-T.txt" "$F/dash/--use-compress-program=touch PWNED")
expect "option-like names → zip as plain names" 'unzip -Z1 "$OUT" | names_are && untouched' -- archive.zip "${DASH[@]}"
expect "option-like names → tar as plain names" 'tar -tf "$OUT" | names_are && untouched' -- archive.tar "${DASH[@]}"
expect "option-like names → tar.gz as plain names" 'tar -tzf "$OUT" | names_are && untouched' -- archive.gzip "${DASH[@]}"
expect "repack tar with option-like members → zip" 'unzip -Z1 "$OUT" | names_are && untouched' -- convert.archive.zip "$F/repack/odd.tar"
expect "repack zip with option-like members → tar" 'tar -tf "$OUT" | names_are && untouched' -- convert.archive.tar "$F/repack/odd.zip"
expect "repack zip with option-like members → tar.gz" 'tar -tzf "$OUT" | names_are && untouched' -- convert.archive.gzip "$F/repack/odd.zip"
expect "extract drops links that leave the archive" '[[ -f "$OUT/real.txt" && -L "$OUT/ok" && ! -e "$OUT/innocent.txt" && ! -L "$OUT/innocent.txt" && ! -L "$OUT/up" && ! -L "$OUT/self" && ! -L "$OUT/via-self" ]]' -- convert.archive.extract "$F/links.tar"
expect "zip marks non-ASCII names as UTF-8" 'python3 -I -c "import sys,zipfile; i=zipfile.ZipFile(sys.argv[1]).infolist(); sys.exit(0 if i and all(e.flag_bits & 0x800 for e in i) else 1)" "$OUT"' -- archive.zip "$F/it's \"quoted\" & ünïcode.png"
rm -f PWNED

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
