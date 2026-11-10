# Releasing uawake

`make release` builds `build.noindex/release/uawake-<version>.dmg` and `.zip`. Without the items below it
runs in **stub mode**: ad-hoc signed, no hardened runtime, not notarized. Stub builds are for local
testing only.

## One-time setup (blocked on the maintainer)
1. **Developer ID.** Enrol Underscore Technology in the Apple Developer Program; create a
   "Developer ID Application" certificate and install it in the release Mac's keychain (or CI).
   Put the Team ID in `TEAM_ID` (and `Config/ExportOptions.plist` is filled from it).
2. **Notarization credentials.** `xcrun notarytool store-credentials uawake-notary --apple-id <id>
   --team-id <team> --password <app-specific password>`; then `export NOTARY_PROFILE=uawake-notary`.
3. **Sparkle EdDSA keys.** From the Sparkle 2.9.6 release (`bin/` in the distribution archive, or
   the SwiftPM checkout under `DerivedData/.../SourcePackages/artifacts/sparkle`):
   - `./bin/generate_keys` — creates the private key in the login keychain and prints the public key.
   - Back up the private key (`./bin/generate_keys -x private-key-file`) somewhere safe and offline;
     losing it means existing users can't receive updates.
   - Put the public key in `App/Info.plist` → `SUPublicEDKey`. The updater stays off until this is a
     real 32-byte key.
4. **Update feed.** Choose the HTTPS host for `appcast.xml` and set `SUFeedURL` in `App/Info.plist`
   (currently the placeholder `https://updates.example.invalid/uawake/appcast.xml`). Beta builds
   use the `beta` channel in the same feed.

## Each release
1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Version.xcconfig`; update CHANGELOG.
2. `TEAM_ID=… NOTARY_PROFILE=… make release`.
3. `./bin/sign_update build.noindex/release/uawake-<version>.zip` and add the item to the appcast
   (`./bin/generate_appcast` can do both).
4. Tag `v<version>` on `main`, publish the GitHub release with the DMG, update the Homebrew cask.

## Why stub builds have no hardened runtime
With the hardened runtime, library validation only loads frameworks signed by the same team.
Ad-hoc code has no team, so an ad-hoc app can't load the embedded Sparkle framework and exits at
launch. Developer ID builds sign the app and Sparkle with one team, so they keep the hardened runtime.
