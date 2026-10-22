#!/usr/bin/env bash
# Page specs (rotation, merge file:page) and the metadata writers, run headlessly through `Clementine --run`.
# Each check runs an action and then reads the result back (PDFKit, ImageIO via the Metadata tool, ffprobe).
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
source scripts/test-lib.sh
test_setup pdfmeta
q() { ffmpeg -loglevel error -y "$@"; }

# Helper: PDF fixtures and a page dump ("count|rotation:first-word-of-text ...").
cat > "$WORK/h.swift" <<'SWIFT'
import AppKit; import PDFKit; import ImageIO
let args = CommandLine.arguments
func url(_ s: String) -> URL { URL(fileURLWithPath: s) }
switch args[1] {
case "pdf": // out n label
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let c = CGContext(url(args[2]) as CFURL, mediaBox: &box, nil)!
    for i in 0..<Int(args[3])! {
        c.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(args[4])\(i + 1) text", attributes: [.font: NSFont.systemFont(ofSize: 36)]))
        c.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(line, c)
        c.endPDFPage()
    }
    c.closePDF()
case "pages":
    let d = PDFDocument(url: url(args[2]))!
    let pages = (0..<d.pageCount).map { i -> String in
        let p = d.page(at: i)!
        return "\(p.rotation):\((p.string ?? "").split(separator: " ").first ?? "")"
    }
    print("\(d.pageCount)|\(pages.joined(separator: " "))")
case "info": // key
    let d = PDFDocument(url: url(args[2]))!
    let value = d.documentAttributes?[PDFDocumentAttribute(rawValue: args[3])]
    print((value as? [Any]).map { $0.map { "\($0)" }.joined(separator: ",") } ?? value.map { "\($0)" } ?? "")
case "photo": // in out: JPEG/PNG/HEIC with EXIF orientation 6, GPS, camera, artist
    let src = CGImageSourceCreateWithURL(url(args[2]) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let type = args[3].hasSuffix(".png") ? "public.png" : args[3].hasSuffix(".heic") ? "public.heic" : "public.jpeg"
    let dest = CGImageDestinationCreateWithURL(url(args[3]) as CFURL, type as CFString, 1, nil)!
    let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                      kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5", kCGImagePropertyTIFFArtist: "Old Name"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "TestLens", kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"]]
    CGImageDestinationAddImage(dest, img, props as CFDictionary); CGImageDestinationFinalize(dest)
case "pixels": // a b: same decoded pixels?
    func data(_ p: String) -> Data {
        let s = CGImageSourceCreateWithURL(url(p) as CFURL, nil)!
        let i = CGImageSourceCreateImageAtIndex(s, 0, nil)!
        return i.dataProvider!.data! as Data
    }
    print(data(args[2]) == data(args[3]) ? "same" : "different")
default: exit(2)
}
SWIFT
swiftc -O "$WORK/h.swift" -o "$WORK/h" 2>/dev/null || { echo "helper build failed"; exit 1; }
H="$WORK/h"

echo "Fixtures in $F"
"$H" pdf "$F/five.pdf" 5 P
"$H" pdf "$F/two.pdf" 2 Q
"$H" pdf "$F/one.pdf" 1 R
q -f lavfi -i testsrc=size=400x200 -frames:v 1 "$WORK/wide.png"
"$H" photo "$WORK/wide.png" "$F/photo.jpg"
"$H" photo "$WORK/wide.png" "$F/photo.png"
"$H" photo "$WORK/wide.png" "$F/photo.heic"
q -f lavfi -i testsrc=size=300x300 -frames:v 1 "$WORK/cover.png"
q -f lavfi -i "sine=r=44100" -i "$WORK/cover.png" -t 3 -map 0 -map 1 -c:a libmp3lame -c:v mjpeg -disposition:v attached_pic \
  -metadata title="Song" -metadata artist="Someone" -metadata genre="Rock" "$F/song.mp3"
q -f lavfi -i "sine=r=44100" -t 2 -c:a aac -metadata title="Tune" "$F/tune.m4a"
q -f lavfi -i "sine=r=48000" -t 2 -c:a libopus -metadata title="Voice" -metadata artist="Old" "$F/voice.opus"
q -f lavfi -i "sine=r=44100" -t 2 -metadata TITLE="Loss" "$F/loss.flac"
q -f lavfi -i testsrc=size=320x240:rate=30 -f lavfi -i sine=r=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac \
  -timecode 01:00:00:00 -write_tmcd 1 -metadata title="Clip" "$F/clip.mov"
echo "not a pdf" > "$F/broken.pdf"

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
  if eval "${check[*]}"; then ok "$name"; return; fi
  # For media outputs, show what ffprobe sees (tags and streams), so a failure on CI can be read from the log.
  local seen=""
  [[ "$OUT" =~ \.(mp3|m4a|mov|mp4|opus|flac)$ ]] && seen=" ffprobe: $(ffprobe -v error -show_entries format_tags:stream=codec_type,codec_tag_string -of compact "$OUT" 2>&1 | tr '\n' ' ')"
  bad "$name" "assertion failed: ${check[*]} (output: $OUT)$seen"
}
# expect_error <name> <substring> -- <action args…>: action must fail with a readable message containing substring.
expect_error() {
  local name="$1" needle="$2"; shift 3
  local out
  if out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  if [[ "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name" "unexpected message: $out"; fi
}
pages() { "$H" pages "$1"; }
meta() { "$BIN" --run tool.metadata "$1"; }
# A tag from the container, or (Ogg/Opus) the audio stream.
tag() {
  local v; v="$(ffprobe -v error -show_entries "format_tags=$2" -of default=nw=1:nk=1 "$1")"
  [[ -n "$v" ]] || v="$(ffprobe -v error -select_streams a:0 -show_entries "stream_tags=$2" -of default=nw=1:nk=1 "$1")"
  echo "$v"
}
nstreams() { ffprobe -v error -select_streams "$2" -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '; }

echo "Page specs"
expect "plain list unchanged" '[[ "$(pages "$OUT")" == "3|0:P3 0:P1 0:P2" ]]' -- tool.pdf.pages --set "pages=3, 1-2" "$F/five.pdf"
expect "3r90 rotates one page" '[[ "$(pages "$OUT")" == "4|90:P3 0:P1 0:P2 0:P5" ]]' -- tool.pdf.pages --set "pages=3r90, 1-2, 5-" "$F/five.pdf"
expect "range rotation 2-3r180" '[[ "$(pages "$OUT")" == "2|180:P2 180:P3" ]]' -- tool.pdf.pages --set "pages=2-3r180" "$F/five.pdf"
expect "r-90 means 270" '[[ "$(pages "$OUT")" == "1|270:P1" ]]' -- tool.pdf.pages --set "pages=1r-90" "$F/five.pdf"
expect "uppercase R and spaces" '[[ "$(pages "$OUT")" == "1|90:P4" ]]' -- tool.pdf.pages --set "pages=4 R 90" "$F/five.pdf"
expect "bare r90 rotates every page" '[[ "$(pages "$OUT")" == "5|90:P1 90:P2 90:P3 90:P4 90:P5" ]]' -- tool.pdf.pages --set "pages=r90" "$F/five.pdf"
expect "r360 is no rotation" '[[ "$(pages "$OUT")" == "1|0:P2" ]]' -- tool.pdf.pages --set "pages=2r360" "$F/five.pdf"
expect "duplicates allowed" '[[ "$(pages "$OUT")" == "3|0:P1 90:P1 0:P1" ]]' -- tool.pdf.pages --set "pages=1, 1r90, 1" "$F/five.pdf"
expect "1: prefix on a single file" '[[ "$(pages "$OUT")" == "2|0:P2 0:P3" ]]' -- tool.pdf.pages --set "pages=1:2-3" "$F/five.pdf"
ROTATED="$("$BIN" --run tool.pdf.pages --set pages=1r90 "$F/five.pdf")"
expect "rotation adds to a page's own" '[[ "$(pages "$OUT")" == "1|180:P1" ]]' -- tool.pdf.pages --set "pages=1r90" "$ROTATED"
expect_error "rotation not a multiple of 90" "Use r90, r180 or r270" -- tool.pdf.pages --set "pages=3r45" "$F/five.pdf"
expect_error "rotation missing degrees" "rotation" -- tool.pdf.pages --set "pages=3r" "$F/five.pdf"
expect_error "rotated page out of range" "This PDF has 5 pages" -- tool.pdf.pages --set "pages=9r90" "$F/five.pdf"
expect_error "file 2 on a single PDF" "Only one PDF is open" -- tool.pdf.pages --set "pages=2:1" "$F/five.pdf"
expect_error "garbage file prefix" "Couldn't read" -- tool.pdf.pages --set "pages=a:1" "$F/five.pdf"
expect_error "one-page pdf says 1 page" "has 1 page." -- tool.pdf.pages --set "pages=2" "$F/one.pdf"

echo "Merge specs"
expect "merge without spec keeps every page" '[[ "$(pages "$OUT")" == "8|0:P1 0:P2 0:P3 0:P4 0:P5 0:Q1 0:Q2 0:R1" ]]' -- tool.pdf.merge "$F/five.pdf" "$F/two.pdf" "$F/one.pdf"
expect "file:page picks across files" '[[ "$(pages "$OUT")" == "3|0:Q2 0:P1 0:R1" ]]' -- tool.pdf.merge --set "pages=2:2, 1:1, 3:1" "$F/five.pdf" "$F/two.pdf" "$F/one.pdf"
expect "file:range with rotation" '[[ "$(pages "$OUT")" == "4|90:Q1 90:Q2 0:P5 0:P4" ]]' -- tool.pdf.merge --set "pages=2:1-2r90, 1:5-4" "$F/five.pdf" "$F/two.pdf"
expect "file: alone takes the whole file" '[[ "$(pages "$OUT")" == "3|0:Q1 0:Q2 0:R1" ]]' -- tool.pdf.merge --set "pages=2:, 3:" "$F/five.pdf" "$F/two.pdf" "$F/one.pdf"
expect "plain numbers count through the files" '[[ "$(pages "$OUT")" == "3|0:Q1 0:P5 180:R1" ]]' -- tool.pdf.merge --set "pages=6, 5, 8r180" "$F/five.pdf" "$F/two.pdf" "$F/one.pdf"
expect "open range runs across files" '[[ "$(pages "$OUT")" == "3|0:P5 0:Q1 0:Q2" ]]' -- tool.pdf.merge --set "pages=5-7" "$F/five.pdf" "$F/two.pdf" "$F/one.pdf"
expect_error "merge: no such file" "Files are numbered 1–2" -- tool.pdf.merge --set "pages=3:1" "$F/five.pdf" "$F/two.pdf"
expect_error "merge: page past a file's end" "doesn't exist in file 2, which has 2 pages" -- tool.pdf.merge --set "pages=2:3" "$F/five.pdf" "$F/two.pdf"
expect_error "merge: plain page past the total" "7 pages in all" -- tool.pdf.merge --set "pages=8" "$F/five.pdf" "$F/two.pdf"
expect_error "merge: bad rotation" "r90" -- tool.pdf.merge --set "pages=1:1r30" "$F/five.pdf" "$F/two.pdf"
expect_error "merge: unreadable file, no output" "Couldn't read" -- tool.pdf.merge --set "pages=1:1" "$F/five.pdf" "$F/broken.pdf"

echo "Image metadata"
IMG='{"title":"Lisbon","description":"Tram 28","artist":"Ana","copyright":"(c) 2026 Ana","keywords":["sun","sea"],"date":"2026-07-14 18:42","rating":4}'
for ext in jpg png heic; do
  expect "$ext: fields round-trip" 'm="$(meta "$OUT")"; [[ "$m" == *"ObjectName: Lisbon"* && "$m" == *"Artist: Ana"* && "$m" == *"Copyright: (c) 2026 Ana"* && "$m" == *"Keywords: sun, sea"* && "$m" == *"DateTimeOriginal: 2026:07:14 18:42:00"* && "$m" == *"StarRating: 4"* && "$m" == *"Tram 28"* && "$OUT" == *"(edited).$ext" ]]' -- tool.metadata --set "fields=$IMG" "$F/photo.$ext"
  expect "$ext: camera, lens, GPS kept unless asked" 'm="$(meta "$OUT")"; [[ "$m" == *"EOS R5"* && "$m" == *TestLens* && "$m" == *"Latitude: 48.85"* ]]' -- tool.metadata --set 'fields={"title":"x"}' "$F/photo.$ext"
  expect "$ext: remove location drops GPS only" 'm="$(meta "$OUT")"; [[ "$m" != *Latitude* && "$m" != *GPS* && "$m" == *TestLens* ]]' -- tool.metadata --set 'fields={"removeLocation":true}' "$F/photo.$ext"
  expect "$ext: pixels untouched" '[[ "$("$H" pixels "$OUT" "$F/photo.$ext")" == same ]]' -- tool.metadata --set "fields=$IMG" "$F/photo.$ext"
  expect "$ext: orientation kept" '[[ "$(meta "$OUT" | grep -m1 "^Orientation")" == "Orientation: 6" ]]' -- tool.metadata --set 'fields={"rating":2}' "$F/photo.$ext"
done
expect "jpg: data copied, not re-encoded" '[[ $(( $(stat -f%z "$OUT") - $(stat -f%z "$F/photo.jpg") )) -lt 4000 && $(( $(stat -f%z "$F/photo.jpg") - $(stat -f%z "$OUT") )) -lt 4000 ]]' -- tool.metadata --set 'fields={"title":"Same bytes"}' "$F/photo.jpg"
EDITED="$("$BIN" --run tool.metadata --set "fields=$IMG" "$F/photo.jpg")"
expect "empty values clear fields" 'm="$(meta "$OUT")"; [[ "$m" != *ObjectName* && "$m" != *"Artist:"* && "$m" != *Keywords* && "$m" != *DateTimeOriginal* && "$m" != *StarRating* && "$m" != *Copyright* ]]' -- tool.metadata --set 'fields={"title":"","artist":"","copyright":"","keywords":[],"date":"","rating":0,"description":""}' "$EDITED"
expect "artist replaces an existing one" '[[ "$(meta "$OUT" | grep -m1 "  Artist:")" == *"Artist: New"* ]]' -- tool.metadata --set 'fields={"artist":"New"}' "$F/photo.jpg"
expect "EXIF-style and T dates accepted" '[[ "$(meta "$OUT")" == *"DateTimeOriginal: 1999:12:31 23:59:58"* ]]' -- tool.metadata --set 'fields={"date":"1999:12:31 23:59:58"}' "$F/photo.jpg"
expect "ISO T date accepted" '[[ "$(meta "$OUT")" == *"DateTimeOriginal: 2001:02:03 04:05:06"* ]]' -- tool.metadata --set 'fields={"date":"2001-02-03T04:05:06"}' "$F/photo.jpg"
expect_error "impossible date" "isn't a valid date" -- tool.metadata --set 'fields={"date":"2026-02-30"}' "$F/photo.jpg"
expect_error "date with words" "isn't a valid date" -- tool.metadata --set 'fields={"date":"last tuesday"}' "$F/photo.jpg"
expect_error "rating out of range" "0 to 5" -- tool.metadata --set 'fields={"rating":7}' "$F/photo.jpg"
expect_error "unknown image field" "isn't a field" -- tool.metadata --set 'fields={"album":"x"}' "$F/photo.jpg"
expect_error "fields not JSON" "JSON object" -- tool.metadata --set 'fields=title=x' "$F/photo.jpg"
expect "no fields still shows the dump" '[[ "$OUT" == "== photo.jpg ==" ]]' -- tool.metadata "$F/photo.jpg"

echo "Audio/video metadata"
MEDIA='{"title":"New Title","artist":"","album":"Album","album_artist":"Various","year":"2024","genre":"Pop","track":"3/12","comment":"hello"}'
expect "mp3: tags round-trip" '[[ "$(tag "$OUT" title)" == "New Title" && "$(tag "$OUT" album)" == Album && "$(tag "$OUT" album_artist)" == Various && "$(tag "$OUT" date)" == 2024 && "$(tag "$OUT" genre)" == Pop && "$(tag "$OUT" track)" == 3/12 && "$(tag "$OUT" comment)" == hello ]]' -- tool.metadata --set "fields=$MEDIA" "$F/song.mp3"
expect "mp3: empty value removes a tag" '[[ -z "$(tag "$OUT" artist)" ]]' -- tool.metadata --set "fields=$MEDIA" "$F/song.mp3"
expect "mp3: untouched tags and cover art kept" '[[ "$(tag "$OUT" genre)" == Rock && $(nstreams "$OUT" v) == 1 && $(nstreams "$OUT" a) == 1 ]]' -- tool.metadata --set 'fields={"title":"Only title"}' "$F/song.mp3"
expect "mp3: audio copied, not re-encoded" '[[ "$(ffprobe -v error -select_streams a -show_entries packet=size -of csv=p=0 "$OUT" | md5)" == "$(ffprobe -v error -select_streams a -show_entries packet=size -of csv=p=0 "$F/song.mp3" | md5)" ]]' -- tool.metadata --set 'fields={"title":"x"}' "$F/song.mp3"
expect "m4a: tags round-trip" '[[ "$(tag "$OUT" title)" == "New Title" && "$(tag "$OUT" track)" == 3/12 && "$OUT" == *"(edited).m4a" ]]' -- tool.metadata --set "fields=$MEDIA" "$F/tune.m4a"
expect "opus: stream tags replaced too" '[[ "$(tag "$OUT" title)" == "New Title" && -z "$(tag "$OUT" artist)" ]]' -- tool.metadata --set "fields=$MEDIA" "$F/voice.opus"
expect "flac: uppercase tags replaced" '[[ "$(tag "$OUT" title)" == "New Title" ]]' -- tool.metadata --set "fields=$MEDIA" "$F/loss.flac"
expect "mov with timecode: title + streams kept" '[[ "$(tag "$OUT" title)" == "Edited clip" && $(nstreams "$OUT" v) == 1 && $(nstreams "$OUT" a) == 1 ]]' -- tool.metadata --set 'fields={"title":"Edited clip","year":"2026-07-14"}' "$F/clip.mov"
expect "media dump still works" '[[ "$("$BIN" --run tool.metadata "$F/song.mp3")" == *Someone* ]]' -- tool.metadata "$F/song.mp3"
expect_error "bad year" "isn't a year" -- tool.metadata --set 'fields={"year":"20x4"}' "$F/song.mp3"
expect_error "bad track" "Track should be" -- tool.metadata --set 'fields={"track":"three"}' "$F/song.mp3"
expect_error "image field on audio" "isn't a field Clementine edits for audio and video" -- tool.metadata --set 'fields={"rating":3}' "$F/song.mp3"

echo "PDF metadata"
DOC='{"title":"Report","author":"Ana","subject":"Q3","keywords":"alpha, beta gamma","creator":"Clementine"}'
expect "pdf: fields round-trip" '[[ "$("$H" info "$OUT" Title)" == Report && "$("$H" info "$OUT" Author)" == Ana && "$("$H" info "$OUT" Subject)" == Q3 && "$("$H" info "$OUT" Keywords)" == "alpha,beta gamma" && "$("$H" info "$OUT" Creator)" == Clementine ]]' -- tool.metadata --set "fields=$DOC" "$F/five.pdf"
expect "pdf: pages untouched" '[[ "$(pages "$OUT")" == "$(pages "$F/five.pdf")" ]]' -- tool.metadata --set "fields=$DOC" "$F/five.pdf"
DOCED="$("$BIN" --run tool.metadata --set "fields=$DOC" "$F/five.pdf")"
expect "pdf: empty clears, others kept" '[[ -z "$("$H" info "$OUT" Title)" && "$("$H" info "$OUT" Author)" == Ana ]]' -- tool.metadata --set 'fields={"title":""}' "$DOCED"
expect "pdf: dump lists keywords plainly" '[[ "$("$BIN" --run tool.metadata "$DOCED")" == *"Keywords: alpha, beta gamma"* ]]' -- tool.metadata "$DOCED"
expect_error "unknown pdf field" "Use title, author, subject, keywords, creator" -- tool.metadata --set 'fields={"artist":"x"}' "$F/five.pdf"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
