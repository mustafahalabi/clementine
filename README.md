# Clementine

A menu bar app for macOS. Hold **⇧ Shift** while dragging a file and a wheel of output formats appears around the pointer. Drop on a format, and the converted copy lands right next to the original. Hold **⌥ Option + ⇧ Shift** instead and the wheel fills with tools for that kind of file.

Everything runs locally. Nothing is uploaded.

## Install

Download the latest `Clementine-<version>.dmg` from [Releases](https://github.com/mustafahalabi/clementine/releases), open it and drag Clementine to Applications. It's signed and notarized, comes with ffmpeg and the WebP tools built in, and updates itself (menu bar › Check for Updates…). On first launch a short welcome tour shows the two gestures; reopen it any time with **Show Welcome…**.

## Build & run

Requires macOS 14+ and Xcode 16+ (Swift 6 toolchain). Swift Package Manager fetches [Sparkle](https://sparkle-project.org) on the first build.

```sh
make tools                   # optional: verified static ffmpeg/ffprobe + cwebp/img2webp into vendor/bin, bundled into the app
make run                     # builds build/Clementine.app and launches it
make install                 # copies it to /Applications
make test                    # smoke, edge-case and stress suites: every action, run headlessly on generated files
make ui-test                 # interaction tests: real windows off-screen, driven with synthetic clicks, drags and typing
scripts/test-waveform.sh     # channel layouts, bleeps on video, editor times, offscreen editor renders
scripts/test-pdf-metadata.sh # page lists, merge picks and metadata writers, read back after each run
scripts/test-image-editor.sh # crop / redact / annotate engines, from the JSON the editors produce
```

The tests (and an app built without `make tools`) use Homebrew's tools: `brew install ffmpeg webp`. You can also open `Package.swift` in Xcode.

## Release

`make release` (or `scripts/release.sh`) builds the app, signs everything inside-out with the hardened runtime, notarizes and staples it, and writes a versioned `.zip` and `.dmg` to `dist/`. It needs two environment variables:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=clementine-notary make release
```

Without them it still produces artifacts, ad-hoc signed and named `-unsigned`, for local testing. The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`. [RELEASING.md](RELEASING.md) covers the one-time setup (certificate, notary profile, Sparkle keys), the appcast and publishing. CI (`.github/workflows/ci.yml`) builds and runs the smoke and edge tests on every push.

## Licensing of bundled tools

Release builds bundle FFmpeg (static GPL v3 builds by [Martin Riedl](https://ffmpeg.martin-riedl.de), run as separate processes), Google's libwebp tools (BSD) and Sparkle (MIT). Details, source locations and how to swap in an LGPL FFmpeg are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

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

- **Images:** Compress, Target Size, Resize, Crop, Rotate/Flip, Edit (exposure, brightness, contrast, saturation, highlights, shadows with live preview), Redact, Annotate, Add BG, Read QR, Metadata, Remove Metadata. With 2+ images: Collage, Make PDF.
  - **Crop** opens an editor: drag the frame's corners and edges, pick an aspect (Free, Original, 1:1, 4:5, 4:3, 3:2, 16:9, 9:16), turn in 90° steps.
  - **Redact** covers areas you draw, or faces and lines of text found with Auto-detect, with pixelate, blur or solid black. The original pixels are destroyed, not hidden.
  - **Annotate** draws arrows, rectangles, ellipses, pen and highlighter strokes, and text, with undo and redo.
- **Video:** Compress, Target Size (two-pass), Trim (waveform + filmstrip editor), Speed, Split, Snapshot, Mute, Rotate, Bleep, Metadata (editable), Remove Metadata. With 2+ clips: Join.
- **Audio:** Compress, Target Size, Trim (waveform editor with "trim silent ends"), Speed, Split, Normalize (EBU R128), Trim Silence, Channels (mono / stereo / swap L⇄R with per-side volume), Bleep (drag regions on the waveform, preview with bleeps), Metadata (editable), Remove Metadata. With 2+ files: Join.
- **PDF:** Compress, Pages (a thumbnail grid: drag to reorder, rotate, duplicate, delete), Split, Rotate, Metadata (editable), Remove Metadata. With 2+ files: Merge, arranged in the same page grid.

In the editors Return applies, Esc cancels and Delete removes the selection. Metadata edits are saved to an `(edited)` copy without re-encoding.

Dropping several files runs the action on each (several at once: up to half your cores for images and documents, two for ffmpeg work), or once on all of them for batch tools like Join, Merge and Collage. Each job gets a small progress window, and finished files are revealed in Finder. Dropping on the middle of the wheel cancels.

**Without dragging:** right-click files in Finder › Services › **Convert with Clementine** or **Clementine Tools**, or use **Open Files…** in the menu bar. The wheel opens in click mode: hover and click a slice, Tab (or the mode chip) switches wheels, arrows and Return work too, Esc or a click on the hub or elsewhere closes it.

**Your wheel:** slices you use most move to the front, per kind of file and wheel (frecency: uses fade with a two-week half-life; ties keep the catalog order). Settings › Wheel hides slices you never use, with a live preview, and resets everything.

**History & undo:** the menu bar's **Recent** submenu lists the last jobs (click to reveal the files), **Undo Last Conversion** moves the newest job's files to the Trash, and each finished progress card offers **Undo** for a few seconds (hover to keep it open). The last 50 jobs are kept in `~/Library/Application Support/Clementine/history.json`.

## How it works

```
Sources/Clementine/
  App/        entry point, menu bar, settings, CLI, welcome tour, Sparkle updater
  Drag/       DragMonitor (spots file drags + modifier keys), WheelController (glue)
  Wheel/      WheelPanel (floating drop target), WheelView (SwiftUI), WheelModel (geometry, hit-testing)
  Actions/    Action model + registry; ConvertActions and ToolActions are the catalog
  Engines/    ImageEngine/ImageTools (ImageIO, Core Image, Vision), PDFEngine (PDFKit),
              DocumentEngine (AppKit text system), MediaEngine/FFmpeg, ArchiveEngine, SubtitleEngine
  Jobs/       JobRunner, BatchRunner (parallel units), History, progress / parameter / result windows
  Waveform/   peak extraction + cache, playback and preview renders, the Trim / Bleep / Channels editors
  ImageEditor/  Crop, Redact and Annotate windows on a shared canvas (ImageEdits in Engines/ renders the result)
```

- **Spotting drags:** a global mouse-down monitor (no Accessibility permission needed) starts a 30 Hz poll while the button is held. When the shared drag pasteboard's change count bumps and it holds file URLs, a drag is underway. If ⇧ is down, the wheel opens under the pointer.
- **The wheel** is a borderless, non-activating `NSPanel` registered as a drop target. The slice under the pointer is worked out from angle and radius.
- **Adding an action** means adding an `Action` to `ConvertActions` or `ToolActions`. Give it an `accepts` predicate, optional `parameters` (they get a settings sheet automatically), and a `run` closure. It shows up on the wheel for matching files.
- **External tools** are looked up in `Contents/Resources/bin` first, then the folder set in Settings, then `/opt/homebrew/bin` and `/usr/local/bin`. `scripts/fetch-tools.sh` downloads pinned, checksum- and signature-verified builds of `ffmpeg`, `ffprobe`, `cwebp` and `img2webp` into `vendor/bin/` (`universal` for Intel + Apple silicon); `scripts/bundle.sh` copies them into the app.

### Headless CLI (for testing)

```sh
BIN=.build/debug/Clementine
$BIN --list photo.heic                                   # which actions apply
$BIN --run convert.image.webp photo.heic
$BIN --run tool.fit --set megabytes=2 clip.mov
$BIN --run convert.image.jpeg *.png --record               # parallel, like the app; --record logs usage + history
$BIN --history                                           # also --undo, --clear-history
$BIN --run tool.audio.channels --set channels=swap --set left=0.8 song.mp3   # mono | stereo | swap, gains 0–2
$BIN --run tool.audio.bleep --set "ranges=0:05.2-0:06, 1:10-1:12" clip.mp4
$BIN --run tool.pdf.merge --set 'pages=2:1-3, 1:2r90' a.pdf b.pdf
$BIN --run tool.metadata --set 'fields={"title":"Lisbon","rating":4,"removeLocation":true}' photo.jpg   # no fields: show it all
# The image editors take JSON in pixels of the upright image (top-left origin); crop rotates first, then crops:
$BIN --run tool.image.crop --set 'crop={"x":0,"y":0,"w":800,"h":600,"rotate":90}' photo.jpg
$BIN --run tool.image.redact --set 'boxes=[{"x":10,"y":20,"w":300,"h":40}]' --set style=blur photo.jpg   # or boxes=auto
$BIN --run tool.image.annotate --set 'shapes=[{"kind":"arrow","points":[[40,40],[300,200]],"color":"#FF5E3A","width":12}]' photo.jpg
$BIN --render-wheel /tmp/wheel.png --tools --hover 3 clip.mov   # draw the wheel to a PNG
build/Clementine.app/Contents/MacOS/Clementine --demo-wheel --tools clip.mov  # live wheel, no drag (--click for click mode)
```

`--list` shows each wheel as it would appear, with hidden slices marked. Debug builds read `CLEMENTINE_DEFAULTS_SUITE` and `CLEMENTINE_SUPPORT_DIR` so tests use scratch settings and history (the unbundled binary otherwise uses the `Clementine` defaults domain); `scripts/test-productivity.sh` covers ordering, hiding, history, undo and parallel batches.

## Known limits / roadmap

- **Metadata editing** covers the common fields. WebP, GIF, AVIF and other formats that can't be edited without re-encoding open read-only.
- **Waveform editors** show a filmstrip and video preview only for formats AVFoundation reads (MP4, MOV, M4V); MKV, WebM and the like get the waveform and sound-only playback. Bleep and Channels previews are rendered with ffmpeg first, so long files take a moment.
- **RAR** can be extracted (via bsdtar) but not created.
- **Split** copies streams without re-encoding, so cuts land on keyframes and part lengths are approximate.
- **DOCX → PDF** keeps text styling but not embedded images.
- **Distribution:** `make app` is ad-hoc signed for local use; `make release` makes signed, notarized builds (see above). The app isn't sandboxed, which global drag detection and running ffmpeg require, so the Mac App Store is out.
