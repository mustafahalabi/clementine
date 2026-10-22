# Changelog

## 0.2.0 — unreleased

New tools, a third wheel, Shortcuts, and better results on everyday phone video. Apple silicon, macOS 14 or later.

**New**
- **Cut Out Subject** (⌥⇧ on an image): removes the background and keeps the person, pet or object on
  transparency, on-device with Apple's Vision. Saves PNG, HEIC or WebP, optionally cropped to the subject, with a
  live preview; says "No subject found" instead of guessing. CLI: `tool.image.removebg`.
- **Presets:** **Save as Preset…** in any tool's settings sheet keeps those settings as a wheel slice of its own
  (marked with a small bookmark, placed after its tool) that runs without asking. Rename, reorder, hide and delete
  them in Settings › Wheel › Presets. Invalid presets are skipped with a reason. CLI: `--preset`, `--list-presets`,
  `--save-preset`, `--rename-preset`, `--delete-preset`.
- **A third wheel on ⌃** while dragging: Copy Path, Copy Name, SHA-256, Data URI (up to 5 MB), Open in Terminal,
  Reveal in Finder and AirDrop. Values go to the clipboard and show on the job card. ⌃ needs a quarter-second hold
  so ⌃-arrow Space switching mid-drag doesn't trigger it; Settings › General can turn it off. Also in click mode
  (Tab and the chip step through three wheels) and as a "Clementine File Actions" Service.
- **Shortcuts:** *Convert with Clementine* (any action, preset or file action, picked from a list that fits the
  files, with optional `key=value` settings), *Remove Background with Clementine* and *Convert Images with
  Clementine*. They return the new files (copied values come back as text) and run without opening any window.
- **GIF tool:** frame rate, width (or original) and an optional "under N MB" target. All GIFs now use 15 fps, a
  motion-weighted palette and better dithering.
- The wheel holds up to 13 slices (was 12); presets count toward it.

**Video**
- HDR video (iPhone HLG, HDR10/PQ) converted to H.264, WebM, GIF, PNG snapshots, Compress or Target Size is
  tone-mapped to SDR and tagged BT.709 instead of playing washed out. Trim, Speed, Rotate and Join keep HDR as
  10-bit HEVC in MP4/MOV.
- Hardware encoding (VideoToolbox) for Convert, Trim, Speed, Rotate and Join: a 5 s 4K clip converts in 2.9 s
  instead of 8.2 s, using 2.7 s of CPU instead of 49 s, at the same VMAF. Falls back to software by itself;
  Settings › **Use hardware encoding for video** turns it off and the CLI has `--software`. Compress and Target
  Size stay on software encoding, which makes smaller files.
- Join honours phone rotation, makes a portrait video from portrait clips, and keeps the clips' frame rate instead
  of forcing 30 fps.
- Trim, Speed and Rotate on TS, FLV and 3GP write H.264 + AAC, and MPG high-quality MPEG-2, instead of ffmpeg's
  200 kb/s defaults (3GP used to fail). Trimming a TS file no longer loses its video.

**Lighter on memory**
- Make PDF (Images → PDF) writes one page at a time: 100 × 12 MP photos peak at 8 MB, was ~7 GB. Upright JPEGs go
  in without re-encoding, and pages are sized for paper (the image's dpi, at most A4's long edge) instead of one
  point per pixel. Transparency is kept.
- PDF → PNG/JPG releases each page as it goes (200 pages: 56 MB peak, was 2.5 GB).
- Parallel batches share a memory budget, so very large images run fewer at a time.

**Reliability**
- Compress never hands back a bigger file: if the result isn't smaller, it's deleted and the original kept ("Already
  as small as it gets — kept the original."; the CLI prints `kept: <file>: …` on stderr and exits 0).
- Results are written under a hidden temporary name in the same folder and get their real name only when complete,
  so a crash or force quit can't leave a half-written file that looks finished. Nothing is ever replaced; leftovers
  from a crash are removed at the next launch, only in folders Clementine recorded itself.
- Polish from driving 0.2.0 on a real Mac: Settings fits a 1080p screen and resizes to each tab (it's capped to the
  screen and the form scrolls); renaming a preset in Settings and pressing Tab no longer shows the old name again;
  AirDrop says "AirDrop closed" instead of "Sent with AirDrop", since macOS reports Cancel in its picker as a
  finished share; Cut Out's preview says "No subject found" instead of spinning; the settings sheet's buttons are
  no longer cut off; suggested preset names are short enough for a slice ("0.05 MB" rather than
  "Target Size · 0.05 MB").
- Updates found by an automatic check no longer pop up behind other apps: the menu bar icon shows a dot, the menu
  gets an "Update Available: Clementine x — Install…" item, and a quiet notification goes to Notification Center.

**Project**
- New test suites `test-video.sh` and `test-presets-files.sh` (both in CI), more UI suites; `make test` runs ten
  suites.

## 0.1.1 — 2026-10-22

A hardening release: safer archives and outputs, nothing left behind when jobs stop, stricter privacy, and a
calmer first run. Apple silicon, macOS 14 or later.

**Safety and privacy**
- File names inside archives, and files you archive, are always treated as names, never as tool options.
- Extracting drops symlinks that point outside the extracted items and refuses archives that would expand to an
  unreasonable size or fill the disk.
- Outputs whose names differ only in letter case no longer overwrite each other, and ffmpeg never overwrites a file.
- Undo only trashes outputs that are still the files Clementine wrote.
- HTML conversion makes no network requests: remote images, stylesheets, fonts and frames are removed first.
- Redact removes GPS, camera serial numbers, owner names and embedded previews from the redacted image.
- New [PRIVACY.md](PRIVACY.md): the only automatic network request is Sparkle's update check.

**Reliability**
- Quitting the app or interrupting the CLI stops running tools and removes unfinished outputs.
- A tool that crashes is reported as a failure, not a cancellation; the CLI exits non-zero on failure (exit codes
  in docs/CLI.md).
- The CLI validates `--set` values and other arguments and explains what's allowed instead of crashing.
- The Mac stays awake while jobs run.
- Document → PDF fails at once in a folder that isn't writable, instead of hanging, and uses the system paper size.
- Text and subtitles in UTF-16 and Windows-1252 convert correctly.
- Created ZIPs mark non-ASCII file names as UTF-8, so they read correctly on Windows.

**First run and interface**
- Clementine no longer uses CPU while idle (the hidden wheel kept animating).
- Opening the app again shows Settings, or the welcome tour if it wasn't finished; the tour only counts as seen once
  you finish or close it. New installs launch at login.
- Job cards stack without overlapping; long errors fold behind "Show details…" and lead with a plain sentence.
- Higher-contrast accent for text on orange, with stronger shades under Increase Contrast; Reduce Motion turns off
  the wheel's decorative motion.
- The image wheel's OCR slice is labelled "Text (OCR)"; slices and the wheel have VoiceOver labels, and job results
  are announced.

**Project**

**Project**
- README rewritten as a product page with renders of every wheel and editor, in light and dark.
- A 65-second launch film (plus a 9:16 cut and a README loop), made with ElevenLabs audio and Remotion; source in
  `marketing/video/`.
- A watch page for the film on GitHub Pages (https://mustafahalabi.github.io/clementine/), linked from the README.
- `main` is protected: changes from contributors go through pull requests that need CI and the owner's approval.
  Added CONTRIBUTING.md, CODEOWNERS and pull request / issue templates.

## 0.1.0 — 2026-10-22

First public release, Developer ID–signed and notarized. Apple silicon, macOS 14 or later.

**The wheel**
- Hold ⇧ while dragging files for the convert wheel, ⌥⇧ for the tools wheel; drop on a slice, or on the hub to
  cancel. Switching ⇧ / ⌥⇧ mid-drag swaps wheels.
- Click-mode wheel from Finder's right-click › Services (**Convert with Clementine**, **Clementine Tools**) and
  from **Open Files…** in the menu bar.
- Slices you use most come first (per file kind and wheel); Settings › Wheel hides slices you never use.

**Conversions**
- Images (JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, PDF, OCR to TXT; animation kept between GIF and WebP),
  video (MP4, MOV, MKV, AVI, WMV, WebM, GIF, soundtrack to MP3/M4A/WAV), audio (MP3, M4A, WAV, FLAC, OGG, Opus,
  AIFF), documents (PDF, DOCX, TXT, RTF), PDF (TXT, DOCX, PNG/JPG pages), subtitles (SRT ⇄ VTT), archives
  (extract ZIP/TAR/GZ/BZ2/XZ/RAR/7Z, repack, or pack anything as ZIP/TAR/GZIP).

**Tools**
- Compress and Target Size for images, video (two-pass) and audio.
- Image editors: Crop (handles, aspect presets, quarter turns), Redact (pixelate/blur/black, auto-detect faces and
  text), Annotate (arrows, shapes, pen, highlighter, text, undo). Also Resize, Rotate/Flip, Edit (exposure,
  contrast…), Add BG, Read QR, Collage, Make PDF.
- Waveform editors: Trim (audio and video, filmstrip, auto-trim silence, playback), Bleep (drag regions, preview,
  video too), Channels (mono/stereo/swap with per-side volume). Also Speed, Split, Snapshot, Mute, Rotate,
  Normalize, Trim Silence, Join.
- PDF page organizer for Pages and Merge (drag to reorder, rotate, duplicate, delete); Compress, Split, Rotate.
- Metadata editor for images (incl. removing location), audio/video and PDF, saved without re-encoding; Remove
  Metadata.

**App**
- Progress cards with live progress, cancel, and Undo; history (last 50) with **Recent** and **Undo Last
  Conversion** in the menu bar.
- Parallel batches (half the cores for images and documents, two at a time for ffmpeg work).
- Welcome tour, Settings, citrus design with springy motion and Reduce Motion support.
- Bundled ffmpeg/ffprobe (GPL v3) and libwebp tools; Sparkle 2 auto-updates.

**Fixed before release (found by driving the real app)**
- Clicks on a control's exact centre line were swallowed by decorative outlines.
- Dragging a waveform handle or a page thumbnail moved the window instead.
- The welcome tour opened behind other apps; Settings opened partly off-screen and didn't close with Esc.
- The bleep tone played 12 dB quieter than the audio it replaced.
