#!/usr/bin/env bash
# Adversarial cases beyond smoke-test.sh / edge-test.sh: timecode/data tracks, subtitles in containers,
# multiple audio tracks, tiny/huge/1x1 media, alpha & wide-gamut images, animations, locked/rotated/cropped PDFs,
# 0-byte and extension-less files, uppercase extensions, dotted folder names, archive naming, odd parameter values.
# Every case asserts something about the result; failure cases also assert nothing is left behind.
set -uo pipefail
cd "$(dirname "$0")/.."

for i in 1 2 3 4 5; do swift build -q 2>/dev/null && break; echo "build failed, retrying in 30s"; sleep 30; done
BIN="$(swift build --show-bin-path)/Clementine"
[[ -x "$BIN" ]] || { echo "no binary"; exit 1; }
WORK="$(mktemp -d /tmp/clementine-stress.XXXXXX)"
F="$WORK/fixtures"
mkdir -p "$F"
q() { ffmpeg -loglevel error -y "$@"; }
probe() { ffprobe -v error -of csv=p=0 "$@"; }

# ---------------------------------------------------------------- helper (ImageIO / PDFKit)
cat > "$WORK/h.swift" <<'SWIFT'
import Foundation; import ImageIO; import CoreGraphics; import PDFKit; import AppKit
let args = CommandLine.arguments
func url(_ p: String) -> URL { URL(fileURLWithPath: p) }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func ctx(_ w: Int, _ h: Int, _ space: CGColorSpace, _ info: CGImageAlphaInfo = .premultipliedLast) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info.rawValue)!
}
func save(_ img: CGImage, _ path: String, _ type: String) {
    let d = CGImageDestinationCreateWithURL(url(path) as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); guard CGImageDestinationFinalize(d) else { fail("finalize \(path)") }
}
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
switch args[1] {
case "info": // width height alpha frames profile
    guard let src = CGImageSourceCreateWithURL(url(args[2]) as CFURL, nil), CGImageSourceGetCount(src) > 0,
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("unreadable") }
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    var alpha = true
    switch img.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: alpha = false; default: break }
    let prof = (p[kCGImagePropertyProfileName] as? String) ?? (img.colorSpace?.name as String? ?? "?")
    print("\(img.width) \(img.height) \(alpha ? 1 : 0) \(CGImageSourceGetCount(src)) \(prof.replacingOccurrences(of: " ", with: "_"))")
case "pix": // pix file x y → r g b a (top-left origin, sRGB)
    guard let src = CGImageSourceCreateWithURL(url(args[2]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("unreadable") }
    let c = ctx(img.width, img.height, srgb)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let o = Int(args[4])! * c.bytesPerRow + Int(args[3])! * 4
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    print("\(d[o]) \(d[o+1]) \(d[o+2]) \(d[o+3])")
case "alpha": // 200x100: left half opaque red, right half transparent
    let c = ctx(200, 100, srgb)
    c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    save(c.makeImage()!, args[2], args[3])
case "p3":
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let c = ctx(300, 200, p3, .noneSkipLast)
    c.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    save(c.makeImage()!, args[2], args[3])
case "solid": // solid w h out type
    let w = Int(args[2])!, h = Int(args[3])!
    let c = ctx(w, h, srgb, .noneSkipLast)
    c.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: max(w / 3, 1), height: max(h / 3, 1)))
    save(c.makeImage()!, args[4], args[5])
case "pdf-text": // pdf-text out n
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let c = CGContext(url(args[2]) as CFURL, mediaBox: &box, nil)!
    for i in 0..<Int(args[3])! {
        c.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(i + 1) hello", attributes: [.font: NSFont.systemFont(ofSize: 36)]))
        c.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(line, c)
        c.endPDFPage()
    }
    c.closePDF()
case "pdf-rotate": // in out degrees pageIndex
    let d = PDFDocument(url: url(args[2]))!
    d.page(at: Int(args[5])!)!.rotation = Int(args[4])!
    guard d.write(to: url(args[3])) else { fail("write") }
case "pdf-crop":
    let d = PDFDocument(url: url(args[2]))!
    for i in 0..<d.pageCount { d.page(at: i)!.setBounds(CGRect(x: 100, y: 100, width: 300, height: 200), for: .cropBox) }
    guard d.write(to: url(args[3])) else { fail("write") }
case "pdf-lock": // in out user owner
    let d = PDFDocument(url: url(args[2]))!
    var o: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: args[5]]
    if !args[4].isEmpty { o[.userPasswordOption] = args[4] }
    guard d.write(to: url(args[3]), withOptions: o) else { fail("write") }
case "pdfinfo": // pages locked encrypted | rotation WxH(cropBox, as displayed) text-of-page-1
    guard let d = PDFDocument(url: url(args[2])) else { fail("unreadable") }
    var s = "\(d.pageCount) \(d.isLocked ? 1 : 0) \(d.isEncrypted ? 1 : 0)"
    if !d.isLocked, let p = d.page(at: 0) {
        let b = p.bounds(for: .cropBox); let q = p.rotation % 180 != 0
        s += " \(p.rotation) \(Int(q ? b.height : b.width))x\(Int(q ? b.width : b.height)) "
        s += (p.string ?? "").replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: " ", with: "_")
    }
    print(s)
default: fail("unknown")
}
SWIFT
swiftc -O "$WORK/h.swift" -o "$WORK/h" 2>/dev/null || { echo "helper build failed"; exit 1; }
H="$WORK/h"

# ---------------------------------------------------------------- fixtures
echo "Fixtures in $F"
# Video
q -f lavfi -i testsrc=size=640x360:rate=30 -f lavfi -i sine=r=48000 -t 3 -c:v libx264 -g 30 -pix_fmt yuv420p -c:a aac \
  -timecode 01:00:00:00 -metadata location="+48.8500+002.3500/" -metadata "make=Apple" "$F/iphone.mov"
printf '1\n00:00:00,500 --> 00:00:01,500\nHello\n\n2\n00:00:02,000 --> 00:00:02,800\nWorld\n' > "$F/s.srt"
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine -i "$F/s.srt" -t 3 -map 0 -map 1 -map 2 -c:v libx264 -g 25 -pix_fmt yuv420p -c:a aac -c:s srt "$F/subs.mkv"
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine -i "$F/s.srt" -t 3 -map 0 -map 1 -map 2 -c:v libx264 -g 25 -pix_fmt yuv420p -c:a aac -c:s mov_text "$F/subs.mp4"
q -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine=f=440 -f lavfi -i sine=f=880 -t 3 -map 0 -map 1 -map 2 -c:v libx264 -pix_fmt yuv420p -c:a aac \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra "$F/two audio.mkv"
q -f lavfi -i testsrc=size=320x240:rate=30 -f lavfi -i sine -t 0.1 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/tiny.mp4"
q -f lavfi -i testsrc=size=641x361:rate=24 -t 2 -c:v libx264 -pix_fmt yuv444p "$F/odd wide.mkv"
q -f lavfi -i testsrc=size=361x641:rate=24 -t 2 -c:v libx264 -pix_fmt yuv444p "$F/odd tall.mkv"
q -f lavfi -i sine -t 2 -c:a aac "$F/audio only.mp4"
q -f lavfi -i testsrc=size=320x240:rate=30 -f lavfi -i sine -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/clip.mp4"
cp "$F/clip.mp4" "$F/CLIP.MOV"
# Audio
q -f lavfi -i "sine=f=300:r=44100" -t 2 -ac 2 "$F/a.wav"
q -f lavfi -i "sine=f=500:r=44100" -t 2 -c:a libmp3lame "$F/b.mp3"
q -f lavfi -i "sine=f=700:r=96000" -t 2 -ac 1 -c:a flac "$F/c.flac"
q -f lavfi -i "sine=f=400:r=8000" -t 100 -ac 1 -c:a libmp3lame -b:a 32k "$F/long.mp3"
q -f lavfi -i "sine=r=44100" -t 3 -c:a aac -b:a 96k "$F/song.m4a"
cp "$F/b.mp3" "$F/SONG.MP3"
# Images
"$H" solid 12000 8000 "$F/huge.jpg" public.jpeg
"$H" solid 1 1 "$F/one.png" public.png
"$H" alpha "$F/alpha.png" public.png
"$H" alpha "$F/alpha.heic" public.heic
"$H" p3 "$F/p3.png" public.png
"$H" p3 "$F/p3.jpg" public.jpeg
"$H" solid 400 300 "$F/PHOTO.JPG" public.jpeg
q -f lavfi -i testsrc=size=200x150:rate=10 -t 1 "$F/anim.gif"
gif2webp -quiet "$F/anim.gif" -o "$F/anim.webp" 2>/dev/null
mkdir -p "$F/grid" "$F/pano"
for i in 0 1 2 3 4 5 6 7 8 9; do
  "$H" solid 640 480 "$F/grid/g$i.jpg" public.jpeg
  "$H" solid 1600 200 "$F/pano/p$i.jpg" public.jpeg
done
cp "$F/PHOTO.JPG" "$F/photo_noext"
# PDFs
"$H" pdf-text "$F/three.pdf" 3
"$H" pdf-text "$F/one page.pdf" 1
"$H" pdf-rotate "$F/one page.pdf" "$F/rotated.pdf" 90 0
"$H" pdf-crop "$F/one page.pdf" "$F/cropped.pdf"
"$H" pdf-lock "$F/three.pdf" "$F/locked.pdf" secret owner
"$H" pdf-lock "$F/three.pdf" "$F/owner only.pdf" "" owner
# 0-byte
mkdir -p "$F/zero"
for e in jpg png mp4 mov mp3 wav pdf zip gz docx srt; do : > "$F/zero/empty.$e"; done
# Folders with dots
mkdir -p "$F/dirs/Vacation.mov" "$F/dirs/photos.2024" "$F/dirs/backup.zip" "$F/dirs/Thing.app"
for d in "$F/dirs/"*; do echo hi > "$d/inside.txt"; done
# Archives
mkdir -p "$F/arc/src/proj/sub" && echo one > "$F/arc/src/proj/a.txt" && echo two > "$F/arc/src/proj/sub/b.txt"
(cd "$F/arc/src" && zip -qr ../singlefolder.zip proj)
mkdir -p "$F/arc/uni/café" && echo bonjour > "$F/arc/uni/café/naïve ü.txt" && echo hi > "$F/arc/uni/日本.txt"
(cd "$F/arc/uni" && zip -qr ../unicode.zip . -x '.*')
(cd "$F/arc/uni" && ditto -c -k --sequesterRsrc --keepParent "café" ../ditto.zip)
(cd "$F/arc/src" && tar -czf inner.tar.gz proj && echo readme > README && tar -czf ../nested.tar.gz inner.tar.gz README && rm inner.tar.gz README)
echo "plain text" > "$F/arc/notes.txt" && gzip -k "$F/arc/notes.txt" && bzip2 -k "$F/arc/notes.txt" && mv "$F/arc/notes.txt" "$F/arc/notes-orig.txt"
echo "data" > "$F/arc/a.txt" && gzip -kf "$F/arc/a.txt"   # a.txt + a.txt.gz exist
(cd "$F/arc/src" && tar -czf ../proj.tgz proj)

# ---------------------------------------------------------------- harness
pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$(echo "$2" | head -c 600)"; }
# expect <name> <assertion…> -- <action args…>: action succeeds and the assertion (with $OUT = first output line, $ALL = all) holds.
expect() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out
  # Output paths come from stdout only: system frameworks sometimes log noise to stderr (e.g. on CI VMs).
  local err; err="$(mktemp)"
  if ! out="$("$BIN" --run "$@" 2>"$err")"; then bad "$name" "$(cat "$err") $out"; rm -f "$err"; return; fi
  rm -f "$err"
  OUT="$(echo "$out" | head -1)"; ALL="$out"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} (output: $out)"; fi
}
# expect_error <name> <substring> -- <action args…>: fails with a readable message containing substring
# (case-insensitive), not raw tool output, and leaves nothing new in the input folders.
expect_error() {
  local name="$1" needle="$2"; shift 3
  local dirs=() a; for a in "$@"; do [[ -e "$a" ]] && dirs+=("$(dirname "$a")"); done
  local before after out; before="$(for d in "${dirs[@]}"; do ls -A "$d"; done | sort)"
  if out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  after="$(for d in "${dirs[@]}"; do ls -A "$d"; done | sort)"
  if [[ "$before" != "$after" ]]; then bad "$name" "left behind: $(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ') ($out)"; return; fi
  shopt -s nocasematch
  if [[ "$out" != *"$needle"* ]]; then shopt -u nocasematch; bad "$name" "unexpected message: $out"; return; fi
  shopt -u nocasematch
  if [[ "$out" == *"ffmpeg failed"* || "$out" == *"ffprobe failed"* || "$out" == *"tar failed"* || "$out" == *"gzip failed"* ]]; then
    bad "$name" "raw tool error: $out"; return
  fi
  ok "$name"
}
# expect_list <name> <assertion on $LIST> -- <files…>
expect_list() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  LIST="$("$BIN" --list "$@" 2>&1)"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} — list: $(echo "$LIST" | awk '{print $1}' | tr '\n' ' ')"; fi
}
has() { grep -qE "^  $1 " <<<"$LIST"; }
dims() { "$H" info "$1" | cut -d' ' -f1,2; }
alpha() { "$H" info "$1" | cut -d' ' -f3; }
frames() { "$H" info "$1" | cut -d' ' -f4; }
profile() { "$H" info "$1" | cut -d' ' -f5; }
pix() { "$H" pix "$@"; }
pdfi() { "$H" pdfinfo "$1"; }
vdims() { probe -select_streams v:0 -show_entries stream=width,height "$1" | head -1; }
dur() { probe -show_entries format=duration "$1"; }
nstreams() { probe -select_streams "$2" -show_entries stream=index "$1" | wc -l | tr -d ' '; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.3}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
size() { stat -f%z "$1"; }

# ---------------------------------------------------------------- cases
echo "iPhone-style MOV (timecode + location)"
expect "strip keeps a/v, drops location"  '[[ $(nstreams "$OUT" v) == 1 && $(nstreams "$OUT" a) == 1 ]] && ! ffprobe -v error -show_entries format_tags "$OUT" | grep -q 48.85' -- tool.metadata.strip "$F/iphone.mov"
expect "split 1s → ≥3 parts, all playable" '[[ $(ls "$OUT" | wc -l) -ge 2 ]] && for p in "$OUT"/*; do [[ $(nstreams "$p" v) == 1 ]] || exit 1; done' -- tool.media.split --set seconds=1 "$F/iphone.mov"
expect "trim → mov ~1s" 'near "$(dur "$OUT")" 1.0' -- tool.media.trim --set start=1 --set end=2 "$F/iphone.mov"
expect "mute keeps video only" '[[ $(nstreams "$OUT" a) == 0 && $(nstreams "$OUT" v) == 1 ]]' -- tool.video.mute "$F/iphone.mov"
expect "→ mp4" '[[ -f "$OUT" ]]' -- convert.media.mp4 "$F/iphone.mov"
expect "speed 2× → ~1.5s" 'near "$(dur "$OUT")" 1.5' -- tool.media.speed "$F/iphone.mov"

echo "Subtitles inside containers"
expect "mkv+srt → mp4 keeps subs" '[[ $(nstreams "$OUT" s) -ge 1 ]]' -- convert.media.mp4 "$F/subs.mkv"
expect "mkv+srt → mov keeps subs" '[[ $(nstreams "$OUT" s) -ge 1 ]]' -- convert.media.mov "$F/subs.mkv"
expect "mkv+srt → webm" '[[ -f "$OUT" && $(nstreams "$OUT" v) == 1 ]]' -- convert.media.webm "$F/subs.mkv"
expect "mkv+srt → avi" '[[ -f "$OUT" ]]' -- convert.media.avi "$F/subs.mkv"
expect "mkv+srt strip keeps subs" '[[ $(nstreams "$OUT" s) == 1 ]]' -- tool.metadata.strip "$F/subs.mkv"
expect "mkv+srt split" '[[ $(ls "$OUT" | wc -l) -ge 2 ]]' -- tool.media.split --set seconds=1 "$F/subs.mkv"
expect "mkv+srt compress" '[[ -f "$OUT" ]]' -- tool.compress "$F/subs.mkv"
expect "mkv+srt trim keeps subs" '[[ $(nstreams "$OUT" s) -ge 1 ]]' -- tool.media.trim --set start=0 --set end=2 "$F/subs.mkv"
expect "mkv+srt speed" '[[ -f "$OUT" ]]' -- tool.media.speed "$F/subs.mkv"
expect "mp4+mov_text → mkv keeps subs" '[[ $(nstreams "$OUT" s) -ge 1 ]]' -- convert.media.mkv "$F/subs.mp4"
expect "mp4+mov_text → webm" '[[ -f "$OUT" ]]' -- convert.media.webm "$F/subs.mp4"
expect "mp4+mov_text split" '[[ $(ls "$OUT" | wc -l) -ge 2 ]]' -- tool.media.split --set seconds=1 "$F/subs.mp4"
expect "mp4+mov_text strip" '[[ $(nstreams "$OUT" s) == 1 ]]' -- tool.metadata.strip "$F/subs.mp4"
expect "mp4+mov_text rotate" '[[ -f "$OUT" ]]' -- tool.video.rotate "$F/subs.mp4"

echo "Multiple audio tracks"
expect "→ mp4 keeps both tracks" '[[ $(nstreams "$OUT" a) == 2 ]]' -- convert.media.mp4 "$F/two audio.mkv"
expect "compress keeps both tracks" '[[ $(nstreams "$OUT" a) == 2 ]]' -- tool.compress "$F/two audio.mkv"
expect "strip keeps both tracks" '[[ $(nstreams "$OUT" a) == 2 ]]' -- tool.metadata.strip "$F/two audio.mkv"
expect "trim keeps both tracks" '[[ $(nstreams "$OUT" a) == 2 ]]' -- tool.media.trim --set start=1 "$F/two audio.mkv"

echo "Tiny (0.1s) video"
expect "snapshot middle" '[[ -f "$OUT" && "$(dims "$OUT")" == "320 240" ]]' -- tool.video.snapshot "$F/tiny.mp4"
expect "snapshot first frame of tiny" '[[ -f "$OUT" ]]' -- tool.video.snapshot --set frames=1 "$F/tiny.mp4"
expect "snapshot ×10 all exist" '[[ $(ls "$OUT" | wc -l) -eq 10 ]]' -- tool.video.snapshot --set frames=2 "$F/tiny.mp4"
expect "split 1s → one part" '[[ $(ls "$OUT" | wc -l) -eq 1 ]]' -- tool.media.split --set seconds=1 "$F/tiny.mp4"
expect "fit 0.05MB" '[[ $(size "$OUT") -le 50000 ]]' -- tool.fit --set megabytes=0.05 "$F/tiny.mp4"
expect "speed 0.25×" '[[ -f "$OUT" ]]' -- tool.media.speed --set speed=0 "$F/tiny.mp4"
expect "→ gif" '[[ -f "$OUT" ]]' -- convert.media.gif "$F/tiny.mp4"

echo "Odd-sized video tools"
expect "odd wide compress" '[[ -f "$OUT" ]]' -- tool.compress "$F/odd wide.mkv"
expect "odd tall compress smallest" '[[ -f "$OUT" ]]' -- tool.compress --set level=2 "$F/odd tall.mkv"
expect "odd wide fit 0.2MB" '[[ -f "$OUT" ]]' -- tool.fit --set megabytes=0.2 "$F/odd wide.mkv"
expect "odd tall rotate" '[[ "$(vdims "$OUT")" == "640,360" ]]' -- tool.video.rotate "$F/odd tall.mkv"

echo "Audio-only .mp4 (classified as video)"
expect_error "snapshot explains no video" "video" -- tool.video.snapshot "$F/audio only.mp4"
expect_error "mute explains no video" "video" -- tool.video.mute "$F/audio only.mp4"
expect_error "join with audio-only clip explains" "video" -- tool.video.join "$F/clip.mp4" "$F/audio only.mp4"
expect "→ m4a works" '[[ -f "$OUT" ]]' -- convert.media.m4a "$F/audio only.mp4"

echo "Target size larger than the file"
expect "video fit 50MB not bigger than source" '[[ $(size "$OUT") -le $(( $(size "$F/clip.mp4") * 3 / 2 )) ]]' -- tool.fit --set megabytes=50 "$F/clip.mp4"
expect "audio fit 50MB not bigger than source" '[[ $(size "$OUT") -le $(( $(size "$F/song.m4a") * 3 / 2 )) ]]' -- tool.fit --set megabytes=50 "$F/song.m4a"

echo "Trim / split / bleep parameters"
expect "trim start 1:30.5 → ~9.5s" 'near "$(dur "$OUT")" 9.5 0.4' -- tool.media.trim --set start=1:30.5 "$F/long.mp3"
expect "trim 0:00:10 - 00:01:00 → 50s" 'near "$(dur "$OUT")" 50 0.4' -- tool.media.trim --set start=0:00:10 --set end=00:01:00 "$F/long.mp3"
expect_error "trim start 01:02:03 past end" "after" -- tool.media.trim --set start=01:02:03 "$F/long.mp3"
expect_error "trim negative start" "time" -- tool.media.trim --set start=-5 "$F/long.mp3"
expect_error "trim comma decimal" "time" -- tool.media.trim --set start=1,5 "$F/long.mp3"
expect_error "trim end before start" "after" -- tool.media.trim --set start=20 --set end=10 "$F/long.mp3"
expect_error "trim 'inf' start" "" -- tool.media.trim --set start=inf "$F/long.mp3"
expect_error "split 0.5s explains" "1 second" -- tool.media.split --set seconds=0.5 "$F/long.mp3"
expect "split 30s → 4 parts" '[[ $(ls "$OUT" | wc -l) -eq 4 ]]' -- tool.media.split --set seconds=30 "$F/long.mp3"
expect "bleep range past end keeps length" 'near "$(dur "$OUT")" 2.0' -- tool.audio.bleep --set "ranges=0:01-0:10" "$F/a.wav"
expect "bleep range entirely past end" 'near "$(dur "$OUT")" 2.0' -- tool.audio.bleep --set "ranges=5-6" "$F/a.wav"
expect "bleep m4a w/ spaces in ranges" 'near "$(dur "$OUT")" 3.0' -- tool.audio.bleep --set "ranges= 0:01 - 0:02 , 2.5-2.7 " "$F/song.m4a"
expect_error "bleep open range '5-' explains" "ranges" -- tool.audio.bleep --set "ranges=5-" "$F/a.wav"

echo "Join"
expect "join wav+mp3+flac → ~6s wav" '[[ "$OUT" == *.wav ]] && near "$(dur "$OUT")" 6.0' -- tool.audio.join "$F/a.wav" "$F/b.mp3" "$F/c.flac"
expect "join flac first → flac" '[[ "$OUT" == *.flac ]] && near "$(dur "$OUT")" 4.0' -- tool.audio.join "$F/c.flac" "$F/b.mp3"
expect "join video tiny+iphone+subs.mkv" 'near "$(dur "$OUT")" 6.1 0.4' -- tool.video.join "$F/tiny.mp4" "$F/iphone.mov" "$F/subs.mkv"

echo "Uppercase extensions & no extension"
expect_list "PHOTO.JPG: no JPG convert, has PNG" '! has convert.image.jpeg && has convert.image.png && has tool.compress' -- "$F/PHOTO.JPG"
expect_list "CLIP.MOV: no MOV convert, has MP4" '! has convert.media.mov && has convert.media.mp4 && has tool.media.trim' -- "$F/CLIP.MOV"
expect_list "SONG.MP3: no MP3 convert" '! has convert.media.mp3 && has convert.media.wav' -- "$F/SONG.MP3"
expect "PHOTO.JPG compress → 'PHOTO (compressed).jpg'" '[[ "$(basename "$OUT")" == "PHOTO (compressed).jpg" ]]' -- tool.compress "$F/PHOTO.JPG"
expect "CLIP.MOV trim → 'CLIP (trimmed).mov'" '[[ "$(basename "$OUT")" == "CLIP (trimmed).mov" ]]' -- tool.media.trim --set start=1 "$F/CLIP.MOV"
expect "SONG.MP3 compress stays mp3" '[[ "$OUT" == *.mp3 ]]' -- tool.compress "$F/SONG.MP3"
expect "CLIP.MOV split parts lowercased ext" '[[ -f "$OUT/CLIP part 000.mov" ]]' -- tool.media.split --set seconds=1 "$F/CLIP.MOV"
expect_list "extension-less file gets archive fallback" 'has archive.zip' -- "$F/photo_noext"

echo "Folders with dots in the name"
expect_list "'Vacation.mov' folder is a folder" 'has archive.zip && ! has convert.media.mp4' -- "$F/dirs/Vacation.mov"
expect_list "'backup.zip' folder is a folder" 'has archive.zip && ! has convert.archive.extract' -- "$F/dirs/backup.zip"
expect_list "'photos.2024' folder → archives" 'has archive.zip' -- "$F/dirs/photos.2024"
expect_list "'Thing.app' → archives" 'has archive.zip' -- "$F/dirs/Thing.app"
expect "zip 'photos.2024' → photos.2024.zip" '[[ "$(basename "$OUT")" == "photos.2024.zip" ]] && unzip -Z1 "$OUT" | grep -qx "photos.2024/inside.txt"' -- archive.zip "$F/dirs/photos.2024"
expect "gzip 'photos.2024' → photos.2024.tar.gz" '[[ "$(basename "$OUT")" == "photos.2024.tar.gz" ]]' -- archive.gzip "$F/dirs/photos.2024"

echo "0-byte files"
for e in jpg png; do expect_error "empty.$e → convert" "empty.$e" -- convert.image.webp "$F/zero/empty.$e"; done
expect_error "empty.jpg compress" "empty.jpg" -- tool.compress "$F/zero/empty.jpg"
for e in mp4 mov; do expect_error "empty.$e → mkv" "empty.$e" -- convert.media.mkv "$F/zero/empty.$e"; done
expect_error "empty.mp4 split leaves no folder" "" -- tool.media.split "$F/zero/empty.mp4"
expect_error "empty.mp4 snapshot" "" -- tool.video.snapshot --set frames=2 "$F/zero/empty.mp4"
expect_error "empty.mp4 fit explains" "length" -- tool.fit "$F/zero/empty.mp4"
expect_error "empty.mp3 → wav" "" -- convert.media.wav "$F/zero/empty.mp3"
expect_error "empty.wav compress" "" -- tool.compress "$F/zero/empty.wav"
expect_error "empty.pdf → png" "empty.pdf" -- convert.pdf.png "$F/zero/empty.pdf"
expect_error "empty.zip extract" "empty" -- convert.archive.extract "$F/zero/empty.zip"
expect_error "empty.gz extract" "empty" -- convert.archive.extract "$F/zero/empty.gz"
expect_error "empty.docx → pdf" "empty.docx" -- convert.document.pdf "$F/zero/empty.docx"

echo "Huge / tiny images"
expect "12000×8000 compress → 3840 edge" '[[ "$(dims "$OUT")" == "3840 2560" ]]' -- tool.compress "$F/huge.jpg"
expect "12000×8000 fit 2MB" '[[ $(size "$OUT") -le 2000000 ]]' -- tool.fit --set megabytes=2 "$F/huge.jpg"
expect "12000×8000 resize 25%" '[[ "$(dims "$OUT")" == "3000 2000" ]]' -- tool.image.resize --set size=2 "$F/huge.jpg"
expect "12000×8000 → heic" '[[ "$(dims "$OUT")" == "12000 8000" ]]' -- convert.image.heic "$F/huge.jpg"
expect "12000×8000 → webp" '[[ -f "$OUT" ]]' -- convert.image.webp "$F/huge.jpg"
expect "12000×8000 + 1×1 make pdf" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 2 ]]' -- tool.image.pdf "$F/huge.jpg" "$F/one.png"
for f in jpeg heic webp avif tiff bmp gif pdf; do expect "1×1 → $f" '[[ -s "$OUT" ]]' -- convert.image.$f "$F/one.png"; done
expect "1×1 resize 25% stays 1×1" '[[ "$(dims "$OUT")" == "1 1" ]]' -- tool.image.resize --set size=2 "$F/one.png"
expect "1×1 crop 16:9" '[[ -f "$OUT" ]]' -- tool.image.crop --set aspect=4 "$F/one.png"
expect "1×1 background" '[[ -f "$OUT" ]]' -- tool.image.background "$F/one.png"
expect "1×1 compress" '[[ -f "$OUT" ]]' -- tool.compress "$F/one.png"
expect "1×1 QR → message" '[[ "$ALL" == *"No QR"* ]]' -- tool.image.qr "$F/one.png"
expect_error "1×1 OCR → 'No text found'" "No text found" -- convert.image.txt "$F/one.png"

echo "Transparency"
expect "alpha png → jpg flattened white" '[[ "$(pix "$OUT" 150 50)" == "255 255 255 255" && "$(pix "$OUT" 50 50 | cut -d" " -f1)" -gt 240 ]]' -- convert.image.jpeg "$F/alpha.png"
expect "alpha png → bmp flattened white" '[[ "$(pix "$OUT" 150 50)" == "255 255 255 255" ]]' -- convert.image.bmp "$F/alpha.png"
expect "alpha png → webp keeps alpha" '[[ "$(pix "$OUT" 150 50 | cut -d" " -f4)" == 0 ]]' -- convert.image.webp "$F/alpha.png"
expect "alpha png → heic keeps alpha" '[[ "$(pix "$OUT" 150 50 | cut -d" " -f4)" == 0 ]]' -- convert.image.heic "$F/alpha.png"
expect "alpha png compress → heic w/ alpha" '[[ "$OUT" == *.heic && "$(pix "$OUT" 150 50 | cut -d" " -f4)" == 0 ]]' -- tool.compress "$F/alpha.png"
expect "alpha png fit → keeps alpha" '[[ "$(pix "$OUT" 150 50 | cut -d" " -f4)" == 0 ]]' -- tool.fit --set megabytes=0.05 "$F/alpha.png"
expect "alpha heic → png keeps alpha" '[[ "$(pix "$OUT" 150 50 | cut -d" " -f4)" == 0 ]]' -- convert.image.png "$F/alpha.heic"
expect "alpha png rotate keeps alpha" '[[ "$(pix "$OUT" 50 150 | cut -d" " -f4)" == 0 || "$(pix "$OUT" 50 50 | cut -d" " -f4)" == 0 ]]' -- tool.image.rotate "$F/alpha.png"
expect "alpha png → pdf" '[[ -f "$OUT" ]]' -- convert.image.pdf "$F/alpha.png"
expect "alpha png collage has white (not black) bg" '[[ "$(pix "$OUT" 900 500 | cut -d" " -f1)" -gt 200 ]]' -- tool.image.collage --set layout=1 "$F/alpha.png" "$F/one.png"

echo "Wide gamut (Display P3)"
expect "p3 png → jpg keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- convert.image.jpeg "$F/p3.png"
expect "p3 png → webp keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- convert.image.webp "$F/p3.png"
expect "p3 jpg compress keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- tool.compress "$F/p3.jpg"
expect "p3 jpg rotate keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- tool.image.rotate "$F/p3.jpg"
expect "p3 jpg resize keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- tool.image.resize "$F/p3.jpg"
expect "p3 jpg edit keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- tool.image.adjust --set exposure=0.1 "$F/p3.jpg"
expect "p3 jpg strip metadata keeps P3" '[[ "$(profile "$OUT")" == *P3* ]]' -- tool.metadata.strip "$F/p3.jpg"

echo "Animated images"
expect "animated gif → webp stays animated" '[[ $(frames "$OUT") -gt 1 ]]' -- convert.image.webp "$F/anim.gif"
expect "animated webp → gif stays animated" '[[ $(frames "$OUT") -gt 1 ]]' -- convert.image.gif "$F/anim.webp"
expect "animated webp → png (first frame)" '[[ "$(dims "$OUT")" == "200 150" ]]' -- convert.image.png "$F/anim.webp"
expect "animated gif compress stays animated" '[[ $(frames "$OUT") -gt 1 ]]' -- tool.compress "$F/anim.gif"
expect "animated gif resize stays animated" '[[ $(frames "$OUT") -gt 1 ]]' -- tool.image.resize "$F/anim.gif"
expect_list "animated webp offers MP4 like gif" 'has convert.image.mp4' -- "$F/anim.webp"

echo "Collage"
expect "grid of 10 → 4×3 tiles" '[[ "$(dims "$OUT")" == "4120 3096" ]]' -- tool.image.collage "$F"/grid/g*.jpg
expect "row of 10 panoramas" '[[ -f "$OUT" ]]' -- tool.image.collage --set layout=1 "$F"/pano/p*.jpg
expect "column with 12000×8000" '[[ -f "$OUT" ]]' -- tool.image.collage --set layout=2 "$F/huge.jpg" "$F/PHOTO.JPG"

echo "PDF"
expect "rotated page → png is landscape" '[[ "$(dims "$OUT")" == "1584 1224" ]]' -- convert.pdf.png "$F/rotated.pdf"
expect "cropBox page → png uses cropBox" '[[ "$(dims "$OUT")" == "600 400" ]]' -- convert.pdf.png "$F/cropped.pdf"
expect "rotated page → pdf pages keeps rotation" '[[ "$(pdfi "$OUT" | cut -d" " -f4)" == 90 ]]' -- tool.pdf.pages --set pages=1 "$F/rotated.pdf"
expect "rotated page + rotate 90 → 180" '[[ "$(pdfi "$OUT" | cut -d" " -f4)" == 180 ]]' -- tool.pdf.rotate "$F/rotated.pdf"
expect_error "locked → png says password" "password" -- convert.pdf.png "$F/locked.pdf"
expect_error "locked → txt says password" "password" -- convert.pdf.txt "$F/locked.pdf"
expect_error "locked merge says password, no output" "password" -- tool.pdf.merge "$F/three.pdf" "$F/locked.pdf"
expect_error "locked split leaves no folder" "password" -- tool.pdf.split "$F/locked.pdf"
expect "owner-only pdf pages" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 2 ]]' -- tool.pdf.pages --set pages=1,3 "$F/owner only.pdf"
expect "owner-only pdf → txt" 'grep -q "Page 2" "$OUT"' -- convert.pdf.txt "$F/owner only.pdf"
expect "pages '1 - 3'" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 3 ]]' -- tool.pdf.pages --set "pages=1 - 3" "$F/three.pdf"
expect "pages '-2'" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 2 ]]' -- tool.pdf.pages --set pages=-2 "$F/three.pdf"
expect "pages '2-'" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 2 ]]' -- tool.pdf.pages --set pages=2- "$F/three.pdf"
expect "pages '1,,3'" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 2 ]]' -- tool.pdf.pages --set "pages=1,,3" "$F/three.pdf"
expect "pages '3-1' reversed order" '[[ "$(pdfi "$OUT" | cut -d" " -f1,6)" == "3 Page_3_hello" ]]' -- tool.pdf.pages --set pages=3-1 "$F/three.pdf"
expect "pages '3' first page is page 3" '[[ "$(pdfi "$OUT" | cut -d" " -f6)" == Page_3_hello ]]' -- tool.pdf.pages --set pages=3 "$F/three.pdf"
expect_error "pages '1-2-3' explains" "Couldn't read" -- tool.pdf.pages --set pages=1-2-3 "$F/three.pdf"
expect_error "pages '0' explains" "doesn't exist" -- tool.pdf.pages --set pages=0 "$F/three.pdf"
expect_error "pages 'abc' explains" "" -- tool.pdf.pages --set pages=abc "$F/three.pdf"
expect "pages '-' (lone dash) = all pages" '[[ "$(pdfi "$OUT" | cut -d" " -f1)" == 3 ]]' -- tool.pdf.pages --set pages=- "$F/three.pdf"

echo "Archives"
expect "zip with one folder → extracts the folder" '[[ -d "$OUT" && "$(basename "$OUT")" == proj && -f "$OUT/sub/b.txt" ]]' -- convert.archive.extract "$F/arc/singlefolder.zip"
expect "unicode zip names survive" '[[ -f "$OUT/café/naïve ü.txt" || -n "$(find "$OUT" -name "*.txt" | iconv -f utf-8 -t utf-8 | grep -c 日本)" ]] && [[ $(find "$OUT" -type f | wc -l) -eq 2 ]] && python3 -c "import os,sys,unicodedata as u; names=[u.normalize(\"NFC\",n) for _,_,fs in os.walk(sys.argv[1]) for n in fs]; sys.exit(0 if \"naïve ü.txt\" in names and \"日本.txt\" in names else 1)" "$OUT"' -- convert.archive.extract "$F/arc/unicode.zip"
expect "ditto zip (__MACOSX) → single folder" '[[ -d "$OUT" && ! -e "$(dirname "$OUT")/__MACOSX" ]] && python3 -c "import os,sys,unicodedata as u; sys.exit(0 if u.normalize(\"NFC\",os.path.basename(sys.argv[1]))==\"café\" else 1)" "$OUT"' -- convert.archive.extract "$F/arc/ditto.zip"
expect "nested tar.gz → folder with inner tar.gz" '[[ -d "$OUT" && -f "$OUT/inner.tar.gz" && -f "$OUT/README" ]]' -- convert.archive.extract "$F/arc/nested.tar.gz"
expect ".tgz extract → proj folder" '[[ -f "$OUT/a.txt" ]]' -- convert.archive.extract "$F/arc/proj.tgz"
expect ".tgz → zip named proj.zip" '[[ "$(basename "$OUT")" == proj.zip ]]' -- convert.archive.zip "$F/arc/proj.tgz"
expect "plain .gz → zip contains notes.txt" 'unzip -Z1 "$OUT" | grep -qx notes.txt' -- convert.archive.zip "$F/arc/notes.txt.gz"
expect "plain .gz → tar" 'tar -tf "$OUT" | grep -q notes.txt' -- convert.archive.tar "$F/arc/notes.txt.gz"
expect "plain .bz2 extract → notes.txt" '[[ -f "$OUT" ]] && grep -q "plain text" "$OUT"' -- convert.archive.extract "$F/arc/notes.txt.bz2"
expect "gzip a.txt when a.txt.gz exists keeps .txt.gz" '[[ "$OUT" == *.txt.gz ]] && [[ "$(gzip -dc "$OUT")" == data ]]' -- archive.gzip "$F/arc/a.txt"
expect "extract a.txt.gz when a.txt exists → 'a 2.txt'" '[[ "$(basename "$OUT")" == "a 2.txt" ]]' -- convert.archive.extract "$F/arc/a.txt.gz"

echo
echo "Passed $pass, failed $fail. Work dir: $WORK"
if (( fail > 0 )); then printf '  ✗ %s\n' "${failures[@]}"; exit 1; fi
