# Clementine launch film: script and shot list

**Length:** 65 s · **Format:** 1920×1080, 60 fps, H.264 · **Narrator:** ElevenLabs "Eric" (smooth, trustworthy),
Eleven v4 · **Score:** original, ElevenLabs Music v2.5, ~99 BPM, structured to the scenes below.

Arc: hook → problem → reveal → the gesture → every file type → tools and editors → privacy → call to action.

## Narration

> You have the file. You just need it… as something else.
>
> So you find a converter website. Upload it to a stranger's server. Wait. Download. Or install one more app, for
> one more format.
>
> Meet Clementine.
>
> Hold Shift as you drag a file… and every format it can become blooms open, right under your cursor.
>
> Drop it. And the new file lands right beside the original.
>
> Photos. Video. Audio. Documents. PDFs. Archives. One gesture, for all of it.
>
> Add Option, and the wheel fills with tools. Compress. Crop. Redact. Annotate. Trim on a real waveform. Bleep a
> word. Rearrange pages. Merge PDFs.
>
> And all of it happens on your Mac. Nothing is uploaded. Ever.
>
> Clementine. Free, for your Mac. Just hold Shift… and drag.

124 words, recorded as one take so the read stays consistent, then cut at sentence gaps and re-spaced on the
timeline (`public/audio/timeline.json`, `paragraphStarts`). Word times come from the `/with-timestamps` alignment, and
every on-screen word, cut and sound effect is keyed to them in code (`W(paragraph, "word")` in `src/timing.ts`).

## Shot list

Times are seconds on the final timeline. Music sections: Intro 0–16.8 · Lift 16.8–20 · Groove 20–38 · Build 38–50.2 ·
Breath 50.2–55.6 (score low-passed in the mix) · Finale 55.6–65.

| # | Time | Picture | Words on screen | Sound |
|---|------|---------|-----------------|-------|
| 1 | 0.0–6.1 | **Hook.** Black, a warm glow blooms. A photo card, *Sunset.heic*, floats in. On "as something else" its extension flicks through .jpg .png .webp .pdf .gif .avif | "You have the file." → "You just need it as *something else*." | Low drone; a tick per extension |
| 2 | 5.9–16.6 | **Problem.** Cool grey palette. A converter website slides up: "Not Secure", ads, cookie banner. The photo drops in; "Uploading Sunset.heic to our servers…" stalls; "You are #47 in the queue"; three decoy download buttons pop. Then the site recedes and a dock fills with one converter app after another | Left column builds: "Upload." "Wait." "Download." → "One more app. / For one more format." | Swipe, pop, notification blip, ticks, little pops per app; riser into 7 |
| 3 | 16.3–20.2 | **Reveal.** Black to citrus. The app icon springs in and spins to rest; slice-shaped light rays turn behind it; the wordmark rises letter by letter. Icon zooms through the camera | "Clementine" · "The format wheel for your Mac." | Riser peaks into a soft sub impact on "Clementine"; the score opens up |
| 4 | 19.7–30.6 | **The gesture.** An original citrus desktop with menu bar and files. The cursor grabs *Sunset.heic* and drags it across. A ⇧ keycap rises ("hold while you drag") and presses down; **the real convert wheel blooms** under the pointer on "blooms" while the camera pushes in. The pointer sweeps WEBP → PNG → JPG, each slice lighting as it would in the app. Drop: the wheel collapses, a progress card fills and turns green, the camera pans to the desktop and *Sunset.jpg* pops in right beside *Sunset.heic* on "lands" | ⇧ shift · hold while you drag · Convert to JPG → Done | Key press, glassy bloom, a tick per slice, pop on drop, success chime, pop as the file lands; whip-pan whoosh out |
| 5 | 30.4–38.2 | **Every file type.** Blurred desktop. One beat per word: a big type label, its formats, and that file's real wheel blooming with the target slice lit: Photos (WEBP), Video (GIF), Audio (MP3), Documents (PDF), PDFs (PNG pages), Archives (Extract). Then all six wheels orbit the centre | Photos · Video · Audio · Documents · PDFs · Archives, each with its format list and e.g. "Trip.mov → Trip.gif"; "One gesture. / For all of it." | Swipe and tick per beat; bloom for the orbit |
| 6 | 38.0–50.4 | **Tools.** ⌥ + ⇧ keycaps; ⌥ presses on "Option". The real tools wheel blooms on "fills", then slides left. Each tool word lights its slice and swings in the real editor, rendered by the app: Target Size sheet + Compress card, Crop, Redact, Annotate, Trim (video, waveform + filmstrip), Bleep (regions on the waveform), Pages (thumbnail grid), Merge (two PDFs). The wheel re-blooms for video, audio and PDF files | "Add Option for tools." then Compress. Crop. Redact. Annotate. Trim. Bleep. Pages. Merge. | Key press, bloom, swipe + tick per tool, a tiny 1 kHz bleep after "word" |
| 7 | 50.2–55.9 | **Privacy.** Near-black. A Mac outline holding the icon; a dashed line reaches for a cloud and gets cut with a red ✕ on "Nothing" | "All of it happens on your *Mac*." → "Nothing is uploaded. *Ever.*" · No account · No uploads · Works offline · ffmpeg built in | Score drops to a low-passed hush |
| 8 | 55.5–65.0 | **End card.** Warm blurred wallpaper. Icon and wordmark, glow on "Clementine". Then the gesture as a hint: a ⇧ key presses on "Shift", a tiny photo drags on "drag". Download pill and URL | Clementine · Free, for your Mac. · Hold ⇧ and drag · Download free · github.com/mustafahalabi/clementine | Soft impact, key press, closing chime; the score resolves and rings out; fade to black |

## Visual rules

- Colours from `Sources/Clementine/Support/Theme.swift` (tangerine #FF9A3C → blood #FF5E3A, peach, leaf green for done).
- Motion: springs modelled on `Theme.spring`; words rise out of a soft blur; nothing linear except the dashed line.
- All Clementine UI is real: wheels from `--render-wheel` (3×, transparent), windows and editors from `--render-ui`
  (2×), in US English. Only the progress card is rebuilt in React (to animate it), matching ProgressWindow's look.
- Everything else is original: the sunset photo is an SVG drawn for the film, the wallpaper is code, the file icons
  and cursor are drawn, type is Inter / Inter Tight (OFL). No Apple artwork, logos or wallpapers.
- The converter website and the dock apps are invented; the URL uses a non-existent `.web` TLD.
