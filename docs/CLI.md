# Clementine command line

The `Clementine` binary is the menu-bar app and also a headless runner for every wheel action. It's the same
code path the app uses (`ActionRegistry` → `BatchRunner` → engines), which is how every test suite drives it.

```sh
swift build                       # debug build: .build/debug/Clementine (includes the debug-only modes)
BIN=.build/debug/Clementine
# or, from a bundle:
BIN=build/Clementine.app/Contents/MacOS/Clementine
```

When the first argument is one of `--list --run --history --undo --clear-history --render-wheel --help`, the
binary runs headlessly (no Dock icon, no menu-bar item) and exits. With anything else, or no arguments, it
launches the app. Debug builds check `--render-ui` and `--ui-test` before that (see [Debug-only modes](#debug-only-modes)).

Engines find ffmpeg/ffprobe/cwebp in the bundle's `Contents/Resources/bin`, then the Settings tools folder,
then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`. A plain `swift build` binary has no bundled
tools, so it needs Homebrew's `ffmpeg` (and `webp` for animated WebP).

## Modes

### `--list <file>…`

Prints both wheels as they would appear for this selection:

```
$ $BIN --list photo.png
Convert (⇧)
  convert.image.jpeg           JPG
  …
Tools (⌥⇧)
  tool.compress                Compress
  …
```

- Shows visible slices in wheel order (most used first, see [Usage and history](#usage-history-and-settings)),
  at most 12 per wheel, then any slices hidden in Settings › Wheel, marked `(hidden)`.
- An action appears only if every file matches its accepted kinds and the file count is within its min/max inputs.
- The archive actions (`archive.zip/tar/gzip`) are added to the convert wheel when nothing else applies, or when
  every item is a folder or an unknown type. A mix like image + audio therefore gets archives on ⇧ and only the
  shared tools (Compress, Target Size, Metadata, Remove Metadata) on ⌥⇧.
- No files: prints usage and exits 2.

### `--run <action-id> [--set key=value]… [--record] <file>…`

Runs one action on the files. Options and files can be mixed in any order after the action id.

```sh
$BIN --run convert.image.webp photo.heic
$BIN --run tool.fit --set megabytes=1.5 photo.heic
$BIN --run tool.compress --set "level=best quality" a.jpg b.png
$BIN --run tool.pdf.pages --set "pages=3r90, 1-2, 5-" report.pdf
$BIN --run tool.image.crop --set 'crop={"x":0,"y":0,"w":800,"h":600}' photo.jpg
```

**`--set key=value`** sets one parameter. The value is everything after the first `=` (so JSON and specs with `=`
or spaces are fine, if quoted for the shell). Parsing depends on the parameter's type:

| Type | Parsing | Out-of-range / bad value |
|---|---|---|
| number | `Double(value)` | Not a finite number (`abc`, empty, `nan`, `inf`) → usage error. The parameter's range is **not** enforced: the engine checks the value with a specific message (Split under 1 s, an impossibly small Target Size) or accepts it (Target Size below the sheet's 0.05 MB works for small files). |
| slider | `Double(value)` | Not a finite number, or outside the slider's range (bounds included, e.g. `exposure` −2…2) → usage error. |
| choice | An integer index (0-based), or else an option label matched case-insensitively (`style=black`, `channels=swap`, `"level=best quality"`, `speed=2×`) | An index out of range (`speed=99`, `level=-1`) or an unknown label → usage error listing every `index = label`. |
| text | Taken verbatim (JSON, page specs, time codes); may be empty | Validated by the engine, which fails with a readable message |

Usage errors print one line to stderr and exit 2 before anything runs: `speed=99: not a valid choice; use an
index or label: 0 = 0.25×, …`, `exposure=5: must be between -2 and 2`, `unknown parameter size for tool.fit
(valid keys: megabytes)`, `--set needs key=value, got "megabytes"` (also for `--set ""` and a trailing `--set`),
and `unknown option --recrod` for any other `--` argument that isn't an existing file. Parameters you don't set
keep their defaults.

**`--record`** also does what a wheel drop does: it updates usage counts (wheel ordering) and, if the run produced
files, adds a history entry. Without it, `--run` leaves no trace.

**Batches.** Non-batch actions run once per file, several at a time: half the active cores for image and
document work, at most 2 when any input is audio/video (ffmpeg is already multithreaded), and an action's own
`maxConcurrent` if it has one (`convert.image.mp4` = 2). Batch actions (`batch: yes` below) run once with every
file. Output names are reserved while a batch runs, so `dup.png` + `dup.bmp` → JPG gives `dup.jpg` and `dup 2.jpg`.
`CLEMENTINE_TRACE_CONCURRENCY=1` (debug builds) prints `concurrency: <peak> of <limit> for <n> units` to stderr.

**Output.** Printed after everything has finished, in input order (not finish order):

- files: one absolute path per line on stdout (a folder path for multi-file results such as Split, PDF → PNG
  with several pages, or 10 snapshots);
- text results (Read QR, Metadata without `fields`): `== <file name> ==` followed by the body on stdout;
- failures: `error: <file name>: <message>` on stderr. Other files still finish.

Outputs go next to the input and never overwrite: `photo.jpg`, `photo (compressed).jpg`, `photo (compressed) 2.jpg`.
Names differing only by case count as clashes, so `Clip.mov` + `clip.ts` → MP4 give `Clip.mp4` and `clip 2.mp4`.

**Interrupting.** SIGINT (Ctrl-C), SIGTERM and SIGHUP stop the run cleanly: tools such as ffmpeg run in their
own process group, so Clementine terminates them itself (SIGTERM, then SIGKILL after 3 s for one that ignores
it), each unfinished output is deleted, and every unfinished file is reported as `cancelled: <file name>` on
stderr. Files that had already finished are complete and printed as usual. If the work hasn't unwound within
10 s, remaining tools are killed and outputs still being written are deleted. A second signal skips the wait.

A tool that dies from a signal nobody asked for (a crash, an outside `kill`) is a failure, not a cancellation:
`error: clip.mov: ffmpeg failed: … ffmpeg stopped unexpectedly (Segmentation fault: 11)`.

While `--run` (or a job in the app) is running, Clementine holds a power assertion ("Clementine is converting
files", see `pmset -g assertions`) so the Mac doesn't idle to sleep mid-encode.

**Exit codes**

| Code | Meaning |
|---|---|
| 0 | Every file succeeded (a text result like "No QR code … found" counts as success) |
| 1 | At least one file failed (including a tool that crashed or was killed from outside), or `--undo` had nothing to undo |
| 2 | Usage error: unknown action id (usage printed on stdout), unknown parameter or option, a `--set` value that doesn't fit the parameter, fewer files than the action's minimum (`<id> needs at least N files`), a `--render-wheel` without its arguments or with `--hover` not followed by a number |
| 128 + n | Interrupted by signal n: 130 for SIGINT (Ctrl-C), 143 for SIGTERM, 129 for SIGHUP |

Hidden actions still run from the CLI. `maxInputs` is only a wheel rule: `--run` doesn't check it, but
single-image editors (Redact, Annotate) process each file separately.

### `--history`

One line per entry, newest first, tab-separated:
`<ISO-8601 date>  <action id>  <title>  <inputs joined by |>  <outputs joined by |>`.

History holds the last 50 jobs that produced files (text-only results aren't recorded), stored in
`~/Library/Application Support/Clementine/history.json`.

### `--undo`

Moves the outputs of the newest entry whose files still exist to the Trash, removes that entry, and prints where
each file went (for example `~/.Trash/clip.mp3`). Entries whose outputs are all gone are skipped. Outputs that
changed after the job wrote them (edited, or replaced by another file) are left in place with a note on stderr;
if none could be trashed it prints `error: <names> changed after Clementine made it…` and exits 1. Prints
`nothing to undo` and exits 1 when there's nothing to undo.

### `--clear-history`

Empties the history. Exit 0.

### `--render-wheel <out.png> [--tools] [--hover N] [--light] [--click [--chip]] <file>…`

A design aid that draws the wheel for these files to a PNG without showing anything on screen. Works in release builds too.

| Flag | Effect |
|---|---|
| `--tools` | The ⌥⇧ tools wheel (default: convert) |
| `--hover N` | Highlights slice N (0-based, wheel order) |
| `--light` | Light appearance on a light backdrop (default: dark) |
| `--click` | Click-mode wheel (Services / Open Files…), with its chip |
| `--chip` | With `--click`: the chip in its hovered state |

The output path must come first. It waits about 2 s for the Quick Look thumbnail and the open animation, prints
the output path and exits 0. With fewer than 2 arguments it prints usage and exits 2; `--hover` without a
non-negative number after it exits 2. Materials render flat.

### `--help`

Prints usage, exit 0. (An unrecognized first argument launches the app instead.)

## Debug-only modes

These are compiled only in debug builds (`#if DEBUG`): `swift build`, or `scripts/bundle.sh debug`.

### `--render-ui <dir> [image] [audio] [video]`

Renders the job windows, Settings, onboarding and every editor to `<dir>/<name>-light.png` and `<name>-dark.png`
off-screen, then exits 0. The optional files feed the parameter-sheet preview (image) and the waveform editors
(audio/video, with real peaks). PDF and image-editor fixtures are generated. Names include `progress`,
`progress-undo`, `parameters`, `parameters-preview`, `result-qr`, `result-metadata`, `settings`, `settings-wheel`,
`settings-wheel-tools`, `onboarding-N`, `trim-loading`, `trim-audio`, `trim-audio-silence`, `trim-video`, `bleep`,
`bleep-empty`, `channels-mono`, `channels-swap`, `pages`, `pages-drag`, `merge`, `metadata-image`, `metadata-image-all`, `metadata-pdf`,
`editor-crop`, `editor-crop-turning`, `editor-crop-turned`, `editor-redact`, `editor-redact-blur`, `editor-annotate`,
`editor-annotate-typing`.

### `--ui-test [word…]`

Runs the interaction-test suites: real windows parked off-screen, driven with synthetic events. With words, it runs
only suites whose name contains one of them (case-insensitive). Prints `✓`/`✗` per check and
`N passed, M failed`, then exits 0 or 1. See [TESTING.md](TESTING.md#ui-tests---ui-test).

### `--demo-wheel [--tools] [--click] [--hover N] <file>…` (app launch flag)

Not a headless mode. The app launches normally and shows the live wheel at the center of the main screen without a
drag, for working on its looks and motion. `--click` shows the clickable (Services-style) wheel; `--hover N`
highlights a slice. The wheel needs the app's run loop, so use the bundle:

```sh
scripts/bundle.sh debug
build/Clementine.app/Contents/MacOS/Clementine --demo-wheel --tools --hover 2 ~/Desktop/photo.jpg
```

(`--demo-wheel` is read in `WheelController.start()`, so it isn't actually `#if DEBUG`-gated.)

### Environment variables (debug builds)

| Variable | Effect |
|---|---|
| `CLEMENTINE_DEFAULTS_SUITE=<suite>` | Uses that UserDefaults suite instead of the app's domain (hidden slices, usage, `orderByUsage`, settings). The bundle reads `app.clementine.Clementine`. The unbundled binary otherwise uses `~/Library/Preferences/Clementine.plist`. |
| `CLEMENTINE_SUPPORT_DIR=<dir>` | Replaces `~/Library/Application Support/Clementine` (where `history.json` lives) |
| `CLEMENTINE_TRACE_CONCURRENCY=1` | Logs batch concurrency to stderr (see above) |

Use the first two whenever you `--record`, `--undo` or change defaults in tests, so real settings and history
stay untouched. `scripts/test-productivity.sh` does this. Note that `--undo` still uses the real Trash.

### Usage, history and settings

- Wheel order: each `--record`ed run adds 1 to a score per (file kind, wheel) bucket, e.g. `image.tools`,
  `mixed.convert`. Scores halve every 14 days. Equal scores keep catalog order. Turn this off with
  `defaults write <domain> orderByUsage -bool false`.
- Hidden slices: `defaults write <domain> hiddenActions -array tool.image.qr convert.image.heic`.

## File kinds

Classified by extension (a directory is always `folder`, whatever its name, including `.app` and `Vacation.mov/`):

| Kind | Extensions |
|---|---|
| subtitle | srt, vtt |
| archive | zip, tar, gz, tgz, rar, 7z, bz2, tbz, tbz2, xz, txz |
| pdf | pdf |
| document | docx, doc, txt, rtf, md, html, htm, odt, plus anything else conforming to public.text |
| image | svg, plus anything conforming to public.image (jpg, png, heic, webp, gif, tiff, …) |
| video | webm, mkv, wmv, avi, flv, m4v, mpg, mpeg, 3gp, plus public.movie (mp4, mov, …) |
| audio | opus, ogg, oga, flac, wma, plus public.audio (mp3, wav, m4a, aiff, …) |
| other | everything else, including files without an extension |

Extensions are compared lowercased, so `PHOTO.JPG` gets no JPG slice. An audio-only `.mp4` is classified as video.

## Action catalog

Generated from `Sources/Clementine/Actions/ConvertActions.swift` and `ToolActions.swift`. Inputs are min–max
files per run; *batch* means one run with every file (one output), otherwise one run per file. Parameters list
`key` (type) default, then allowed values. Choice indices are 0-based.

### Convert wheel (⇧)

None of these take parameters.

| id | title | accepts | inputs | batch |
|---|---|---|---|---|
| `convert.image.jpeg` | JPG | image, not jpg/jpeg/jpe | 1+ | no |
| `convert.image.png` | PNG | image, not png | 1+ | no |
| `convert.image.heic` | HEIC | image, not heic/heif | 1+ | no |
| `convert.image.webp` | WEBP | image, not webp | 1+ | no |
| `convert.image.avif` | AVIF | image, not avif | 1+ | no |
| `convert.image.tiff` | TIFF | image, not tif/tiff | 1+ | no |
| `convert.image.bmp` | BMP | image, not bmp | 1+ | no |
| `convert.image.gif` | GIF | image, not gif | 1+ | no |
| `convert.image.pdf` | PDF | image, not pdf (always true: pdf is its own kind) | 1+ | no |
| `convert.image.txt` | Text (OCR) | image except svg (OCR via Vision; fails with "No text found") | 1+ | no |
| `convert.image.mp4` | MP4 | gif, or animated webp (max 2 at once) | 1+ | no |
| `convert.media.mp4` | MP4 | video, not mp4/m4v | 1+ | no |
| `convert.media.mov` `.mkv` `.avi` `.wmv` `.webm` `.gif` | MOV, MKV, AVI, WMV, WEBM, GIF | video, not the same format | 1+ | no |
| `convert.media.mp3` `.m4a` `.wav` | MP3, M4A, WAV | audio or video (extracts the soundtrack), not the same format (m4a also skips aac) | 1+ | no |
| `convert.media.flac` `.ogg` `.opus` `.aiff` | FLAC, OGG, OPUS, AIFF | audio, not the same format (ogg skips oga, aiff skips aif) | 1+ | no |
| `convert.document.pdf` `.docx` `.txt` `.rtf` | PDF, DOCX, TXT, RTF | document, not the same extension | 1+ | no |
| `convert.pdf.txt` | TXT | pdf | 1+ | no |
| `convert.pdf.docx` | DOCX | pdf | 1+ | no |
| `convert.pdf.png` | PNG | pdf (one image per page; a folder when several) | 1+ | no |
| `convert.pdf.jpeg` | JPG | pdf (as above) | 1+ | no |
| `convert.subtitle.srt` `.vtt` | SRT, VTT | subtitle, not the same extension | 1+ | no |
| `convert.archive.extract` | Extract | archive | 1+ | no |
| `convert.archive.zip` | ZIP | archive, not zip | 1+ | no |
| `convert.archive.tar` | TAR | archive, not tar | 1+ | no |
| `convert.archive.gzip` | GZIP | archive, not gz/tgz | 1+ | no |
| `archive.zip` `archive.tar` `archive.gzip` | ZIP, TAR, GZIP | anything (fallback, see `--list`) | 1+ | **yes** |

Documents: HTML is converted fully offline. Remote images, stylesheets, fonts, frames, `<base>`, meta refresh and
scripts are removed before import. Relative, `file:` and `data:` images still load. Plain text and subtitles are
read as UTF-8, UTF-16/32 (BOM, or BOM-less UTF-16) or Windows-1252. PDFs use the system's default paper size with 1"
margins. A folder that isn't writable fails at once with "the folder isn't writable".

Extracting (and repacking, which extracts first) fails with `<name> expands to far more than an archive of its size
should…` when the contents would exceed 250× the archive's size (and 1 GiB), or with `There isn't enough free
space…` when they'd leave less than 512 MB free; nothing is left behind. Symlinks pointing outside the extracted
items are dropped. Created ZIPs mark non-ASCII names as UTF-8.

### Tools wheel (⌥⇧)

Listed in wheel order. *Editor* means the app opens a custom window, which produces the same `--set` values.

| id | title | accepts | inputs | batch | parameters |
|---|---|---|---|---|---|
| `tool.compress` | Compress | image, video, audio | 1+ | no | `level` (choice) 1: 0 Best quality, 1 Balanced, 2 Smallest |
| `tool.pdf.compress` | Compress | pdf | 1+ | no | none |
| `tool.fit` | Target Size | image, video, audio | 1+ | no | `megabytes` (number, MB) 5, range 0.05–4000 |
| `tool.image.resize` | Resize | image | 1+ | no | `size` (choice) 1: 0 75%, 1 50%, 2 25%, 3 Max 3840 px, 4 Max 1920 px, 5 Max 1280 px |
| `tool.image.crop` | Crop (editor) | image | 1+ | no | `crop` (text, JSON) empty; `aspect` (choice) 0: 0 Square 1:1, 1 4:5, 2 4:3, 3 3:2, 4 16:9, 5 9:16. With `crop` empty, it crops centered to `aspect`. |
| `tool.image.rotate` | Rotate | image | 1+ | no | `rotation` (choice) 0: 0 90° clockwise, 1 90° counterclockwise, 2 180°, 3 Flip horizontally, 4 Flip vertically |
| `tool.image.adjust` | Edit (live preview) | image | 1+ | no | sliders: `exposure` 0 (−2…2), `brightness` 0 (−0.5…0.5), `contrast` 1 (0.5…1.5), `saturation` 1 (0…2), `highlights` 1 (0…1), `shadows` 0 (−1…1) |
| `tool.image.redact` | Redact (editor) | image | 1–1 | no | `boxes` (text, JSON or `auto`) empty, required; `style` (choice) 0: 0 Pixelate, 1 Blur, 2 Black |
| `tool.image.annotate` | Annotate (editor) | image | 1–1 | no | `shapes` (text, JSON) empty, required |
| `tool.image.background` | Add BG (live preview) | image | 1+ | no | `background` (choice) 0: 0 Sunset, 1 Ocean, 2 Mint, 3 Lavender, 4 Sky, 5 White, 6 Graphite; `padding` (slider) 0.08 (0…0.3, fraction of the long edge); `corners` (slider) 0.02 (0…0.1); `shadow` (choice) 0: 0 On, 1 Off |
| `tool.image.qr` | Read QR | image | 1+ | no | none. Text result. |
| `tool.image.collage` | Collage | image | 2+ | **yes** | `layout` (choice) 0: 0 Grid, 1 Row, 2 Column |
| `tool.image.pdf` | Make PDF | image | 2+ | **yes** | none |
| `tool.media.trim` | Trim (editor) | video, audio | 1+ | no | `start` (text, time) `0:00`; `end` (text, time) empty = end of file |
| `tool.media.speed` | Speed | video, audio | 1+ | no | `speed` (choice) 5: 0 0.25×, 1 0.5×, 2 0.75×, 3 1.25×, 4 1.5×, 5 2×, 6 3×, 7 4× |
| `tool.media.split` | Split | video, audio | 1+ | no | `seconds` (number, sec) 60, range 1–36000. Copies streams, so cuts land on keyframes. |
| `tool.video.snapshot` | Snapshot | video | 1+ | no | `frames` (choice) 0: 0 Middle frame, 1 First frame, 2 10 across the video (folder) |
| `tool.video.mute` | Mute | video | 1+ | no | none |
| `tool.video.rotate` | Rotate | video | 1+ | no | `rotation` (choice) 0: 0 90° clockwise, 1 90° counterclockwise, 2 180°, 3 Flip horizontally |
| `tool.video.join` | Join | video | 2+ | **yes** | none |
| `tool.audio.normalize` | Normalize | audio | 1+ | no | none (loudnorm to −16 LUFS) |
| `tool.audio.silence` | Trim Silence | audio | 1+ | no | none (cuts leading/trailing silence under −50 dB) |
| `tool.audio.channels` | Channels (editor) | audio | 1+ | no | `channels` (choice) 0: 0 Mono, 1 Stereo, 2 Swap; `left` (slider) 1 (0…2); `right` (slider) 1 (0…2) |
| `tool.audio.bleep` | Bleep (editor) | audio, video | 1+ | no | `ranges` (text, time ranges) empty, required |
| `tool.audio.join` | Join | audio | 2+ | **yes** | none (output takes the first file's format) |
| `tool.pdf.pages` | Pages (editor) | pdf | 1+ | no | `pages` (text, page spec) empty, required |
| `tool.pdf.split` | Split | pdf | 1+ | no | none (one PDF per page, in a folder) |
| `tool.pdf.rotate` | Rotate | pdf | 1+ | no | `rotation` (choice) 0: 0 90° clockwise, 1 90° counterclockwise, 2 180° (adds to each page's rotation) |
| `tool.pdf.merge` | Merge (editor) | pdf | 2+ | **yes** | `pages` (text, page spec) empty = every page of every file, in order |
| `tool.metadata` | Metadata (editor) | image, video, audio, pdf | 1+ | no | `fields` (text, JSON) empty. With it empty, the run shows all metadata as a text result. Otherwise it saves an `(edited)` copy. |
| `tool.metadata.strip` | Remove Metadata | image, video, audio, pdf | 1+ | no | none |

The wheel shows at most 12 slices. A single image matches exactly 12 tools. With two or more images, Redact and
Annotate drop out and Collage and Make PDF come in.

### Text parameter formats

All coordinates are pixels of the **upright** image (EXIF orientation already applied), origin top-left.

**`crop`** (`tool.image.crop`): `{"x":0,"y":0,"w":800,"h":600,"rotate":0}`. Every key is optional. `rotate`
(clockwise degrees, multiple of 90; negatives allowed, `-90` = `270`) is applied first, and the rectangle is in
the rotated image. Missing `x`/`y` default to 0, and missing `w`/`h` run to the edge, so `{"rotate":90}` only turns
the image (output suffix `(rotated)` instead of `(cropped)`). Values are rounded and the rectangle is clipped to the
image. Errors: non-positive size, rectangle fully outside, rotation not a multiple of 90, bad JSON (`Expected JSON like …`).

**`boxes`** (`tool.image.redact`): `[{"x":10,"y":20,"w":300,"h":40}, …]`, or `auto` (also `"auto"`) to detect faces
and lines of text with Vision. Boxes need positive `w`/`h` and at least one must overlap the image. An empty
list, or `auto` that finds nothing, fails with "Nothing to redact". The default empty value fails as invalid JSON.
The redacted copy also drops identifying metadata: GPS, maker notes, serial numbers, owner name, EXIF user comment,
IPTC location and Photoshop resources. Orientation, colour profile and capture settings stay. (Compress keeps all
metadata on purpose; use `tool.metadata.strip` to remove it.)

**`shapes`** (`tool.image.annotate`): a JSON array of
`{"kind": K, "points": [[x,y], …], "color": "#RRGGBB", "width": W, "text": "…"}`.

| kind | points | notes |
|---|---|---|
| `arrow` | ≥ 2: from first to last | head scales with width |
| `rectangle`, `ellipse` | ≥ 2: two corners (first and last) | outline only |
| `pen` | ≥ 1, smoothed through all | |
| `highlighter` | ≥ 1 | 40% opacity, 3× width |
| `text` | ≥ 1: top-left of the text | `text` required and non-empty; `width` is the font size |

`color` defaults to `#FF9A3C`, `width` to 8 (must be > 0). An empty array fails with "There are no annotations to draw".

**`fields`** (`tool.metadata`): a JSON object of field → value. Keys you leave out are unchanged, and `""` or `null`
clears a field. Values may be strings, numbers, booleans or (keywords) arrays. Nothing is re-encoded: the output
is `<name> (edited).<ext>`.

| File | Keys |
|---|---|
| image | `title`, `description`, `artist`, `copyright`, `keywords` (array or comma-separated), `date`, `rating` (0–5), `removeLocation` (true drops GPS only) |
| audio / video | `title`, `artist`, `album`, `album_artist`, `year` (`2026` or `2026-07-14`), `genre`, `track` (`3` or `3/12`), `comment` |
| pdf | `title`, `author`, `subject`, `keywords`, `creator` |

Dates accept `2026-07-14`, `2026-07-14 18:42[:09]`, `2026-07-14T18:42:09` and EXIF `2026:07:14 18:42:09`. Impossible
dates (Feb 30) are rejected. An unknown key fails and lists the valid ones. Formats that can't be edited without
re-encoding (WebP, GIF, AVIF, animated PNG, …) fail with an explanation.

**`pages`** (`tool.pdf.pages`, `tool.pdf.merge`): comma-separated items, kept in the listed order (duplicates allowed):

| Item | Meaning |
|---|---|
| `3` | page 3 |
| `1-3`, `3-1` | a range; reversed if start > end. Spaces are allowed (`1 - 3`) |
| `5-`, `-2`, `-` | to the end, from the start, all pages |
| `…r90`, `r180`, `r270`, `r-90` | rotate those pages clockwise (`R` also works, spaces allowed: `4 R 90`). `r360` = no rotation. Adds to the page's own rotation. A bare `r90` rotates every page. |
| `2:3`, `2:1-4`, `2:` | merge: page(s) of file 2 (files are numbered 1… in the order given); `2:` = all of file 2 |

In merge, plain numbers count through all files back to back (with a 5-page and a 2-page file, `6` is file 2
page 1). On a single PDF, `1:` is accepted and other file numbers fail ("Only one PDF is open"). Empty items
(`1,,3`) are ignored. An empty spec fails for Pages and means "everything" for Merge. Errors name the problem
("Page 9 doesn't exist. This PDF has 5 pages.", "Use r90, r180 or r270").

**Times** (`tool.media.trim` `start`/`end`): seconds, `m:ss` or `h:mm:ss`, with an optional fraction using a dot:
`90`, `1:30`, `0:01:30.5`, `0:02.600`. Negative values and comma decimals are rejected. An `end` past the duration
means end of file. `start` must be before the end of the file and before `end`.

**Ranges** (`tool.audio.bleep` `ranges`): comma-separated `start-end` pairs in the same time format, with end > start:
`0:05-0:06, 1:10-1:12`, `1-2,3-3.5`, `0:01.250-0:01.900`. Open ranges (`5-`) are rejected. Ranges past the end are
harmless. The beep is a 1 kHz tone. On video, the picture is copied, not re-encoded. Fails if the file has no audio track.

**Channels** (`tool.audio.channels`): `channels=mono|stereo|swap` (or 0/1/2). `left`/`right` are per-side gains
(1 = unchanged, 0.5 ≈ −6 dB, 0 = silent; the engine clamps to 0…4). In Swap, the gains apply to the output sides.
Mono input feeds both sides, and more than two channels are downmixed to stereo first. Output suffix:
`(mono)`, `(stereo)` or `(swapped)`.
