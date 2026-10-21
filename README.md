# Clementine

A menu bar app for macOS. Hold **⇧ Shift** while dragging a file and a wheel of output formats appears around the pointer. Drop on a format, and the converted copy lands right next to the original. Hold **⌥ Option + ⇧ Shift** instead and the wheel fills with tools for that kind of file.

Everything runs locally. Nothing is uploaded.

## Build & run

Requires macOS 14+, Xcode 16+ (Swift 6 toolchain), and Homebrew tools for media:

```sh
brew install ffmpeg webp     # ffmpeg/ffprobe for video & audio, cwebp for WebP output
make run                     # builds build/Clementine.app and launches it
make install                 # copies it to /Applications
make test                    # smoke, edge-case and stress suites: every action, run headlessly on generated files
scripts/test-image-editor.sh # crop / redact / annotate engines, from the JSON the editors produce
```

You can also open `Package.swift` in Xcode.

## What it does

**Convert (⇧)**

| Input | Outputs |
| --- | --- |
| Images (incl. HEIC, WebP, SVG, AVIF) | JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, PDF, TXT (OCR); animated GIF → MP4 |
| Video | MP4, MOV, MKV, AVI, WMV, WebM, GIF, and soundtrack as MP3 / M4A / WAV |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF |
| Documents (DOCX, DOC, RTF, TXT, HTML, ODT, MD) | PDF, DOCX, TXT, RTF |
| PDF | TXT, DOCX, PNG / JPG pages |
| Subtitles | SRT ⇄ VTT |
| Archives (ZIP, TAR, GZ, RAR, 7Z…) | Extract, or repack as ZIP / TAR / GZIP |
| Folders, other files, mixed selections | ZIP, TAR, GZIP |

**Tools (⌥⇧)**

- **Images:** Compress, Target Size, Resize, Crop, Rotate/Flip, Edit (exposure, brightness, contrast, saturation, highlights, shadows with live preview), Redact, Annotate, Add BG (gradient backdrop, padding, rounded corners, shadow with live preview), Read QR, Metadata, Remove Metadata. With 2+ images: Collage, Make PDF, and Crop trims them all to an aspect preset.
  - **Crop** opens an editor: drag the frame's corners and edges (or draw a new one), pick an aspect (Free, Original, 1:1, 4:5, 4:3, 3:2, 16:9, 9:16), turn the picture by quarters.
  - **Redact** covers areas you draw, or faces and lines of text found with Auto-detect, in pixelate, blur or black. All three replace the pixels underneath for good (blocks are averaged with random grain, and blur starts from those blocks), so nothing can be recovered.
  - **Annotate** draws arrows, rectangles, ellipses, pen and highlighter strokes, and text, in citrus and classic colors and three widths, with select/move/delete and undo (⌘Z, ⇧⌘Z).
  - In the editors Return applies, Esc cancels and Delete removes the selected box or mark. Edits render at full resolution and keep the format and metadata (animated GIFs stay animated).
- **Video:** Compress, Target Size (two-pass), Trim, Speed, Split, Snapshot, Mute, Rotate, Metadata, Remove Metadata. With 2+ clips: Join (mixed sizes/codecs are fine).
- **Audio:** Compress, Target Size, Trim, Speed, Split, Normalize (EBU R128), Trim Silence, Channels (mono/stereo), Bleep (time ranges), Metadata, Remove Metadata. With 2+ files: Join.
- **PDF:** Compress, Pages (keep/reorder, e.g. `3, 1-2, 5-`), Split, Rotate, Metadata, Remove Metadata. With 2+ files: Merge.

Dropping several files runs the action on each, or once on all of them for batch tools like Join, Merge and Collage. Each job gets a small progress window, and finished files are revealed in Finder. Dropping on the middle of the wheel cancels.

## How it works

```
Sources/Clementine/
  App/        entry point, menu bar, settings, CLI
  Drag/       DragMonitor (spots file drags + modifier keys), WheelController (glue)
  Wheel/      WheelPanel (floating drop target), WheelView (SwiftUI), WheelModel (geometry, hit-testing)
  Actions/    Action model + registry; ConvertActions and ToolActions are the catalog
  Engines/    ImageEngine/ImageTools (ImageIO, Core Image, Vision), PDFEngine (PDFKit),
              DocumentEngine (AppKit text system), MediaEngine/FFmpeg, ArchiveEngine, SubtitleEngine
  Jobs/       JobRunner, progress / parameter / result windows
  ImageEditor/  Crop, Redact and Annotate windows on a shared canvas (ImageEdits in Engines/ renders the result)
```

- **Spotting drags:** a global mouse-down monitor (no Accessibility permission needed) starts a 30 Hz poll while the button is held. When the shared drag pasteboard's change count bumps and it holds file URLs, a drag is underway. If ⇧ is down, the wheel opens under the pointer.
- **The wheel** is a borderless, non-activating `NSPanel` registered as a drop target. The slice under the pointer is worked out from angle and radius.
- **Adding an action** means adding an `Action` to `ConvertActions` or `ToolActions`. Give it an `accepts` predicate, optional `parameters` (they get a settings sheet automatically), and a `run` closure. It shows up on the wheel for matching files.
- **External tools** are looked up in `Contents/Resources/bin` first, then the folder set in Settings, then `/opt/homebrew/bin` and `/usr/local/bin`. To ship a self-contained app, put static `ffmpeg`, `ffprobe` and `cwebp` builds in `vendor/bin/`. `scripts/bundle.sh` copies them into the app.

### Headless CLI (for testing)

```sh
BIN=.build/debug/Clementine
$BIN --list photo.heic                                   # which actions apply
$BIN --run convert.image.webp photo.heic
$BIN --run tool.fit --set megabytes=2 clip.mov
# The image editors take JSON in pixels of the upright image (top-left origin); crop rotates first, then crops:
$BIN --run tool.image.crop --set 'crop={"x":0,"y":0,"w":800,"h":600,"rotate":90}' photo.jpg
$BIN --run tool.image.redact --set 'boxes=[{"x":10,"y":20,"w":300,"h":40}]' --set style=blur photo.jpg   # or boxes=auto
$BIN --run tool.image.annotate --set 'shapes=[{"kind":"arrow","points":[[40,40],[300,200]],"color":"#FF5E3A","width":12}]' photo.jpg
$BIN --render-wheel /tmp/wheel.png --tools --hover 3 clip.mov   # draw the wheel to a PNG
build/Clementine.app/Contents/MacOS/Clementine --demo-wheel --tools clip.mov  # live wheel, no drag
```

## Known limits / roadmap

- **Interactive editors still to build:** waveform trim, a bleep editor, and drag-to-reorder for PDF pages. Today these use typed values (`0:05-0:06` ranges, `3, 1-2` page lists).
- **Metadata** can be viewed or removed, but not edited yet.
- **RAR** can be extracted (via bsdtar) but not created.
- **Split** copies streams without re-encoding, so cuts land on keyframes and part lengths are approximate.
- **DOCX → PDF** keeps text styling but not embedded images.
- **Distribution:** the app is ad-hoc signed for local use. To share it, sign with a Developer ID (`CODESIGN_IDENTITY="Developer ID Application: …" make app`), notarize, and bundle ffmpeg. It isn't sandboxed, which global drag detection and running ffmpeg require, so the Mac App Store is out.
