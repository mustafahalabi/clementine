# Testing Clementine

Almost everything is tested headlessly through the binary's own CLI (`Clementine --run`/`--list`, see
[CLI.md](CLI.md)). The tests run the same `BatchRunner` → engine path the wheel uses, on fixtures generated fresh
for every run. Editors and other UI are covered by an off-screen interaction harness (`--ui-test`) and by
off-screen renders. A short manual checklist covers what only a real Mac session can confirm.

```sh
make test       # all the shell suites (scripts/run-tests.sh): runs every suite even after a failure, then a summary
make ui-test    # swift build + .build/debug/Clementine --ui-test
```

Requirements: Xcode toolchain, Homebrew `ffmpeg` (ffmpeg + ffprobe) and `webp` (`gif2webp`, used by the stress
fixtures), plus stock macOS tools (`sips`, `textutil`, `zip`, `tar`, `ditto`, `python3`). The suites need a debug
build for the env-var overrides and `--render-ui`, which is what `swift build` (run by every script) produces.

**Which ffmpeg is tested.** Releases bundle the pinned builds from `scripts/fetch-tools.sh` (ffmpeg 9.0.2,
libwebp 1.6.0). After `make tools` puts them in `vendor/bin`, every suite runs Clementine against them: the shared
setup (`scripts/test-lib.sh`) creates a scratch defaults suite (`CLEMENTINE_DEFAULTS_SUITE`) whose Settings tools
folder is `vendor/bin`, and that folder is searched before anything else. Without `vendor/bin` the CLI finds
Homebrew's tools. Override with `CLEMENTINE_TEST_TOOLS=<dir>` or `CLEMENTINE_TEST_TOOLS=system`. Each suite prints
which it uses (`Clementine uses tools in …`). Fixtures are always made with the `ffmpeg` on `PATH`.

## Shell suites (`scripts/`)

| Suite | Covers | Cases | Runtime* |
|---|---|---|---|
| `smoke-test.sh` | Every action at least once, mostly with defaults: all convert targets (image, media, document, PDF, subtitle, archive), every tool on images, video/audio and PDF. Passes if the run exits 0 and every output path it prints exists and isn't empty (text results must have a body). | 94 | ~12 s |
| `edge-test.sh` | Odd names (quotes, unicode, leading dash, spaces), portrait/odd-sized/rotated video, cover-art MP3s, EXIF orientation + GPS, gray/CMYK/16-bit images, multi-page PDFs and page specs, HTML/RTF/DOC/MD/Latin-1 documents, VTT/CRLF subtitles, archive naming, repacking (incl. `convert.archive.gzip`) and staging, broken input. Asserts on the result. | 89 | ~11 s |
| `stress-test.sh` | Adversarial: timecode/location MOVs, subtitles and two audio tracks in containers, 0.1 s video, audio-only `.mp4`, 0-byte files (and nothing left behind on failure), 12000×8000 and 1×1 images, alpha, Display P3, animations, collage geometry, rotated/cropped/locked PDFs, uppercase/missing extensions, dotted folder names, archive edge cases, odd trim/split/bleep values, `--list` contents. | 162 | ~25 s |
| `test-image-editor.sh` | The Crop/Redact/Annotate engines driven by editor JSON: geometry, rotation, clipping, pixel checks inside/outside boxes, `auto` redaction, each annotation kind, format and animation preservation, error messages, wheel contents for 1 vs 2 images. | 54 | ~6 s |
| `test-waveform.sh` | Channels (layouts, gains, RMS levels per channel, 5.1), Bleep on audio and video (picture copied, tone inside/silence outside, codecs), Trim with editor-style ms times, and `--render-ui` of the Trim/Bleep/Channels editors in light and dark. The renders are skipped only when there's no GUI session (`launchctl managername` isn't `Aqua`, e.g. over ssh); a crash or non-zero exit fails the suite. | 32 | ~75 s (≈65 s is `--render-ui`) |
| `test-pdf-metadata.sh` | Page specs (`3r90`, `r-90`, bare `r90`, duplicates, `1:` prefix, rotation adding up) and merge specs (`2:1-3`, cross-file numbering, error wording). Metadata writers for JPG/PNG/HEIC, MP3/M4A/Opus/FLAC/MOV and PDF: round-trips, clearing, no re-encoding, date/year/track/rating validation. | 70 | ~9 s |
| `test-productivity.sh` | Wheel ordering from `--record`ed usage (per kind and mode, `orderByUsage` off), hidden slices, history (JSON, 50 cap, order, undo, skip-gone, clear), parallel batches (order, concurrency limits via `CLEMENTINE_TRACE_CONCURRENCY`, collision-free names, partial failure exit 1). Uses a scratch defaults suite and support dir. | 34 | ~6 s |
| `test-video.sh` | HLG/PQ fixtures (10-bit HEVC; made with the bundled ffmpeg's zscale when available): tone-mapping to BT.709 for every SDR output (tags plus a luma/saturation check against washed-out passthrough), also through the no-zscale fallback with Homebrew's ffmpeg; HDR kept as `hvc1` 10-bit HEVC by Trim/Speed/Rotate/Join; VideoToolbox used (no x264 SEI) or the x264 fallback when it's missing, `--software`, the Settings toggle, Compress on x264; Join canvas with display-matrix rotation and frame rates; GIF fps/width/target size; Trim/Speed/Rotate on TS/FLV/3GP/MPG. | 55 | ~60 s |
| `test-lifecycle.sh` | Process lifecycle: SIGINT/SIGTERM/SIGHUP during a long encode (exit 128 + n, ffmpeg gone, no output or partial left, power assertion held), a tool that ignores SIGTERM (SIGKILL after the grace period), a second signal, fake tools that crash, get killed or exit 255 by themselves (failures, exit 1), and `--set`/`--hover` validation (exit 2). Fake tools go in through the `toolsDirectory` setting in a scratch defaults suite. | 50 | ~30 s |

\* Measured on an M4 Pro (12 cores), macOS 26.1, warm build: about 585 checks, about 3 minutes in total. Counts
are the `N passed` line of each suite, so they change as cases are added.

**Running.** Each script builds first (`swift build -q`; stress-test retries the build up to 5 times), then runs
from the repo root, so you can call it from anywhere:

```sh
scripts/edge-test.sh
scripts/smoke-test.sh tool.media      # smoke-test only: run actions whose id contains the filter
scripts/run-tests.sh edge-test test-waveform   # several suites, with the summary
```

Only `smoke-test.sh` takes a filter. For the others, comment out sections or copy the one `expect` line you need
(the helpers and fixtures are at the top of each file). Every suite ends with `N passed, M failed`, lists the failures
and exits 1 if any failed.

**Fixtures.** Generated per run in `/tmp/clementine-<suite>.XXXXXX/fixtures` (made by `test_setup` in
`scripts/test-lib.sh`), mostly with ffmpeg `lavfi` sources (`testsrc`, `sine`, `anullsrc`, `anoisesrc`). Images,
PDFs and EXIF/GPS/P3/alpha/locked files come from small Swift helpers that the script writes and compiles
(`swiftc -O`) into the work dir. Those helpers also do the pixel/page checks (`info`, `pix`, `pdfinfo`, `pages`, …).
A work dir is deleted when its suite passes and kept when it fails, so you can inspect the outputs (the script
prints `Work dir kept: …`; `KEEP_WORK=1` always keeps it). Kept dirs older than two days are pruned on later runs.

**Adding a case.** Edge, stress, image-editor, waveform and pdf-metadata share two helpers:

```sh
# expect <name> <assertion…> -- <action args…>
#   The action must exit 0. The assertion is eval'd with $OUT = first stdout line (stress also sets $ALL = all lines).
expect "rotate 90 alone turns clockwise" '[[ "$(dims "$OUT")" == "100 200" ]]' -- tool.image.crop --set 'crop={"rotate":90}' "$F/quad.png"

# expect_error <name> <substring> -- <action args…>
#   The action must fail and its output must contain the substring.
#   In stress-test it's case-insensitive, it rejects raw "ffmpeg failed"-style messages, and it fails
#   if anything new appears in the input folders.
expect_error "pages out of range" "doesn't exist" -- tool.pdf.pages --set pages=99 "$F/long.pdf"
```

Other helpers: `expect_list` (stress: assert on `--list` output with `has <id>`), `check <name> <assertion>`
(productivity), and per-suite probes such as `dims`, `vdims`, `dur`, `near a b [tol]`, `nstreams`, `rms`, `pix`.
In smoke-test, add a `run <action-id> [--set k=v]… <files>` line. Edge and stress read output paths from stdout
only, because system frameworks sometimes log to stderr on CI VMs. Do the same in new assertions.

If a case needs settings or history, call `test_defaults_suite` before `test_setup` (a scratch
`CLEMENTINE_DEFAULTS_SUITE`, deleted on exit) and export `CLEMENTINE_SUPPORT_DIR` as `test-productivity.sh` does.
Never `--record` against the real domain.

## CI (`.github/workflows/ci.yml`)

Runs on pushes to `main`, pull requests and manual dispatch, on `macos-latest` with a 40-minute timeout (one run
per ref; newer pushes cancel older runs). The job is called `test`, which is the required check on `main`.

1. Print the toolchain; restore `.build` (keyed on the Swift version, `Package.resolved` and the sources, falling
   back to the newest build for the same toolchain and packages) and `vendor/bin` (keyed on
   `scripts/fetch-tools.sh`).
2. `make tools` on a cache miss, `brew install ffmpeg webp` (fixtures), `swift build`, `swift build -c release`.
3. All the suites, each its own step. They run even if an earlier suite failed, so the run shows every
   suite's result; any failure fails the job. Clementine uses the bundled tools from `vendor/bin`.
4. `scripts/bundle.sh debug`: the bundled binary's `--help` (Sparkle embeds and links), the tools are in
   `Contents/Resources/bin`, and a Settings tools folder is searched before them.
5. `make ui-test` with `continue-on-error`: an experiment to see whether the off-screen harness runs on GitHub's
   runners. It never fails the job; check its log.

## UI tests (`--ui-test`)

Debug-only (`Sources/Clementine/Testing/`). Real SwiftUI/AppKit windows are opened at x = −8000 (off every screen)
and driven with synthetic `NSEvent`s posted to the app itself, so it doesn't move your mouse and needs no
permissions.

```sh
make ui-test                              # every suite
.build/debug/Clementine --ui-test crop    # suites whose name contains any of the words (case-insensitive)
```

Output is one line per suite, `✓`/`✗` per check, then `N passed, M failed` (exit 0/1). Current suites: `harness`
(proves a button press, a drag and typing reach SwiftUI), `job cards` (a failed card with a long error is capped
behind "Show details…", and the next card stacks below it, before and after opening the details, without
covering its Close button; the stack is parked off-screen through `ProgressPanel.stackArea`), `onboarding seen`
(the tour isn't marked seen until it has been shown and closed), `accent contrast` (white on the accent stops ≥
3:1 for bold labels, ≥ 7:1 with Increase Contrast; the deep accent ≥ 4.5:1; accent text on cream and charcoal),
`error copy` (brew hints only without bundled tools, `brew install webp` for img2webp, plain-sentence ffmpeg
failures, the "Text (OCR)" slice), `midline` (clicks on a control's exact center land, across button styles and
the chip picker) and `lifecycle quit` (a running encode stopped the way quitting stops it: no tool, job or partial
output left; it runs last because it refuses tool launches afterwards): 51 checks,
about 25 s.

**Writing a suite.** Add a file in `Sources/Clementine/Testing/` that extends `UITest` with
`static var <area>: [Suite]`, and append it to `UITest.all` (kept sorted by area).

```swift
extension UITest {
    static var crop: [Suite] {
        [Suite(name: "crop") { t in
            let url = t.makeImage()                                   // PNG fixture in t.scratch
            var applied: ParamValues?
            CropEditor.present([url], ActionRegistry.find("tool.image.crop")!.defaults) { applied = $0 }
            // Editor windows are titled "<Title> – <file name>".
            guard let window = t.appWindow(titled: "Crop") else { return t.check(false, "crop window opens") }
            t.click(id: "crop.apply", in: window)                     // after tagging the button .uiTestID("crop.apply")
            t.check(t.wait { applied != nil }, "Apply hands the crop JSON back")
        }]
    }
}
```

Few app views are tagged yet (the job card's `job.close.<title>`, `job.undo.<title>`, `job.details.<title>`,
and `settings.launchAtLogin`), so tag the controls a new suite needs as you go.

`UITestContext` (`t`) provides:

- Windows: `open(view, size:)` hosts a view in a Clementine panel, `adopt(window)` parks an app-created
  window off-screen, `appWindow(titled:)` finds and adopts one. Windows close after each suite.
- Lookups: `frame(id:in:)` returns the frame of a view tagged `.uiTestID("…")`. `frame(of: "Label", in:)` looks up
  by visible label through Accessibility. `point(x, yFromTop, in:)` takes layout-style coordinates.
- Input: `click(_:in:count:modifiers:)`, `click(id:in:)`, `drag(from:to:in:steps:modifiers:)`, `hover`, `type`,
  `key(_:keyCode:modifiers:in:)`, `pressReturn`, `pressEscape`.
- Time: `settle(seconds)`, `wait(timeout) { condition }`.
- Checks and fixtures: `check(cond, name)`, `skip(name)`, `snapshot(window, name)` → `scratch/<name>.png`,
  `makeImage(name, width:, height:)`, `shell("ffmpeg …")` (runs in `scratch`).

**Tag controls** with `.uiTestID("area.thing")`. In debug builds it records the view's global frame in
`UITestRegistry`. In release builds it does nothing.

**Gotchas**

- **Queue follow-up events before the mouse-down.** AppKit controls (text fields, sliders) run their own tracking
  loop inside `mouseDown` and pull the rest of the gesture from the event queue. `click` and `drag` therefore
  `postEvent` the drags and mouse-up first, then send the mouse-down. If you hand-roll events, do the same, or the
  control waits for a mouse-up that never comes.
- **`settle` is the run loop.** There's no `NSApplication.run()` in test mode. `settle` pulls and dispatches events
  until the time is up, and `wait` calls it in a loop. After anything asynchronous (a window opening, a job
  finishing, an animation), `wait` for a condition instead of assuming it happened.
- **Typing goes through the field editor.** Synthetic key events into an off-screen text field can stall text
  input, so `type` inserts into the window's first responder `NSTextView` directly. Click the field first to focus
  it. Without a focused field, the check fails. Use `key` for Return, Esc, arrows and shortcuts (they go through
  `performKeyEquivalent` first). Key codes: return 36, escape 53, delete 51, forward delete 117, tab 48,
  left/right/down/up 123/124/125/126.
- **Accessibility lookup only when trusted.** `frame(of:)` returns nil unless the process is trusted for
  Accessibility (System Settings › Privacy & Security › Accessibility, for your terminal). Prefer `uiTestID`.
- `Frame.center` is nudged 0.3 pt off the exact midpoint, because SwiftUI hit-testing can miss on an integral
  midline (that's what the `midline` suite guards).
- Run it on an otherwise idle machine. With the shell suites running in parallel, the `harness` button-press
  check failed once and then passed on an idle re-run.

## Visual checks

| Command | What you get |
|---|---|
| `.build/debug/Clementine --render-ui /tmp/ui photo.jpg voice.m4a clip.mp4` | Every job window, Settings tab, onboarding page and editor, light and dark, as PNGs (~70 s with media). Debug only. Prefix `CLEMENTINE_INCREASE_CONTRAST=1` to render the Increase Contrast accents. |
| `.build/debug/Clementine --render-wheel /tmp/wheel.png [--tools] [--hover N] [--light] [--click [--chip]] photo.jpg` | The wheel for those files as a PNG (~2 s). Works in any build. |
| `build/Clementine.app/Contents/MacOS/Clementine --demo-wheel [--tools] [--click] [--hover N] photo.jpg` | The live wheel at screen center without a drag, with real materials and animation. Bundle it first with `scripts/bundle.sh debug`, and quit any running Clementine first. |

Renders draw materials flat. Use `--demo-wheel` or the real app for vibrancy and blur. File names are listed in
[CLI.md](CLI.md#--render-ui-dir-image-audio-video).

## Manual verification on a real Mac

These depend on a GUI session, system services, the user's permissions or Apple's servers, so no script covers
them. Test the bundled app (`make install` copies it to `/Applications`):

- [ ] **Finder drag + ⇧**: drag a file in Finder and hold ⇧. The convert wheel appears at the pointer. Drop on a
      slice, and the output appears next to the original (revealed in Finder if enabled).
- [ ] **⌥⇧ mid-drag**: switching modifiers during the drag swaps to the tools wheel and back. Releasing the
      modifiers, or dropping elsewhere, hides the wheel and leaves Finder's drop behaving normally.
- [ ] Multi-file drags (batch tools appear, progress card counts up, Undo on the finished card), a folder
      (archives only), parameter sheets and each editor window opening from a slice.
- [ ] **Services from /Applications**: right-click files › Services (or Quick Actions) › *Convert with Clementine*
      / *Clementine Tools* opens the click-mode wheel at the pointer. Services register from the installed bundle.
      If they're missing, relaunch the app, and log out if needed.
- [ ] **Sparkle**: *Check for Updates…* in the menu works from the installed, signed app. From `.build/debug`, or
      with the placeholder `SUPublicEDKey`, it explains that updates are off instead of checking.
- [ ] **Notarized build**: `CODESIGN_IDENTITY=… NOTARY_PROFILE=… scripts/release.sh`. Then on a clean account or
      Mac, open the DMG and launch with no Gatekeeper warning. `spctl -a -vv /Applications/Clementine.app` should
      say *Notarized Developer ID*, and `xcrun stapler validate` should pass. Bundled ffmpeg runs (no Homebrew on PATH).
- [ ] First launch: the onboarding window appears, and drags are detected without any permission prompt (the
      drag monitor is a global mouse-down monitor plus pasteboard polling). Launch at login is on (Settings and
      System Settings › General › Login Items) when the app runs from /Applications. Quitting before the tour
      appears brings it back on the next launch.
- [ ] **Reopen**: with Clementine running, open it again from Finder or Spotlight. Settings comes forward (the
      welcome tour instead if it was never finished or closed).
- [ ] **Idle CPU**: with the app idle and no wheel showing, `top -l 5 -pid $(pgrep -x Clementine)` stays at ~0 %.
- [ ] **VoiceOver**: with the click-mode wheel open (Services), VoiceOver reads "Convert wheel for …" and the
      highlighted slice as the arrow keys move; a finished or failed job is announced.

### Driving the real app from a script

If you automate the steps above (an agent, `osascript`, `cliclick`, CGEvent tools):

- Synthetic mouse and keyboard input to other apps needs **Accessibility permission** for the process sending
  it (your terminal, or the agent host). Without it, events are dropped silently.
- Use **real virtual key codes** (Return 36, Esc 53, Tab 48, arrows 123–126, ⇧ 56, ⌥ 58). For a ⇧/⌥⇧ drag, hold
  the modifier key down for the whole mouse-down → drag → mouse-up sequence, and move in steps. The wheel opens
  on a drag in progress, not on a jump.
- **zsh doesn't word-split** unquoted variables: with `ARGS="--tools photo.jpg"`, `$BIN $ARGS` passes one argument.
  Use an array (`args=(--tools photo.jpg); $BIN $args`) or `${=ARGS}`, and quote paths with spaces.
- **Don't send Return unless a Clementine window is frontmost and focused.** If Finder is frontmost with a file
  selected, Return starts renaming it, and the next keystrokes overwrite the filename. Check the frontmost app first,
  and use Esc, or click the button, when unsure.
