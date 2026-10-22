# Working on Clementine

Notes for whoever changes this code next, human or AI. Read [README.md](README.md) first, then
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). [docs/TESTING.md](docs/TESTING.md) and [docs/CLI.md](docs/CLI.md)
cover verification and every action's parameters.

## Commands

```sh
swift build                      # debug build (.build/debug/Clementine doubles as the CLI)
make test                        # all seven headless suites (~2.5 min); scripts/<suite>.sh runs one
make ui-test                     # interaction tests in off-screen windows (needs a GUI session)
make run / make install          # build the .app and launch it / copy it to /Applications
scripts/release.sh               # signed + notarized release (see RELEASING.md for the env vars)
```

Homebrew's `ffmpeg` and `webp` must be installed for tests and for app builds without `make tools`.

## Conventions

- **Swift 6 toolchain, Swift 5 language mode**, macOS 14+. No sandbox (global drag detection and running ffmpeg
  need that), so no App Store.
- **New wheel action:** add an `Action` to `Actions/ConvertActions.swift` or `Actions/ToolActions.swift` with an
  `accepts` predicate, `parameters` (they get a settings sheet for free) and a `run` closure that calls an engine.
  Interactive editors use the `editor` hook and must still produce plain `ParamValues` (JSON in `.text` values
  for complex data), so the CLI and the tests can run the same action. Add CLI cases to a `scripts/*.sh` suite.
- **Outputs** go next to the input via `Output.file(beside:…)`; never overwrite. Wrap writes in
  `Output.produce`/`Output.filling` so failures and cancellation leave nothing behind.
- **UI** takes colours and motion from `Support/Theme.swift`; shared pieces live in `ThemeComponents.swift` and
  `WindowMotion.swift`. Respect Reduce Motion.
- **Windows** are `FocusablePanel`s whose content goes in through `window.host(…)` (a `FirstMouseHostingView`).
  Don't use `NSHostingController`/`contentViewController` for them.
- **Decorative overlays** (`.overlay(shape.stroke…)` and similar) must be `.allowsHitTesting(false)`.
- **Tag controls tests need to click** with `.uiTestID("area.name")` (it compiles to nothing in release builds).
- Comments explain *why*; keep them short. Commits end with a `Co-Authored-By` line when an AI wrote them.

## Lessons that cost time

- `NSApp.activate()` is only a request on macOS 14+. Clementine's windows open while Finder stays active, which is
  why they're non-activating panels that can still become key.
- SwiftUI content counts as window background, so `isMovableByWindowBackground` turns control drags into window
  drags. `FirstMouseHostingView` refuses that by default; only the progress card opts in.
- A stroked shape laid over a control steals clicks on the control's exact horizontal midline. On 1× displays real
  clicks land there.
- Size a window from its content *before* `center()`, or it's placed by its old size.
- `Process.waitUntilExit()` can hang off the main thread; `ProcessRunner` uses `terminationHandler` and a
  `DispatchGroup`. Treat ffmpeg's stderr as noise until filtered (`Errors.swift`).
- ffprobe only reports cover art with `stream_disposition=attached_pic`; without it MP3s with art look like video.
- In test scripts, `unzip -l … | grep -q` fails at random under `pipefail`; use `unzip -Z1 … | grep -qx`. Read
  output paths from stdout only, because CI's virtual Macs log framework noise to stderr.

## Driving the real app

Off-screen checks (`make ui-test`, `--render-ui`) catch most problems, but some only show up on a real screen:
Finder drags, Services, keyboard focus, window placement. To drive it:

- The terminal app needs Accessibility (and Screen Recording for screenshots) in System Settings › Privacy.
- Post real key codes, not keycode 0 with a substituted character; AppKit treats those differently.
- The Bash tool's shell is zsh: `$VAR` holding "x y" is *not* split into two arguments, and `log` is a builtin
  (use `/usr/bin/log`).
- Never press Return unless a Clementine window is verified to have focus; in Finder, Return renames the
  selected file. Escape any stray rename immediately.
- On the maintainer's Mac, ⌘⇧G is taken by another app (Goldfish), so it won't open "Go to Folder".
- Clicking a selected file's name twice starts a rename; deselect by clicking empty rows first.

## Releases

Credentials live in the build Mac's login keychain (identity, `agents-island` notary profile, Sparkle key).
[RELEASING.md](RELEASING.md) has the exact commands and the post-release checks. Never commit private keys or
anything in `dist/`. The repo has no license by the owner's choice; don't add one.
