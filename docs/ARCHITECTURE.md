# Clementine architecture

For developers (and agents) joining the project. What the pieces are, how a file gets from a drag to a
converted copy, and the things that took a while to get right. Paths are relative to `Sources/Clementine/`
unless they start with `Resources/`, `scripts/` or similar.

Toolchain: SwiftPM, Swift 6 toolchain with `swiftLanguageMode(.v5)`, macOS 14+, one executable target
(`Package.swift`). The only dependency is Sparkle (binary XCFramework). `Info.plist` sets `LSUIElement`, so the
app lives only in the menu bar.

## 1. Overview

```
 Finder drag (⇧ / ⌥⇧ held)                Finder › Services          Menu bar › Open Files…
          │                                       │                           │
          ▼                                       ▼                           ▼
 DragMonitor  ── .began/.modeChanged/.ended ──►  WheelController  ◄── ServiceProvider / NSOpenPanel
 (Drag/DragMonitor.swift)                        (Drag/WheelController.swift)
                                                       │ show() / showClickable()
                                                       ▼
                                   WheelPanel + DropCatcher (NSPanel, drop target / click handler)
                                   WheelModel (slices, geometry)  ─►  WheelView (SwiftUI)
                                                       │ onDrop(action, urls)
                                                       ▼
                         ActionRegistry.actions(for:mode:)  (ConvertActions / ToolActions, WheelOrdering)
                                                       │
                                                       ▼
                    JobRunner.start ── action.editor? ──► custom editor window ─┐
                                    ── parameters?    ──► ParameterWindow ──────┤ ParamValues
                                    ── neither ─────────────────────────────────┤
                                                                                ▼
                    JobRunner.execute ── ProgressPanel card, ActionUsage.record
                                                       │
                                                       ▼
                    BatchRunner.run (units, concurrency limit, progress, cancellation)
                                                       │ action.run(JobContext)
                                                       ▼
                    Engines: ImageEngine/ImageTools/ImageEdits, PDFEngine, DocumentEngine,
                             MediaEngine → FFmpeg → ProcessRunner → ffmpeg/ffprobe (ToolLocator),
                             ArchiveEngine, SubtitleEngine, MetadataEngine
                                                       │ JobOutput (.files / .text), written via Output
                                                       ▼
                    Reveal in Finder · ResultWindow (text) · HistoryStore (history.json) · Undo
```

The headless CLI (`App/CLI.swift`, `--run`) calls `BatchRunner.run` directly with the same `Action` and
`ParamValues`, so everything below the wheel is shared between the app and the test scripts.

Process entry (`App/ClementineApp.swift`, `Entry.main`): debug-only `--render-ui` (`UIPreview`) and `--ui-test`
(`UITest`) run first, then `CLI.commands` (`--list`, `--run`, `--render-wheel`, `--history`, `--undo`,
`--clear-history`, `--help`), otherwise the SwiftUI `MenuBarExtra` app starts. `AppDelegate` starts
`WheelController`, `Updater`, `ServiceProvider`, the history clock and the first-launch welcome tour.

## 2. Module map

| Folder | Key types |
| --- | --- |
| `App/` | `Entry`/`ClementineApp`/`AppDelegate` (entry, menu bar). `CLI` (headless commands). `ServiceProvider` (Finder Services). `Updater` (Sparkle wrapper). `HistoryMenu` (Open Files…, Recent, Undo). `SettingsWindow` (General + Wheel tabs), `WheelSettings` (`WheelCatalog`, `WheelPrefs`, live preview). `OnboardingWindow` (welcome tour, launch-at-login via `SMAppService`). |
| `Drag/` | `DragMonitor` (detects file drags + modifiers), `WheelController` (glue: monitor → panel → `JobRunner`; also `--demo-wheel`, `openFiles()`, `showClickable`). |
| `Wheel/` | `WheelPanel` (+ private `WheelWindow`, `DropCatcher`), `WheelModel` (actions, geometry, hit-testing, thumbnail), `WheelView` (SwiftUI ring, `Slice` shape, `Hub`, `ModeChip`, `EmptyNotice`). |
| `Actions/` | `Action`, `Parameter`, `ParamValue(s)`, `JobContext`, `JobOutput`, `Editor`, `WheelMode`, `ActionRegistry` (`Action.swift`). Catalogs: `ConvertActions`, `ToolActions`. `WheelOrdering.swift`: `HiddenActions`, `ActionUsage` (frecency). |
| `Engines/` | `ImageEngine` (ImageIO load/encode, `ImageFormat`), `ImageTools` (⌥⇧ image tools, Core Image), `ImageEdits` (full-res crop/redact/annotate from JSON), `PDFEngine` (PDFKit, page specs), `DocumentEngine` (`@MainActor`, AppKit text system), `MediaEngine` + `FFmpeg` (probe, encode args, progress), `ArchiveEngine` (system zip/bsdtar/gzip/bzip2), `SubtitleEngine`, `MetadataEngine` (read/write common fields, `(edited)` copies), `ProcessRunner` + `ToolLocator`. |
| `ImageEditor/` | `ImageEditorWindow` (panel + `EditorShell`), `EditorCanvas` (`EditorImage`, `CanvasMapping`, `RectHandle`, toolbar pieces), `CropEditor`, `RedactEditor`, `AnnotateEditor`. |
| `Waveform/` | `Waveform` + `WaveformLoader` (peaks, in-memory cache), `Playback` (AVPlayer, `PreviewRenders` in a temp folder), `WaveformEditorModel` (`EditorModel.swift`), `WaveformViews` (shared views, `EditorWindow`), `TrimEditor`, `BleepEditor`, `ChannelsEditor`. |
| `Jobs/` | `JobRunner`/`RunningJob`, `BatchRunner`/`BatchReport`, `HistoryStore`/`HistoryEntry` (`History.swift`), `ProgressPanel`/`JobView`, `ParameterWindow`/`ParameterForm`, `ResultWindow`, `PageOrganizer`, `MetadataEditor`, `UIPreviewRenderer` (debug `--render-ui`). |
| `Support/` | `Prefs`, `Output` (+ `Locked`), `FileItem`/`FileKind`, `ClementineError`, `TimeCode`, `Theme`, `ThemeComponents`, `WindowMotion`, `FocusablePanel`, `FirstMouseHostingView` (`FirstMouseHosting.swift`), `uiTestID` (`UITestID.swift`). |
| `Testing/` | Debug-only `UITest` harness (`UITestHarness.swift`) and the `midline` suite (`UITestMidline.swift`). |

## 3. Key flows

### 3.1 Drag detection — `Drag/DragMonitor.swift`

- `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`: a global monitor that only observes, so it
  needs no Accessibility permission.
- On each mouse-down: record `NSPasteboard(name: .drag).changeCount` as the baseline and start a 30 Hz `Timer`
  in `.common` run-loop mode.
- `tick()`:
  - Button released (`NSEvent.pressedMouseButtons & 1 == 0`): stop the timer, and send `.ended` if a wheel was up.
  - Change count unchanged: no drag yet. Once it changes, read file URLs. If there are none (a text drag, say),
    stop polling until the next click.
  - Needs `Prefs.enabled` and ⇧ held (`NSEvent.modifierFlags`). ⌥ picks `.tools`, otherwise `.convert`. The
    first match sends `.began(urls, mode)`, and a later change sends `.modeChanged`. Letting go of ⇧ keeps the
    current wheel up.
- `WheelController.handle` shows the panel at `NSEvent.mouseLocation`. On `.ended` it waits 0.3 s, because the
  drop arrives after mouse-up, then hides the wheel, but only for the same generation (`currentGeneration`), so a
  newer wheel stays put.

### 3.2 The wheel — `Wheel/`

**WheelPanel** (`WheelPanel.swift`): one reused borderless `.nonactivatingPanel` at `.popUpMenu` level,
`canJoinAllSpaces`/`fullScreenAuxiliary`/`transient`. The content view is a container holding an
`NSHostingView(WheelView)` with a `DropCatcher` NSView on top, so the catcher always wins drag and click
hit-testing. `present()` bumps `generation`, loads the model, sizes and clamps the frame to the screen under the
pointer (`layout()`), calls `orderFrontRegardless()`, and sets `visible = true` on the next runloop pass so the
appear animation runs. `hide()` animates out and calls `orderOut` 0.22 s later if nothing has re-shown it.

**WheelModel** (`WheelModel.swift`), the geometry:
- `innerRadius = 60`. `outerRadius = 150`, plus 10 per slice above 8. `canvasSize = outerRadius*2 + 84` (room
  for the shadow, the hover pop-out and the mode chip).
- `segment(at:in:)`: `atan2(dx, dy)` gives 0 at 12 o'clock, going clockwise. It returns nil inside
  `innerRadius` (the hub) or past `outerRadius + 40`, and otherwise rounds to the nearest slice center.
- `chipContains`: a 112×26 box centered `outerRadius + 24` below the center.
- `session` is bumped on every load so the slices replay their fan-in. `load` asks QuickLook for a thumbnail and
  shows the workspace icon until it arrives.
- `loadDemo` / `preview` drive the same `WheelView` in the welcome tour and Settings › Wheel.

**Drop mode** (`DropCatcher` drag methods): `draggingEntered`/`Updated` set `hovered` from `segment(at:)`.
Over the hub the catcher returns `[]`, so Finder slides the file back, and that is how a drop cancels. In
`performDragOperation` it reads the URLs from the drag pasteboard and calls `onDrop` asynchronously, so the drag
session finishes before any window opens.

**Click mode** (`showClickable`, used by Services, Open Files… and `--demo-wheel --click`):
`beginClickMode()` sets `model.interactive`, lets the `WheelWindow` become key (`acceptsKey`), and makes the
catcher first responder. It installs global and local mouse-down monitors plus a `didResignKey` observer, all of
which dismiss the wheel. `mouseDown` remembers the slice that was pressed, and `mouseUp` runs it only if the
pointer is still on that slice. Releasing on the chip toggles the mode, and releasing on the hub or empty space
dismisses. Keys: Esc dismisses, Return/Enter/Space run the slice, Tab toggles the mode, and the arrow keys walk
the ring. If neither wheel has anything to offer, the empty notice shows for 1.6 s and closes.

### 3.3 Actions and ordering — `Actions/`

- `ActionRegistry.all = ConvertActions.all + ToolActions.all + ConvertActions.archiveCreate`. `find(id)` is
  used by the CLI and `PageOrganizer`.
- `candidates(for:mode:)` keeps the actions from the mode's catalog where the selection count fits
  `minInputs...maxInputs` and every `FileItem` passes `accepts`. In convert mode it adds the `archive.*` actions
  when nothing else matched, or when everything is a folder or `.other`.
- `actions(for:mode:)` drops `HiddenActions.ids`, sorts with `ActionUsage.arrange`, and keeps the first **12**
  ("so labels stay readable").
- Frecency (`WheelOrdering.swift`): each use adds 1 to a score that halves every 14 days. Scores live in
  UserDefaults `actionUsage` as `[bucket: [actionID: [score, lastUsed]]]`, where the bucket is
  `"<kind>.<convert|tools>"`, or `mixed.*` when the selection has different kinds. Ties keep catalog order. The
  `orderByUsage` setting (default on) turns sorting off. Hidden slices (`hiddenActions`) only leave the wheel and
  can still run from `--run`.
- `FileItem` (`Support/FileItem.swift`) classifies by extension, then by UTType. Any directory counts as
  `.folder`, packages included.
- Catalog order is wheel order. Convert IDs look like `convert.image.webp`, `convert.media.mp4`,
  `convert.pdf.png` and `archive.zip`. Tool IDs look like `tool.compress`, `tool.fit`, `tool.image.crop`,
  `tool.audio.bleep`, `tool.pdf.merge` and `tool.metadata`.

### 3.4 The `Action` model — `Actions/Action.swift`

| Field | Meaning |
| --- | --- |
| `id`, `title`, `symbol`, `mode` | Identity and wheel label. `JobRunner.title` adds "Convert to …" for convert actions. |
| `accepts: (FileItem) -> Bool` | Per-file filter. The `kinds(.image, .pdf)` helper builds the common case. |
| `minInputs` / `maxInputs` | Selection-size window. For example, Collage/Join/Merge need `minInputs: 2`, and Redact/Annotate have `maxInputs: 1`. |
| `batch` | Run once with all files (`[urls]`) instead of once per file. |
| `maxConcurrent` | Overrides `BatchRunner.limit` (e.g. `convert.image.mp4` uses ffmpeg, so 2). |
| `parameters` | `.slider`, `.number`, `.choice`, `.text`. `ParameterWindow` builds a form from them automatically, and `defaults` collects the initial values. |
| `preview` | `(URL, ParamValues) async -> NSImage?`, a live preview in the parameter sheet for single-image inputs (Edit, Add BG). |
| `editor` | `Editor = @MainActor (urls, defaults, apply) -> Void`. A custom window used instead of the sheet. It must end by calling `apply(ParamValues)`. |
| `run` | `(JobContext) async throws -> JobOutput`. `JobContext` has `inputs`, `params` and a thread-safe `progress(0…1)`. Returns `.files([URL])` or `.text(title:body:)`. |

To add an action, add it to `ConvertActions` or `ToolActions`. No other registration is needed.

### 3.5 Running jobs — `Jobs/JobRunner.swift`, `Jobs/BatchRunner.swift`, `Jobs/History.swift`

- `JobRunner.start`: runs the `editor` if there is one, otherwise `ParameterWindow` when there are parameters,
  otherwise `execute` directly with the defaults.
- `JobRunner.execute`: creates a `RunningJob` (observable state), shows a `ProgressPanel` card, records usage,
  then calls `BatchRunner.run` inside a `Task` stored on `job.task`. Progress callbacks hop to the main actor,
  and progress never goes backwards. With several units the detail line reads "n of N done". When it finishes:
  reveal the files in Finder (`Prefs.revealInFinder`), open a `ResultWindow` for each text output, write a
  history entry, and offer Undo on the card. The card closes after 1.2 s, or 5 s if Undo is available. Hovering
  keeps it open (`ProgressPanel.close(after:)`). A failure leaves the card open with the messages.
- `BatchRunner.units`: `[urls]` for batch actions, `[[url]]…` otherwise.
- `BatchRunner.limit`: `cores = max(1, activeProcessorCount / 2)`. `maxConcurrent` is capped at `cores`. Any
  video or audio in the units means `min(2, cores)` (ffmpeg is already multithreaded); everything else gets
  `cores`.
- `BatchRunner.run`: a `TaskGroup` with a sliding window of `limit` tasks. A private `Tally` (NSLock) tracks
  per-unit fractions → overall progress, the finished count, and the peak concurrency. Debug builds print the
  peak with `CLEMENTINE_TRACE_CONCURRENCY`. Results come back in input order in a `BatchReport`.
  `CancellationError` counts as `cancelled` only if the batch's task was cancelled (otherwise it's a failure,
  "Stopped unexpectedly."), and other errors become `failures` (prefixed with the file name when there are
  several units). The whole run is wrapped in `Output.beginBatch()/endBatch()` and holds a
  `ProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` so the Mac doesn't idle to sleep.
- Cancellation: the card's cancel button, or closing a running card (`windowWillClose`), calls
  `job.task?.cancel()`. Units that haven't started return `CancellationError`. `ProcessRunner`'s
  `onCancel` marks the child as asked to stop and terminates it; only that mark turns its exit (ffmpeg's 255,
  or death by SIGTERM) into `CancellationError`. A child that dies of a signal nobody sent is a `toolFailed`
  ("stopped unexpectedly (Segmentation fault: 11)"). `execute` notices `Task.isCancelled`, records history for
  any files that had already finished, and closes the card.
- Quitting and interrupts: `JobRunner.running` lists jobs whose batch is running and `ProcessRunner` keeps a
  registry of launched children (they lead their own process group, so nothing else would stop them).
  `AppDelegate.applicationShouldTerminate` returns `.terminateLater` while either is non-empty and runs
  `JobRunner.stopAll()`; the CLI does the same from `DispatchSource` handlers for SIGINT/SIGTERM/SIGHUP. Both go
  through `Shutdown.stop`: cancel the work, `ProcessRunner.stopAll` (SIGTERM, SIGKILL to the process group after
  3 s, and no new launches), wait for the engines to unwind so `Output.produce` deletes their partial outputs,
  and after 10 s kill whatever is left and `Output.discardInFlight()`.
- History: `HistoryStore` keeps the newest 50 entries (paths, action ID, title, symbol, date) as pretty-printed
  ISO-8601 JSON. Each entry also stores a `FileStamp` per output (inode, size, modification time; folders by inode
  only), taken when the job finishes. `undoable` is the newest entry that still has at least one output on disk.
  `undo` moves the outputs that still match their stamp to the Trash with `FileManager.trashItem` and drops the
  entry; outputs edited or replaced since stay put, and if that leaves nothing to trash it throws to say so.
  Entries saved before stamps existed (0.1.0) have none and are trusted as before. The card's Undo first checks the entry
  is still there, since it may already have been undone from the menu. `startClock()` ticks every 30 s so
  "2 min ago" stays current.

### 3.6 Engines and external tools — `Engines/`

- **ToolLocator** (`ProcessRunner.swift`) searches in this order: `Bundle.main.resourceURL/bin` (that is
  `Contents/Resources/bin`), then `Prefs.toolsDirectory` (tilde-expanded), then `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`, `/bin`. `require` throws `ClementineError.missingTool`, whose message suggests
  `brew install ffmpeg` or `brew install webp`. External tools used: `ffmpeg`, `ffprobe`, `cwebp` (WebP output;
  ImageIO can't write WebP, see `ImageEngine.swift`) and `img2webp` (fetched and bundled). Archives use the
  system `bsdtar` (`/usr/bin/tar`, which also writes ZIPs with the UTF-8 name flag), `gzip` and `bzip2`.
- **ArchiveEngine** (`ArchiveEngine.swift`):
  - Member names reach bsdtar as `./name` after `--` and are stripped back with `-s`, so names that look like
    options or bsdtar's `@archive` syntax are only ever paths. Covers creating and repacking.
  - Extraction (and repacking, which extracts first) runs under a bomb guard: archives with an index (zip, 7z, rar)
    are refused up front if their listing exceeds the limit, a watchdog polls free space during extraction, and
    the result is measured at the end. The limit is 250× the archive's size (at least 1 GiB) and never more than
    the free space minus 512 MB.
  - After extraction, symlinks whose real target isn't strictly inside the extracted items (absolute, `..`, via
    other links, or dangling) are deleted.
- **ProcessRunner.run**: stdin comes from `/dev/null`. Stdout goes to a pipe (with an optional per-line
  `onLine` callback, which ffmpeg progress uses) or to a file (`stdoutFile`, for binary output). Stderr is always
  captured. It finishes when a `DispatchGroup` has seen `terminationHandler` and EOF on both pipes. A non-zero
  exit becomes `ClementineError.toolFailed(name, stderr)`, and `Errors.swift` trims ffmpeg noise out of that
  message. A stop we asked for is a `CancellationError` whatever the exit status (see Cancellation above).
- **FFmpeg** (`FFmpeg.swift`):
  - `probe`: ffprobe JSON with `format=duration:stream=…:stream_disposition=attached_pic`. It reads duration,
    audio channels, the first real video stream (skipping attached pictures) and subtitle codecs.
  - `readable`: rejects empty files and files with no audio or video.
  - `run`: adds `-hide_banner -nostdin -n -loglevel error -nostats -progress pipe:1` and turns `out_time_us=`
    into a fraction of the duration. `-n` because outputs always come from `Output`: a file already at that path
    isn't ours, so ffmpeg must fail rather than overwrite it.
  - `transcode`: wraps the run in `Output.produce`.
  - `encodeArgs`: per-container codec presets, with even-size scaling for H.264/MPEG-4/WMV and a palette
    pipeline for GIF. `streamMaps` keeps every stream and converts subtitles per container.
  - `atempo` chains filters to stay within 0.5…2.
- **Output** (`Support/Output.swift`):
  - `file(beside:name:suffix:ext:)` writes next to the input, e.g. `photo (compressed).jpg`, and never
    overwrites. On a clash it tries `name 2`, `name 3`, and so on.
  - Names are compared case- and normalization-insensitively, against both the folder's listing and the names
    reserved by running jobs, so `Clip.mov` + `clip.ts` → MP4 give `Clip.mp4` and `clip 2.mp4` (on APFS/HFS+
    `Clip.mp4` and `clip.mp4` are one file).
  - During a batch, names it hands out are reserved in a locked set, so two parallel units can't both pick
    `photo.jpg`. `produce` releases a name once its file is written or abandoned, names whose files exist are
    pruned when the set grows past 256, and the set is cleared when the last batch ends.
  - `produce(url)` deletes a half-written output if the body throws, and `filling(folder)` does the same for
    output folders.
- Other engines: `ImageEdits` renders the editors' JSON at full resolution, in pixel coordinates of the upright
  image with a top-left origin. `MetadataEngine.write` takes a JSON object of field changes and saves an
  `(edited)` copy without re-encoding. `PDFEngine.parseSpec/spec(for:qualified:)` handles page specs such as
  `3r90, 1-2` and `2:1-3, 1:2`.

## 4. Windows and UI system

### FocusablePanel — `Support/FocusablePanel.swift`
Every editor, sheet, settings and welcome window is a `FocusablePanel`: a titled
`.nonactivatingPanel` with `.fullSizeContentView`, `canBecomeKey/Main = true`, `becomesKeyOnlyIfNeeded = false`,
level `.floating`, a transparent title bar with the miniaturize and zoom buttons hidden. It exists because
**`NSApp.activate` is only a request on macOS 14+**. Windows open while Finder is frontmost, and a normal window
could end up visible but not receiving keystrokes. A non-activating panel that can become key gets typing anyway
(the Spotlight technique). `present()` still calls `NSApp.activate()`, then `animateIn` + `makeKey`.
`cancelOperation` (Esc) closes the window. `close()` fades out first and then restores the frame, so the next
`present()` starts from the same place.

### FirstMouseHostingView and `NSWindow.host` — `Support/FirstMouseHosting.swift`
- `acceptsFirstMouse` returns `true`. Clicks on Clementine windows arrive while another app is active, so
  without this the first click would only bring the window forward instead of pressing the control.
- `mouseDownCanMoveWindow` returns `movesWindow`, which defaults to `false`. Only `ProgressPanel` passes
  `movableByBackground: true`: the job card has nothing inside to drag, so a drag anywhere on it moves it.
- `host(_:sizing:movableByBackground:)` installs the view and, when the sizing includes
  `.intrinsicContentSize`, calls `setContentSize(hosting.fittingSize)` right away so that a following `center()`
  uses the real size. Callers that size the window themselves (`ImageEditorWindow`, `MetadataEditor`,
  `PageOrganizer`, `ResultWindow`) pass other sizing options and set a size before calling `center()`.
  `ProgressPanel.show` likewise sizes the window before `place()`.
- Windows whose content needs drags also set `isMovableByWindowBackground = false` explicitly
  (`ImageEditorWindow`, `PageOrganizer`).

### Theme, components, motion
- `Support/Theme.swift`: the palette (`tangerine`, `blood`, `peach`, `leaf`, `cherry`), gradients, and
  scheme-aware `surface`, `hairline` and `secondaryText`. Motion: `Theme.spring`, `.snappy`, `.ease`. Views
  should take colors and animations from here.
- `Support/ThemeComponents.swift`: `Theme.backdrop/card/edge`, `Theme.reduceMotion`
  (`NSWorkspace.accessibilityDisplayShouldReduceMotion`), `GradientBadge`, `WindowBackdrop`, `.card()`, the
  `AccentButtonStyle`, `SoftButtonStyle` and `CircleIconButtonStyle` button styles, `CitrusProgressBar` (reads
  `accessibilityReduceMotion`), `Checkerboard`, `Keycap`, `VisualEffectBackground`.
- `Support/WindowMotion.swift`: `NSWindow.animateIn(from:)` / `animateOut(to:completion:)` animate the frame
  and alpha. With Reduce Motion on, the offset is zero and the window only fades. SwiftUI views likewise switch
  to `Theme.ease` or drop delays when `reduceMotion` is set (`WheelView`, `RedactEditor`, `EditorCanvas`).

### Editors produce `ParamValues`, so the CLI can run the same jobs
Each editor is an `Action.editor`. It only gathers values and calls `apply`. The render itself is the action's
`run`, which `--run … --set key=value` reaches as well.

| Editor | Window | Produces |
| --- | --- | --- |
| `CropEditor` | `ImageEditorWindow` + `EditorShell` + `EditorCanvas` | `crop` JSON `{x,y,w,h,rotate}` → `ImageEdits.crop` |
| `RedactEditor` | same | `boxes` JSON (or `auto`) + `style` → `ImageEdits.redact` |
| `AnnotateEditor` | same | `shapes` JSON → `ImageEdits.annotate`. The canvas draws with the same `ImageEdits.draw` code. |
| `TrimEditor` | `EditorWindow` (`Waveform/WaveformViews.swift`) | `start`, `end` as clock text |
| `BleepEditor` | `EditorWindow` | `ranges` (e.g. `0:05.2-0:06, 1:10-1:12`, parsed by `TimeCode.ranges`) |
| `ChannelsEditor` | `EditorWindow` | `channels` (choice), `left`, `right` |
| `PageOrganizer` | `FocusablePanel` grid | `pages` spec (`PDFEngine.spec`). Pages on several files falls back to `ParameterWindow`. |
| `MetadataEditor` | `FocusablePanel` | `fields` JSON. With several files or an unsupported kind it calls `apply(defaults)`, which shows the metadata as text. |

`EditorCanvas.swift` provides `CanvasMapping` (view points ↔ image pixels). `WaveformEditorModel` loads the
duration and peaks in the background (cached by `WaveformLoader`), and `PreviewRenders` writes ffmpeg previews
to `$TMPDIR/Clementine Previews/<uuid>`, which is deleted in `onClose`. Each `present` keeps its window in a
static array until `willClose`.

## 5. Settings and persistence

| Key (UserDefaults) | Where | Default |
| --- | --- | --- |
| `enabled` | `Prefs.enabledKey`, menu toggle, Settings | `true` |
| `revealInFinder` | `Prefs.revealKey` | `true` |
| `imageQuality` | `Prefs.qualityKey` (`ImageEngine.write`) | `0.85` |
| `toolsDirectory` | `Prefs.toolsDirectoryKey` (`ToolLocator`) | unset |
| `hiddenActions` | `HiddenActions.key` (sorted string array) | `[]` |
| `actionUsage` | `ActionUsage.key` (frecency dict) | `{}` |
| `orderByUsage` | `ActionUsage.orderKey` | `true` |
| `hasSeenOnboarding` | `OnboardingWindow.seenKey`, written to **`UserDefaults.standard`**, not `Prefs.defaults` | `false` |

- Domain: the bundled app uses `app.clementine.Clementine` (`CFBundleIdentifier`). The unbundled
  `.build/debug/Clementine` falls back to a domain named after the executable (`~/Library/Preferences/Clementine.plist`).
  `@AppStorage` in Settings and the menu writes to `.standard`.
- History: `Prefs.supportDirectory/history.json`, i.e. `~/Library/Application Support/Clementine/history.json`.
- Debug-only environment overrides (`#if DEBUG`): `CLEMENTINE_DEFAULTS_SUITE` (scratch defaults suite for
  `Prefs.defaults`), `CLEMENTINE_SUPPORT_DIR` (history location) and `CLEMENTINE_TRACE_CONCURRENCY`
  (prints peak parallelism). `scripts/test-productivity.sh` uses them.
  `@AppStorage` and the onboarding flag ignore the suite override.
- Waveform peaks are cached in memory only (`WaveformLoader.cache`), and peak extraction uses temporary
  `clementine-peaks-*.f32` files.

## 6. Distribution

- **`scripts/bundle.sh [debug|release]`** builds `build/Clementine.app`:
  ```
  Contents/MacOS/Clementine
  Contents/Info.plist                    (Resources/Info.plist)
  Contents/Resources/AppIcon.icns, THIRD_PARTY_NOTICES.md
  Contents/Resources/bin/                (everything in vendor/bin: ffmpeg, ffprobe, cwebp, img2webp)
  Contents/Frameworks/Sparkle.framework  (ditto'd from the SwiftPM bin dir; rpath @executable_path/../Frameworks)
  ```
  `UNIVERSAL=1` builds arm64 + x86_64, and `NO_SIGN=1` skips the ad-hoc `codesign --deep`.
  `scripts/fetch-tools.sh` (`make tools`) puts pinned, verified tool builds into `vendor/bin`.
- **`scripts/release.sh`** (`make release`) signs from the inside out without `--deep`: each tool in
  `Resources/bin` (with its own identifier), then Sparkle's XPC services, `Autoupdate`, `Updater.app` and the
  framework in Sparkle's documented order, then the app with `Resources/Clementine.entitlements`. After that it
  verifies, notarizes, staples, and builds the zip and DMG in `dist/`. See `RELEASING.md`.
- **Entitlements / hardened runtime:** `Resources/Clementine.entitlements` only sets
  `com.apple.security.app-sandbox = false`. The app is not sandboxed, because global drag watching and running
  ffmpeg on arbitrary files need that. It runs with the hardened runtime and no exceptions: the bundled tools
  are static executables signed by the same team, and Sparkle is re-signed by the same team, so library
  validation passes.
- **Updater gating** (`App/Updater.swift`): `SPUStandardUpdaterController(startingUpdater: false)` starts only
  when `disabledReason(for: .main)` is nil, which requires all three of:
  - the bundle path ends in `.app`, so `.build/debug` and the CLI never update;
  - `SUPublicEDKey` is present and not `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`;
  - `SUFeedURL` is set.

  Otherwise "Check for Updates…" shows an alert explaining why. `Updater` is created lazily from
  `AppDelegate`, and CLI commands exit before the app starts, so the CLI never touches Sparkle.
- **Services:** `Info.plist › NSServices` declares "Convert with Clementine" (`convertFiles`) and
  "Clementine Tools" (`toolFiles`) for `public.item` files. `ServiceProvider.register()` sets
  `NSApp.servicesProvider` and calls `NSUpdateDynamicServices()`. Both handlers read file URLs from the
  pasteboard and open the click-mode wheel at the pointer. In practice Finder only lists the entries for a copy
  in `/Applications` (`make install`), where the services database picks it up. Nothing in the code checks the
  install location.

## 7. Hard-won lessons and gotchas

1. **Decorative overlays must not hit-test.** Hairline borders drawn with `.overlay(Shape().strokeBorder(…))`
   swallowed clicks that landed exactly on a control's vertical midline. Every decorative stroke overlay
   carries `.allowsHitTesting(false)`. Examples: `ThemeComponents.swift` (`CardBackground`, `AccentButton`,
   `SoftButton`, `Keycap`), `WheelView.swift` (`Backdrop`, `Hub`), and `CitrusProgressBar`. The regression suite
   is `Testing/UITestMidline.swift`: it clicks each button style at its exact center and asserts that the click
   lands. Follow the same rule in new views.
2. **SwiftUI content counts as window background.** With `isMovableByWindowBackground`, dragging a trim handle
   or a page thumbnail moved the window. `FirstMouseHostingView.mouseDownCanMoveWindow` returns `false` unless
   `host(…, movableByBackground: true)`, which only `ProgressPanel` uses. Canvas windows also turn
   `isMovableByWindowBackground` off.
3. **`NSApp.activate` is a request on macOS 14+.** Hence the non-activating, key-capable `FocusablePanel`
   (§4), and the click-mode `WheelWindow` that can become key only while `acceptsKey` is set. Don't replace
   these with plain `NSWindow`s.
4. **Size before `center()`.** Windows have to have their final size before `center()` or placement, otherwise
   they are positioned as 0×0 and land off-center. `NSWindow.host` sets the content size immediately,
   `ImageEditorWindow` calls `setContentSize(initialSize…)` first, and `ProgressPanel.show` sizes before
   `place()` (its comment says "or it's placed as 0×0").
5. **`Process.waitUntilExit` can hang off the main thread.** `ProcessRunner` never calls it. It waits on a
   `DispatchGroup` with `terminationHandler` and EOF on both pipes, then resumes a checked continuation.
   Cancellation is checked again just before `process.run()` and right after it, so a cancel during launch isn't
   lost.
6. **Cover art looks like video.** ffprobe only reports `disposition.attached_pic` when asked for
   `stream_disposition=attached_pic`. Without it, an MP3 with artwork reads as having video.
   `FFmpeg.probe` skips attached pictures when setting `hasVideo`, and `streamMaps` maps `0:V?` (capital V
   excludes attached pictures).
7. **UI test harness: queue follow-ups before mouseDown.** AppKit controls run their own tracking loop inside
   `mouseDown` and pull the rest of the gesture from the event queue. So `UITestContext.click` and `drag` first
   `enqueue` (`NSApp.postEvent(atStart: false)`) the drags and mouse-up, and then `post` the mouse-down
   (`Testing/UITestHarness.swift`). Posting them in order would leave the tracking loop waiting for events that are not queued yet.
8. **UI test harness: `settle()` must pump events.** There is no `NSApplication.run` loop in `--ui-test` mode,
   so `settle()` loops `NSApp.nextEvent(…dequeue: true)` + `NSApp.sendEvent`, and `wait(until:)` is built on
   it. Sleeping or spinning the run loop alone delivers nothing.
   `Frame.center` is nudged 0.3 pt off the exact midline, and the midline suite tests the exact center
   separately.
9. **Smaller ones worth knowing:**
   - `WheelController` delays the hide on `.ended` by 0.3 s because the drop arrives after mouse-up. The
     generation check stops a stale hide from closing a newer wheel.
   - `openFiles()` shows the wheel on the next runloop pass so the closing `NSOpenPanel` doesn't take key
     status back.
   - Drop and click handlers call `onDrop` with `DispatchQueue.main.async` so the drag session ends before
     editor windows open.
   - `DocumentEngine` is `@MainActor` because the HTML importers touch WebKit.
   - `Output` reservations exist because parallel units resolved the same "unique" name.

## Testing entry points (quick reference)

- `make test` runs the shell suites in `scripts/` (smoke, edge, stress, image editor, waveform,
  PDF/metadata, productivity) against `.build/debug/Clementine --run …`.
- `make ui-test` runs `.build/debug/Clementine --ui-test [filter…]`, which needs a logged-in GUI session. Tag
  controls with `.uiTestID("…")` (debug-only frame registry in `Support/UITestID.swift`) and add suites to
  `UITest.all`.
- `--render-wheel out.png [--tools] [--hover N] [--light] [--click [--chip]] file…`, `--render-ui <dir>`
  (debug) and `--demo-wheel` (live wheel, app mode) are visual dev aids.
