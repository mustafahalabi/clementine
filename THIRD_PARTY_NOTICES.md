# Third-party notices

Clementine's own source code is in this repository. Release builds of Clementine.app also contain the
third-party software below. This file ships inside the app at `Clementine.app/Contents/Resources/THIRD_PARTY_NOTICES.md`.

| Component | Version | Where in the app | License |
| --- | --- | --- | --- |
| FFmpeg (`ffmpeg`, `ffprobe`) | 9.0.2, static build by Martin Riedl | `Contents/Resources/bin` | **GPL v3 or later** (this build enables GPL components) |
| libwebp tools (`cwebp`, `img2webp`) | 1.6.0, official Google binaries | `Contents/Resources/bin` | BSD 3-Clause + WebM patent grant |
| Sparkle | 2.10.0 | `Contents/Frameworks/Sparkle.framework` | MIT (plus bundled third-party notices) |

`scripts/fetch-tools.sh` downloads the exact binaries listed here and verifies their checksums and signatures.

## FFmpeg

FFmpeg is free software by the FFmpeg developers (https://ffmpeg.org). The binaries Clementine bundles are the
static macOS builds published at https://ffmpeg.martin-riedl.de, signed and notarized by
"Developer ID Application: Martin Riedl (KU3N25YGLU)". They are configured with `--enable-gpl --enable-version3`
and link libx264, libx265, libmp3lame, libopus, libvorbis, libvpx, libaom, dav1d, SVT-AV1, rav1e, libwebp,
OpenSSL and others (the full list is in `ffmpeg -version` and the build's `versions.txt`). The combined work is
therefore licensed under the **GNU General Public License, version 3 or later**.

**What this means for Clementine.** `ffmpeg` and `ffprobe` are separate programs that Clementine runs as
subprocesses; Clementine does not link FFmpeg's libraries. Shipping them alongside the app is "mere aggregation"
under the GPL, so Clementine itself is not GPL-licensed. Anyone redistributing Clementine.app with these
binaries must still honor the GPL for them:

- **Source code:** the FFmpeg 9.0.2 source is at https://ffmpeg.org/releases/ (`ffmpeg-9.0.2.tar.xz`) and
  https://git.ffmpeg.org/ffmpeg.git (tag `n9.0.2`). The build scripts that produced these exact binaries, and the
  versions of every bundled library, are published at https://git.martin-riedl.de/ffmpeg/build-script and
  https://ffmpeg.martin-riedl.de. On request, the maintainers of Clementine will provide the corresponding source
  for the binaries in any Clementine release for at least three years after that release.
- **License text:** https://www.gnu.org/licenses/gpl-3.0.txt
- **No extra restrictions, and you can use your own build:** put your own `ffmpeg`/`ffprobe` (and, if you like,
  `cwebp`/`img2webp`) in a folder and enter its path as **Extra tools folder** in Settings › General (since
  Clementine 0.1.1). Clementine looks in that folder *before* its bundled copies, so your build is used for
  everything while the app stays intact and properly signed; the rows below the field show which file each tool
  resolves to. Any tool missing from your folder still comes from the bundle. Clear the field to go back to the
  bundled tools.
  (Replacing files inside `Clementine.app/Contents/Resources/bin` also works, but it breaks the app's code
  signature, so macOS may refuse to open it; prefer the Settings folder.)

**Want an LGPL-only app?** Build or download an FFmpeg without `--enable-gpl` / `--enable-nonfree` (an "LGPL
build"). You lose libx264/libx265 (use `h264_videotoolbox` / `hevc_videotoolbox` instead) and a few filters;
put the binaries in `vendor/bin/` before running `scripts/bundle.sh`. Patent licensing for codecs such as
H.264/HEVC/AAC is a separate matter from copyright licensing, and is the distributor's responsibility.

## libwebp (cwebp, img2webp)

Official release binaries from https://storage.googleapis.com/downloads.webmproject.org/releases/webp/
(source: https://chromium.googlesource.com/webm/libwebp, tag `v1.6.0`).

```
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

libwebp also comes with an additional royalty-free patent grant from Google for the WebM codecs:
https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0/PATENTS

## Sparkle

https://sparkle-project.org — used for "Check for Updates…". Its full license, including the notices for the
components Sparkle itself bundles, is at https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
