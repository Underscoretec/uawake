# Releasing uawake

`make release` builds `build.noindex/release/uawake-<version>.dmg` and `.zip`, signs the zip for
Sparkle, commits its item to `appcast.xml` on the `gh-pages` branch and prints the commands to publish. `<version>` is
`MARKETING_VERSION`, plus `-PRERELEASE` when that is set (`Config/Version.xcconfig`).

Without a Developer ID it runs in **stub mode**: ad-hoc signed, no hardened runtime, not
notarized. Alphas ship like this; macOS blocks them on first open (docs/TESTERS.md).

## Updates (Sparkle 2.9.6)
- Feed: `https://underscoretec.github.io/uawake/appcast.xml`, served by GitHub Pages from the
  orphan `gh-pages` branch: `appcast.xml`, `.nojekyll` (serve files as they are) and a one-line
  `index.html`. Pushing `gh-pages` publishes it.
- `make release` edits the feed in a git worktree at `build.noindex/gh-pages` (created on demand,
  recreated after `make clean`) and commits there, so your checkout stays on `main`. To fix the
  feed by hand, edit and commit in that worktree.
- Archives: the `.zip` asset of each GitHub Release. The DMG is for first installs.
- Channels: a pre-release item carries `<sparkle:channel>beta</sparkle:channel>`. The
  `UpdateChannel` setting defaults to `beta` until 1.0, so everyone gets alphas; a final release
  has no channel and reaches everyone.
- Release notes: the version's CHANGELOG section, inlined as Markdown in the item.
- The app checks daily (`SUScheduledCheckInterval`) and asks before installing.

## One-time setup
1. **Sparkle EdDSA keys** (the maintainer, on the release Mac). The tools are in the SwiftPM
   checkout after any build: `build.noindex/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`.
   - `./generate_keys` stores the private key in the login keychain and prints the public key.
   - `./generate_keys -x <file>` exports a backup; keep it offline. Losing the key means existing
     installs can never be updated again.
   - Put the public key in `App/Info.plist` → `SUPublicEDKey`. The updater stays off until this is
     a real 32-byte key, and `make release` checks it matches the keychain's key.
2. **GitHub Pages**: repo Settings › Pages › Build and deployment › Source "Deploy from a
   branch", branch `gh-pages`, folder `/ (root)`.
3. **Developer ID** (later). Enrol Underscore Technology in the Apple Developer Program; install a
   "Developer ID Application" certificate; put the Team ID in `TEAM_ID`
   (`Config/ExportOptions.plist` is filled from it).
4. **Notarization** (later). `xcrun notarytool store-credentials uawake-notary --apple-id <id>
   --team-id <team> --password <app-specific password>`; then `export NOTARY_PROFILE=uawake-notary`.

## Each release
1. Bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION`/`PRERELEASE`) in
   `Config/Version.xcconfig`; add the `## [<version>]` section to CHANGELOG.
2. `make release` (signed: `TEAM_ID=… NOTARY_PROFILE=… make release`). Keychain may ask to let
   `sign_update` use the key.
3. Commit `main` (version bump, CHANGELOG), then run the printed commands in order: push the tag,
   `gh release create` with the DMG and zip, push `gh-pages` (the feed goes live, and the zip it
   points at already exists), then push `main`.
4. Update the Homebrew cask (from the first public release).

## Ad-hoc builds and updates
- Stub builds have no hardened runtime: library validation only loads frameworks signed by the
  same team, and ad-hoc code has no team, so a hardened ad-hoc app can't load Sparkle.
- Checked on 23 Nov 2026 (Debug, sandboxed, ad-hoc, macOS 27.0.1) against a local feed: the app
  found, downloaded, verified (EdDSA) and installed a higher build. Sparkle logs "Code signature of
  the new version doesn't match the old version" (ad-hoc cdhashes always differ) and installs
  anyway because the EdDSA signature is valid. The installed app has no quarantine flag, so no
  Gatekeeper prompt appears on relaunch. Settings carried over (sandbox container); Sparkle adds
  `SULastCheckTime`, `SUHasLaunchedBefore`, `SUUpdateGroupIdentifier`.
- Each ad-hoc build is a new code identity to macOS, so privacy permissions granted to the old
  build (Calendar, Location, Bluetooth, camera) may be asked again after an update.
- To repeat the check: make two copies with a throwaway key in `SUPublicEDKey` and different
  `CFBundleVersion`s, re-sign ad-hoc (`codesign -f -s - --preserve-metadata=entitlements,flags`),
  serve a feed on `http://127.0.0.1`, and launch the old copy with `-SUFeedURL <feed>`
  (plus `-SUAutomaticallyUpdate YES -SULastCheckTime '<date>2020-01-01T00:00:00Z</date>'` to run
  unattended). Quit it by pid: `pkill -f <app path>` also kills Sparkle's `Autoupdate`.
