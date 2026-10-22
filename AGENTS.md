# Clementine — agent guide

Context for any AI agent (Claude Code, Codex, Cursor…) or person working on this repo. `CLAUDE.md` imports this
file, so keep everything here.

## What this is

A macOS menu bar app, modelled on "Tangerine": hold **⇧** while dragging a file and a wheel of output formats
appears under the pointer; **⌥⇧** shows tools for that kind of file. Drop on a slice and the result is written
next to the original. Everything runs locally. Owner: Mustafa Halabi (GitHub `mustafahalabi`). Public repo:
https://github.com/mustafahalabi/clementine. Latest release: **v0.1.1** (2026-10-22), signed and notarized; 0.1.0 installs update to it through Sparkle (verified, delta update). When releasing, fix the old appcast URLs (RELEASING.md step 3).

| Doc | Read it for |
| --- | --- |
| [README.md](README.md) | What the app does, install, build, release in short |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the code fits together, data flow, UI system, lessons and where they live |
| [docs/CLI.md](docs/CLI.md) | Every CLI flag and every action id with its parameters |
| [docs/TESTING.md](docs/TESTING.md) | The test suites, the interaction-test harness, the real-Mac checklist |
| [RELEASING.md](RELEASING.md) | Signing, notarizing, the Sparkle feed, publishing; this project's credentials setup |
| [CHANGELOG.md](CHANGELOG.md) | What shipped in each version |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | ffmpeg (GPL v3), libwebp, Sparkle |
| [PRIVACY.md](PRIVACY.md) | What the app stores and the network requests it makes (keep it accurate) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How outside contributors get changes in (fork, PR, owner review) |
| [marketing/video/README.md](marketing/video/README.md) | The launch film: ElevenLabs audio, Remotion motion graphics, how to re-render |

## Decisions already made (don't relitigate without the owner)

| Decision | Why |
| --- | --- |
| Name "Clementine", not "Tangerine" | Tangerine is an existing product. |
| Direct distribution, **no sandbox**, no App Store | Global drag detection and running ffmpeg as a process need it. |
| ffmpeg, cwebp and img2webp bundled as separate executables | Self-contained app; GPL obligations met via notices (THIRD_PARTY_NOTICES.md). |
| **No license** on the repo's own code | Owner's choice: public to read, all rights reserved. Don't add a LICENSE. |
| Sparkle key shared with the Agents Island project | Existing key on the build Mac; RELEASING.md explains how to switch to a separate key. |
| Releases are Apple silicon only by default | `UNIVERSAL=1` exists but adds ~320 MB of tools. |
| Every action must be runnable from the CLI | Editors produce plain parameters, so tests and scripts exercise the same code as the UI. |

## Status and what's open

Everything planned for v0.1.0 is built, merged to `main`, tested and released: conversions, all tools and editors,
click-mode wheel and Services, history/undo, wheel customization, parallel batches, welcome tour, bundled tools,
Sparkle updates, CI. Every feature was also driven live on the build Mac with real mouse and keyboard input.

Known issues and loose ends (none block use):

- The CLI enforces choices and slider ranges but not typed-number ranges; engines report those (e.g. Split's
  1-second minimum).
- `hasSeenOnboarding` and `@AppStorage` values use `UserDefaults.standard`, so `CLEMENTINE_DEFAULTS_SUITE` doesn't
  isolate them in tests.
- `--undo` moves files to the real Trash even when `CLEMENTINE_SUPPORT_DIR` is set.
- **Open Files…** shows the open panel while another app stays active; typing before clicking into it goes to that
  app. Unclear whether this only happens with synthetic input.
- Waveform editors show no filmstrip for MKV/WebM; Split cuts on keyframes; DOCX → PDF drops images; RAR can't be
  created. (Also listed in README › Known limits.)
- Few app controls carry `.uiTestID` tags yet, so `make ui-test` mostly covers the harness and the midline
  regression. Tag controls as you write suites for them.

## How the owner likes work done

- Treat requests as goals and finish them end to end; use parallel subagents (separate git worktrees, merged by
  one agent) for independent areas.
- Verify on the real app, not just with tests: off-screen first (`make ui-test`, `--render-ui`), then drive the real
  Mac when a behaviour depends on macOS (drags, focus, Services, window placement). Report what was and wasn't
  verified.
- Ask before outward-facing or irreversible actions (publishing a release, posting, deleting user data). Pushing
  to `main` after tests and CI pass has been the norm.
- `main` is protected: pull requests need the owner's approval (CODEOWNERS), a passing `test` check and resolved
  conversations; no force-pushes or deletion. The owner, as admin, can still push directly; everyone else forks.
- The ElevenLabs API key is in the build Mac's login keychain (`security find-generic-password -s
  elevenlabs-api-key -w`). Never print or commit it.
- Keep the docs current: update README / ARCHITECTURE / CLI / TESTING / CHANGELOG with every user-visible change.

## Commands

```sh
swift build                      # debug build (.build/debug/Clementine doubles as the CLI)
make test                        # all the headless suites (~3 min), summary at the end; scripts/<suite>.sh runs one
make ui-test                     # interaction tests in off-screen windows (needs a GUI session)
make run / make install          # build the .app and launch it / copy it to /Applications
make tools                       # fetch the verified ffmpeg/ffprobe/cwebp/img2webp into vendor/bin
scripts/release.sh               # signed + notarized release (env vars in RELEASING.md)
```

Homebrew's `ffmpeg` and `webp` must be installed for tests (fixtures) and for app builds without `make tools`.
After `make tools`, the suites run Clementine against the bundled tools in `vendor/bin`. CI
(`.github/workflows/ci.yml`) runs debug and release builds and all the suites on every push and PR.

## Conventions

- **Swift 6 toolchain, Swift 5 language mode**, macOS 14+.
- **New wheel action:** add an `Action` to `Actions/ConvertActions.swift`, `Actions/ToolActions.swift` or `Actions/FileActions.swift` with an
  `accepts` predicate, `parameters` (they get a settings sheet for free) and a `run` closure that calls an engine.
  Interactive editors use the `editor` hook and must still produce plain `ParamValues` (JSON in `.text` values
  for complex data). Add CLI cases to a `scripts/*.sh` suite and the action to docs/CLI.md.
- **Outputs** go next to the input via `Output.file(beside:…)`; never overwrite. Wrap writes in
  `Output.produce`/`Output.filling` so failures and cancellation leave nothing behind.
- **UI** takes colours and motion from `Support/Theme.swift`; shared pieces live in `ThemeComponents.swift` and
  `WindowMotion.swift`. Respect Reduce Motion.
- **Windows** are `FocusablePanel`s whose content goes in through `window.host(…)` (a `FirstMouseHostingView`).
  Don't use `NSHostingController`/`contentViewController` for them.
- **Decorative overlays** (`.overlay(shape.stroke…)` and similar) must be `.allowsHitTesting(false)`.
- **Tag controls tests need to click** with `.uiTestID("area.name")` (compiles to nothing in release builds).
- Comments explain *why*; keep them short. Commits made by an AI end with a `Co-Authored-By` line.

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
- In the UI-test harness, queue follow-up mouse events *before* sending mouse-down (AppKit tracking loops pull
  from the queue) and let `settle()` pump `NSApp` events; there's no run loop in test mode.
- Git worktrees made by an agent tool may be based on the tool's own working directory, not this repo; create them
  with `git worktree add` here.

## Driving the real app

Some things only show up on a real screen: Finder drags, Services, keyboard focus, window placement.

- The terminal app needs Accessibility (and Screen Recording for screenshots) in System Settings › Privacy.
- Post real key codes, not keycode 0 with a substituted character; AppKit treats those differently.
- The Bash tool's shell may be zsh: `$VAR` holding "x y" is *not* split into two arguments, and `log` is a builtin
  (use `/usr/bin/log`). Put multi-step drive sequences in a bash script.
- Never press Return unless a Clementine window is verified to have focus; in Finder, Return renames the
  selected file. Escape any stray rename immediately.
- Clicking a selected file's name twice starts a rename; deselect by clicking empty rows first.
- On the owner's Mac, ⌘⇧G belongs to another app (Goldfish), so it won't open "Go to Folder".
- The owner may be using the Mac; stop sending input as soon as another app comes to the front, and say so.

## Releases and credentials

All credentials live in the build Mac's (Mac mini) login keychain: the Developer ID identity, the `agents-island`
notary profile and the Sparkle private key. [RELEASING.md](RELEASING.md) has the exact commands and post-release
checks. Never commit private keys, passwords or anything in `dist/`; don't print private keys in logs.
