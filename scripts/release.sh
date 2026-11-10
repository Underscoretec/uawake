#!/bin/zsh
# Builds a release: archive, export, DMG and zip in build.noindex/release/.
#
# Signed mode (a "Developer ID Application" identity is in the keychain and TEAM_ID is set):
#   archives with that identity and the hardened runtime, exports with Config/ExportOptions.plist,
#   notarizes with the notarytool keychain profile in NOTARY_PROFILE, staples, then packages.
# Stub mode (no identity): ad-hoc signs WITHOUT the hardened runtime (ad-hoc code can't load the
#   embedded Sparkle framework under library validation), skips notarization, and says so.
#   Stub output is for local testing only; never publish it.
set -euo pipefail
cd "${0:A:h}/.."

version=$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' Config/Version.xcconfig)
build=$(awk -F' = ' '/^CURRENT_PROJECT_VERSION/ {print $2}' Config/Version.xcconfig)
out=build.noindex/release
archive=$out/uawake.xcarchive
rm -rf $out && mkdir -p $out/export

identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$identity" && -n "${TEAM_ID:-}" ]]; then
  echo "==> Signed release $version ($build) with: $identity"
  xcodebuild archive -project uawake.xcodeproj -scheme uawake -configuration Release \
    -archivePath $archive -destination 'generic/platform=macOS' -derivedDataPath build.noindex/DerivedData-release \
    CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp -quiet
  sed "s/REPLACE_WITH_TEAM_ID/$TEAM_ID/" Config/ExportOptions.plist > $out/ExportOptions.plist
  xcodebuild -exportArchive -archivePath $archive -exportOptionsPlist $out/ExportOptions.plist \
    -exportPath $out/export -quiet
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)}"
  ditto -c -k --keepParent $out/export/uawake.app $out/notarize.zip
  xcrun notarytool submit $out/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple $out/export/uawake.app
  signed=1
else
  echo "==> STUB: no Developer ID identity or TEAM_ID. Building an ad-hoc, unnotarized app for local testing."
  xcodebuild archive -project uawake.xcodeproj -scheme uawake -configuration Release \
    -archivePath $archive -destination 'generic/platform=macOS' -derivedDataPath build.noindex/DerivedData-release \
    CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO -quiet
  ditto $archive/Products/Applications/uawake.app $out/export/uawake.app
  signed=0
fi

# DMG with an Applications shortcut, and a zip for Sparkle.
staging=$out/dmg
mkdir -p $staging && ditto $out/export/uawake.app $staging/uawake.app && ln -s /Applications $staging/Applications
hdiutil create -volname "uawake $version" -srcfolder $staging -ov -format UDZO -quiet $out/uawake-$version.dmg
ditto -c -k --keepParent $out/export/uawake.app $out/uawake-$version.zip
rm -rf $staging
# Only the DMG and zip are deliverables; drop every app copy so Launch Services has none to pick.
rm -rf $archive $out/export build.noindex/DerivedData-release $out/notarize.zip
scripts/clean-apps.sh --unregister >/dev/null

if (( signed )); then
  [[ -n "${NOTARY_PROFILE:-}" ]] && xcrun notarytool submit $out/uawake-$version.dmg --keychain-profile "$NOTARY_PROFILE" --wait \
    && xcrun stapler staple $out/uawake-$version.dmg
  echo "==> Sign the zip for Sparkle: Sparkle's sign_update $out/uawake-$version.zip (see docs/RELEASING.md)"
else
  echo "==> STUB: skipped notarization, stapling and Sparkle signing. Do not publish these files."
fi
ls -la $out/*.dmg $out/*.zip
