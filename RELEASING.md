# Releasing Clementine

A release is a Developer ID–signed, notarized `Clementine.app`, shipped as a `.dmg` (for people) and a `.zip`
(for Sparkle), plus an `appcast.xml` that existing installs poll for updates.

## One-time setup

### 1. Developer ID certificate

You need an Apple Developer Program membership and a **Developer ID Application** certificate in your login
keychain (Xcode › Settings › Accounts › Manage Certificates › +). Find its exact name with:

```sh
security find-identity -v -p codesigning
# e.g. "Developer ID Application: Mustafa Halabi (ABCDE12345)"
```

### 2. Notarization credentials

Store an app-specific password (appleid.apple.com › Sign-In and Security › App-Specific Passwords) or an App
Store Connect API key in a keychain profile, once:

```sh
xcrun notarytool store-credentials clementine-notary \
  --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
```

### 3. Sparkle signing keys

Sparkle verifies every update with an EdDSA (ed25519) signature. Its tools come with the SwiftPM package:

```sh
swift package resolve
SPARKLE_BIN=$(dirname "$(find .build/artifacts -path '*Sparkle/bin/sign_update' | head -1)")
"$SPARKLE_BIN/generate_keys"            # creates the private key in your keychain, prints the public key
```

Put the printed public key in `Resources/Info.plist` as `SUPublicEDKey` (replacing
`REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`) and commit it. Until you do, the updater stays off: it never checks in the
background, and "Check for Updates…" just explains that the build isn't set up for updates.

Back up the private key (`generate_keys -x sparkle_private_key`) somewhere safe. **If it's lost, existing
installs can never be updated again**; if it leaks, anyone can ship them an update. Never commit it.

## Each release

1. **Bump the version** in `Resources/Info.plist`: `CFBundleShortVersionString` (e.g. `0.2.0`, shown to people)
   and `CFBundleVersion` (an integer that must go up every release; Sparkle compares it). Commit.

2. **Build, sign, notarize, package:**

   ```sh
   CODESIGN_IDENTITY="Developer ID Application: Mustafa Halabi (ABCDE12345)" \
   NOTARY_PROFILE=clementine-notary \
   scripts/release.sh            # UNIVERSAL=1 for an Intel + Apple silicon build
   ```

   This fetches and verifies the bundled tools (`scripts/fetch-tools.sh`), builds a release bundle, signs every
   embedded binary, Sparkle's XPC services, the framework and the app (inside-out, hardened runtime, secure
   timestamp, `Resources/Clementine.entitlements`), notarizes and staples the app, then writes to `dist/`:

   - `Clementine-<version>.zip` (stapled app, used by Sparkle)
   - `Clementine-<version>.dmg` (signed, notarized, stapled; drag-to-Applications layout)
   - `Clementine-<version>.sha256`

   Without `CODESIGN_IDENTITY` the script still runs end to end but ad-hoc signs, skips notarization and names
   everything `-unsigned`. Those builds are for local testing only.

3. **Sign the update for Sparkle and build the appcast.** Put every release zip you want in the feed in one
   folder (keeping old ones lets Sparkle generate delta updates) and run:

   ```sh
   mkdir -p ~/clementine-updates && cp dist/Clementine-0.2.0.zip ~/clementine-updates/
   "$SPARKLE_BIN/generate_appcast" \
     --download-url-prefix https://github.com/mustafahalabi/clementine/releases/download/v0.2.0/ \
     --link https://github.com/mustafahalabi/clementine \
     ~/clementine-updates
   ```

   `generate_appcast` signs each archive with the key from your keychain and writes
   `~/clementine-updates/appcast.xml` (and any `.delta` files). Release notes: drop a `Clementine-0.2.0.html`
   or `.md` next to the zip and it's embedded automatically.

   To sign a single archive by hand (e.g. to edit the appcast yourself):

   ```sh
   "$SPARKLE_BIN/sign_update" dist/Clementine-0.2.0.zip
   # sparkle:edSignature="…" length="…"   -> paste into the <enclosure> of the new <item>
   ```

   `release.sh` does this for you if you set `SPARKLE_KEY_FILE` to an exported private key file.

4. **Publish a GitHub release** tagged `v0.2.0`, attaching the `.dmg`, the `.zip` and `appcast.xml` (plus any
   `.delta` files):

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   gh release create v0.2.0 dist/Clementine-0.2.0.dmg dist/Clementine-0.2.0.zip \
     ~/clementine-updates/appcast.xml --title "Clementine 0.2.0" --notes-file notes.md
   ```

   The app's feed is `https://github.com/mustafahalabi/clementine/releases/latest/download/appcast.xml`, which
   always resolves to the newest release's `appcast.xml`. Because of that, **every release must attach a full
   appcast** (not just the new item). Mark pre-releases as such on GitHub so `latest` keeps pointing at the stable
   one.

5. **Check it:** on another Mac (or a fresh user account) open the DMG, drag Clementine to Applications and
   launch it; Gatekeeper shouldn't complain (`spctl -a -vv /Applications/Clementine.app` says
   "Notarized Developer ID"). Then install the previous version and use "Check for Updates…".

## Notes

- **Bundled tools and licensing.** The FFmpeg builds are GPL v3. Shipping them inside the app is fine (they run
  as separate processes), but each release must honor the GPL for them; see `THIRD_PARTY_NOTICES.md`, which is
  also copied into the app and the DMG.
- **Bumping tool versions.** Edit the pinned versions, build paths and SHA-256 hashes at the top of
  `scripts/fetch-tools.sh` (`FFMPEG_CHANNEL=latest` fetches the newest FFmpeg to get the new hashes), then update
  `THIRD_PARTY_NOTICES.md`.
- **CI** (`.github/workflows/ci.yml`) builds and runs the smoke and edge tests on every push and PR. Releases are
  built locally because they need your signing identity.
