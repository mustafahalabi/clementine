# Clementine launch film

A 65-second product film for Clementine, built in code with [Remotion](https://www.remotion.dev) from real app
renders, with narration, score and sound effects from ElevenLabs. [SCRIPT.md](SCRIPT.md) has the script and the
shot list.

| Output (in `out/`, not committed) | What |
| --- | --- |
| `clementine-launch.mp4` | The film: 1920×1080, 60 fps, H.264 + AAC, −14 LUFS |
| `clementine-launch-9x16.mp4` | Vertical social cut: the film framed over a blurred copy, with live captions |
| `clementine-teaser.mp4` / `.webp` / `.gif` | Silent 10 s seamless loop of the gesture, for the README |

## Regenerate

Needs Node 20+, ffmpeg, `uv` (for the numpy analysis scripts), Xcode/Swift for the app renders, and Chrome Headless
Shell (`remotion.config.ts` uses Playwright's cached copy if present, otherwise Remotion downloads one).

```sh
cd marketing/video
npm install
scripts/render-app-assets.sh   # real Clementine UI into public/app/ (wheels at 3x, windows at 2x), ~2 min
scripts/render.sh              # the film → out/clementine-launch.mp4 (~7 min on an M-series Mac)
scripts/render-cuts.sh         # teaser loop + 9:16 cut
npm run studio                 # preview and scrub in the browser
scripts/stills.sh 24.2 41.6    # QC stills at given seconds → out/qc/
```

`render-app-assets.sh` builds the debug app with `tools/render-scale.patch` applied for the duration of the run
(it adds `CLEMENTINE_RENDER_SCALE` for sharp high-DPI output and `CLEMENTINE_RENDER_CLEAR` for a transparent wheel
backdrop), sets a temporary `AppleLocale=en_US` for the unbundled binary so numbers render as `62%` and `1.40`
whatever the Mac's region, and then undoes both. App source and your preferences are left as they were. Slice order
comes from a separate defaults suite, so your own wheel usage doesn't reorder the slices. Fixtures (`fixtures/`, not
committed) are the sunset photo (the `Photo` still in this project), a 20 s clip made from it, a narration excerpt,
and small DOCX/PDF/ZIP files.

### Audio

Committed in `public/audio/`: the narration take with its alignment, the score (plus a low-passed copy for the
privacy beat), the sound effects, and their analysis (`sfx/onsets.json`, `beats.json`). Rebuilding them costs
ElevenLabs credits:

```sh
scripts/generate-audio.sh                 # everything
scripts/generate-audio.sh narration       # or one of: narration, music, sfx, analyse
scripts/audition.sh                       # one line in six voices → auditions/
```

The key comes from the keychain (`security find-generic-password -s elevenlabs-api-key -w`) into an environment
variable inside the script. It's never printed or written to disk.

| Asset | Model | Notes |
| --- | --- | --- |
| Narration | Eleven v4 (`eleven_v4`), voice **Eric** (`cjVigY5qzO86Huf0OWal`), stability 0.5, speed 0.96, seed 11 | One take via `/with-timestamps`; cut at sentence gaps |
| Score | Music v2.5 (`music_v2_5`), composition plan with six sections matching the scenes, seed 21 | Instrumental, ~99 BPM |
| SFX | `eleven_text_to_sound_v2` | Prompts in `scripts/el_sfx.py`; the bleep is a generated 1 kHz tone |

Voices auditioned on the same line (in `auditions/`): Jarnathan, Eric, Sarah, George, Brian, Mira VO. Eric was
picked for a clean noise floor, warm low spectral centroid and natural pacing. Swap `VOICE` in
`scripts/generate-audio.sh` to try another.

## How it fits together

- `src/timing.ts` turns the narration alignment plus `paragraphStarts` into absolute word times. `W(p, "word")`
  is used everywhere a cut, word or sound must land on the voice.
- `src/Launch.tsx` sequences the scenes and builds the whole mix: narration clips, the score ducked under speech
  (and cross-faded to the low-passed copy for the privacy beat), and every SFX cue aligned on its transient or peak.
- `src/scenes/` holds the scenes. `GestureDemo` (drag → bloom → hover → drop → result) takes a timing object and
  is reused by the teaser. Hovered slices come from the pointer's angle, like the app's hit-testing, and each slice
  change gets a tick.
- `src/components/` holds the desktop (wallpaper, menu bar, icons, cursor, keycaps), the wheel (real renders, one
  PNG per hover index), kinetic type and the progress card.
- `scripts/master.sh` normalises loudness in two passes (`loudnorm`, −14 LUFS integrated, −1 dBTP).

Colours come from `Sources/Clementine/Support/Theme.swift`. Type is Inter / Inter Tight (OFL). The photo,
wallpaper, file icons and cursor are drawn for the film; the converter site and dock apps are invented.
