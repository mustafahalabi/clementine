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

- **Images:** Compress, Target Size, Resize, Crop (aspect presets), Rotate/Flip, Edit (exposure, brightness, contrast, saturation, highlights, shadows with live preview), Add BG (gradient backdrop, padding, rounded corners, shadow with live preview), Read QR, Metadata, Remove Metadata. With 2+ images: Collage, Make PDF.
- **Video:** Compress, Target Size (two-pass), Trim, Speed, Split, Snapshot, Mute, Rotate, Metadata, Remove Metadata. With 2+ clips: Join (mixed sizes/codecs are fine).
- **Audio:** Compress, Target Size, Trim, Speed, Split, Normalize (EBU R128), Trim Silence, Channels (mono/stereo), Bleep (time ranges), Metadata, Remove Metadata. With 2+ files: Join.
- **PDF:** Compress, Pages (keep/reorder, e.g. `3, 1-2, 5-`), Split, Rotate, Metadata, Remove Metadata. With 2+ files: Merge.

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
$BIN --render-wheel /tmp/wheel.png --tools --hover 3 clip.mov   # draw the wheel to a PNG
build/Clementine.app/Contents/MacOS/Clementine --demo-wheel --tools clip.mov  # live wheel, no drag (--click for click mode)
```

`--list` shows each wheel as it would appear, with hidden slices marked. Debug builds read `CLEMENTINE_DEFAULTS_SUITE` and `CLEMENTINE_SUPPORT_DIR` so tests use scratch settings and history (the unbundled binary otherwise uses the `Clementine` defaults domain); `scripts/test-productivity.sh` covers ordering, hiding, history, undo and parallel batches.

## Known limits / roadmap

- **Interactive editors still to build:** freeform crop handles, annotate, redact, waveform trim, a bleep editor, and drag-to-reorder for PDF pages. Today these use presets or typed values (aspect ratios, `0:05-0:06` ranges, `3, 1-2` page lists).
- **Metadata** can be viewed or removed, but not edited yet.
- **RAR** can be extracted (via bsdtar) but not created.
- **Split** copies streams without re-encoding, so cuts land on keyframes and part lengths are approximate.
- **DOCX → PDF** keeps text styling but not embedded images.
- **Distribution:** `make app` is ad-hoc signed for local use; `make release` makes signed, notarized builds (see above). The app isn't sandboxed, which global drag detection and running ffmpeg require, so the Mac App Store is out.
