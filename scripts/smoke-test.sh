#!/usr/bin/env bash
# Generates sample files and runs every action headlessly through `Clementine --run`.
# Usage: scripts/smoke-test.sh [filter]   e.g. scripts/smoke-test.sh tool.media
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
FILTER="${1:-}"
source scripts/test-lib.sh
test_setup smoke

echo "Fixtures in $F"
ffmpeg -loglevel error -f lavfi -i testsrc=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$F/clip.mp4"
ffmpeg -loglevel error -f lavfi -i testsrc2=size=320x240:rate=25 -t 2 -c:v libx264 -pix_fmt yuv420p "$F/silent.mp4"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=330:sample_rate=44100,volume=0.5" -af "apad=pad_dur=1" -t 5 "$F/tone.wav"
ffmpeg -loglevel error -i "$F/tone.wav" -c:a libmp3lame -q:a 4 "$F/tone.mp3"
ffmpeg -loglevel error -f lavfi -i testsrc=size=1600x1000 -frames:v 1 "$F/photo.png"
ffmpeg -loglevel error -f lavfi -i "color=c=red@0.5:size=400x300,format=rgba" -frames:v 1 "$F/alpha.png"
ffmpeg -loglevel error -i "$F/photo.png" -q:v 2 "$F/photo.jpg"
ffmpeg -loglevel error -f lavfi -i testsrc=size=200x150:rate=10 -t 1 "$F/anim.gif"
cat > "$F/logo.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120"><circle cx="60" cy="60" r="50" fill="orange"/></svg>
SVG
printf 'Hello from Clementine.\n\nSecond paragraph with some words.\n' > "$F/notes.txt"
cat > "$F/subs.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,500
Hello <i>there</i>

2
00:00:03,000 --> 00:00:04,000
Second line
SRT
mkdir -p "$F/folder/inner" && echo a > "$F/folder/a.txt" && echo b > "$F/folder/inner/b.txt"
(cd "$F" && zip -qr bundle.zip folder && tar -czf bundle.tar.gz folder && gzip -kc notes.txt > notes.txt.gz)
# A QR code image, via Core Image.
cat > "$WORK/qr.swift" <<'SWIFT'
import CoreImage; import ImageIO; import UniformTypeIdentifiers
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue("https://example.com/clementine".data(using: .utf8), forKey: "inputMessage")
let image = filter.outputImage!.transformed(by: .init(scaleX: 10, y: 10))
let canvas = image.extent.insetBy(dx: -40, dy: -40)
let cg = CIContext().createCGImage(image.composited(over: CIImage(color: .white).cropped(to: canvas)), from: canvas)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
SWIFT
swift "$WORK/qr.swift" "$F/qr.png" || echo "warning: couldn't make qr.png"

pass=0; fail=0; failures=()
run() { # run <action-id> [--set k=v]... <files>
  local id="$1"
  [[ -n "$FILTER" && "$id" != *"$FILTER"* ]] && return
  local out problem="" line
  # Output paths come from stdout only (CI VMs log framework noise to stderr).
  if ! out="$("$BIN" --run "$@" 2>"$WORK/stderr")"; then
    problem="$out$(cat "$WORK/stderr")"
  elif [[ "$out" == "== "* ]]; then
    [[ -n "$(echo "$out" | sed 1d)" ]] || problem="empty text result"
  elif [[ -z "$out" ]]; then
    problem="no output path"
  else
    # Every output must exist and have content: a non-empty file, or a folder with something in it.
    while IFS= read -r line; do
      if [[ -f "$line" ]]; then [[ -s "$line" ]] || problem="empty file: $line"
      elif [[ -d "$line" ]]; then [[ -n "$(ls -A "$line")" ]] || problem="empty folder: $line"
      else problem="missing output: $line (stdout: $(echo "$out" | head -3 | cat -v | tr '\n' '|'))"; fi
    done <<<"$out"
  fi
  if [[ -z "$problem" ]]; then
    pass=$((pass + 1)); printf '  ✓ %-28s %s\n' "$id" "$(echo "$out" | head -1 | sed "s|$F/||")"
  else
    fail=$((fail + 1)); failures+=("$id"); printf '  ✗ %-28s %s\n' "$id" "$problem"
  fi
}

echo "Convert"
for f in jpeg png heic webp avif tiff bmp gif pdf; do run convert.image.$f "$F/photo.png"; done
run convert.image.png "$F/photo.jpg"
run convert.image.jpeg "$F/alpha.png"
run convert.image.png "$F/logo.svg"
run convert.image.mp4 "$F/anim.gif"
for f in mp4 mov mkv avi wmv webm gif; do run convert.media.$f "$F/silent.mp4"; done
run convert.media.webm "$F/clip.mp4"
for f in mp3 m4a wav; do run convert.media.$f "$F/clip.mp4"; done
for f in mp3 m4a flac ogg opus aiff; do run convert.media.$f "$F/tone.wav"; done
for f in pdf docx rtf; do run convert.document.$f "$F/notes.txt"; done
run convert.document.txt "$(ls "$F"/notes.docx)"
run convert.document.pdf "$F/notes.docx"
run convert.pdf.txt "$F/notes.pdf"
run convert.pdf.docx "$F/notes.pdf"
run convert.pdf.png "$F/notes.pdf"
run convert.pdf.jpeg "$F/notes.pdf"
run convert.image.txt "$F/notes.png"
run convert.subtitle.vtt "$F/subs.srt"
run convert.subtitle.srt "$F/subs.vtt"
run convert.archive.extract "$F/bundle.zip"
run convert.archive.extract "$F/bundle.tar.gz"
run convert.archive.extract "$F/notes.txt.gz"
run convert.archive.zip "$F/bundle.tar.gz"
run convert.archive.tar "$F/bundle.zip"
run convert.archive.gzip "$F/bundle.zip"
run archive.zip "$F/folder"
run archive.tar "$F/folder" "$F/notes.txt"
run archive.gzip "$F/notes.txt"
run archive.gzip "$F/folder"

echo "Tools: images"
run tool.compress "$F/photo.png"
run tool.compress --set level=2 "$F/photo.jpg"
run tool.fit --set megabytes=0.05 "$F/photo.jpg"
run tool.image.resize "$F/photo.jpg"
run tool.image.crop --set aspect=0 "$F/photo.jpg"
run tool.image.rotate --set rotation=0 "$F/photo.jpg"
run tool.image.adjust --set exposure=0.5 --set saturation=1.5 "$F/photo.jpg"
run tool.image.background "$F/alpha.png"
run tool.image.qr "$F/qr.png"
run tool.image.collage "$F/photo.jpg" "$F/alpha.png" "$F/qr.png"
run tool.image.collage --set layout=1 "$F/photo.jpg" "$F/alpha.png"
run tool.image.pdf "$F/photo.jpg" "$F/qr.png"
run tool.metadata "$F/photo.jpg"
run tool.metadata.strip "$F/photo.jpg"

echo "Tools: video & audio"
run tool.compress "$F/clip.mp4"
run tool.compress "$F/tone.wav"
run tool.fit --set megabytes=0.3 "$F/clip.mp4"
run tool.fit --set megabytes=0.05 "$F/tone.wav"
run tool.media.trim --set start=0:01 --set end=0:03 "$F/clip.mp4"
run tool.media.trim --set start=1 "$F/tone.mp3"
run tool.media.speed "$F/clip.mp4"
run tool.media.speed --set speed=0 "$F/silent.mp4"
run tool.media.split --set seconds=2 "$F/clip.mp4"
run tool.video.snapshot "$F/clip.mp4"
run tool.video.snapshot --set frames=2 "$F/clip.mp4"
run tool.video.mute "$F/clip.mp4"
run tool.video.rotate "$F/clip.mp4"
run tool.video.join "$F/clip.mp4" "$F/silent.mp4"
run tool.video.gif "$F/clip.mp4"
run tool.audio.normalize "$F/tone.mp3"
run tool.audio.silence "$F/tone.wav"
run tool.audio.channels "$F/tone.mp3"
run tool.audio.bleep --set ranges=0:01-0:02,3-3.5 "$F/tone.wav"
run tool.audio.join "$F/tone.wav" "$F/tone.mp3"
run tool.metadata "$F/clip.mp4"
run tool.metadata.strip "$F/tone.mp3"

echo "Tools: PDF"
run tool.pdf.compress "$F/notes.pdf"
run tool.pdf.pages --set pages=1,1 "$F/notes.pdf"
run tool.pdf.split "$F/photo.pdf"
run tool.pdf.rotate "$F/notes.pdf"
run tool.pdf.merge "$F/notes.pdf" "$F/photo.pdf"
run tool.metadata "$F/notes.pdf"
run tool.metadata.strip "$F/notes.pdf"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed: %s\n' "${failures[*]}"; exit 1; }
