# Changelog

## Unreleased

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
