# Privacy

Clementine converts and edits files on your Mac. It has no accounts, no analytics, no telemetry and no crash
reporter, and it never uploads your files or anything about them.

## Your files

- Every conversion and tool runs locally, through macOS frameworks and the command-line tools bundled in the
  app (ffmpeg, ffprobe, cwebp, img2webp) or ones you point it at in Settings.
- Results are written next to the original. Originals are never changed.
- To notice a drag, Clementine reads the file paths on the system's drag pasteboard while a drag is in
  progress. It doesn't read the files until you drop them on a slice.
- Converting an HTML file doesn't fetch anything it references from the web (images, stylesheets, scripts).
- Cut Out Subject finds the subject with Apple's Vision framework, on your Mac.
- Shortcuts actions run the same way, inside Clementine. Files a shortcut passes without a location on disk (an
  image from the clipboard, say) are written to a folder in your user's temporary directory
  (`$TMPDIR/Clementine Shortcuts/`) with their results; macOS clears it over time.

## Network

Clementine makes one kind of network request on its own: **checking for updates** with
[Sparkle](https://sparkle-project.org). It downloads the update feed from GitHub
(`https://github.com/mustafahalabi/clementine/releases/latest/download/appcast.xml`, set as `SUFeedURL` in the
app's Info.plist) and, if you install an update, the release archive from GitHub. The request carries the usual
HTTP headers, including a user agent with Clementine's and Sparkle's version numbers. Sparkle's system profiling is
off (`SUEnableSystemProfiling` isn't set), so it doesn't send a profile of your Mac (model, CPU, OS version and so
on). Sparkle asks before it starts checking automatically; you can also check by hand from the menu. GitHub sees
the request like any other download (your IP address, the time); see [GitHub's privacy
statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

Everything else happens only when you click it:

- **Show in Maps** in the Metadata editor opens the photo's coordinates in Apple Maps.
- **Open** on a decoded QR code opens its link in your browser.

## What Clementine stores

All of it stays on your Mac, in your user account:

| What | Where |
| --- | --- |
| Settings, hidden wheel slices, and how often you use each action (to order the wheel) | `~/Library/Preferences/app.clementine.Clementine.plist` |
| History of the last 50 jobs that made files (action, input and output paths), used for Undo | `~/Library/Application Support/Clementine/history.json` |
| Errors writing that history | the macOS unified log (Console.app), on this Mac only |

**Clear History** in the menu empties `history.json`. Deleting those two files and the app removes everything
Clementine keeps.

Questions: open an issue at https://github.com/mustafahalabi/clementine/issues.
