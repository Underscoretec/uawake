#!/bin/zsh
# Builds a release: archive, export, DMG and zip in build.noindex/release/, then signs the zip for
# Sparkle, commits its item to appcast.xml on the gh-pages branch (through a worktree in
# build.noindex/gh-pages, so your checkout never switches branch) and prints the commands to publish.
#
# Signed mode (a "Developer ID Application" identity is in the keychain and TEAM_ID is set):
#   archives with that identity and the hardened runtime, exports with Config/ExportOptions.plist,
#   notarizes with the notarytool keychain profile in NOTARY_PROFILE, staples, then packages.
# Stub mode (no identity): ad-hoc signs WITHOUT the hardened runtime (ad-hoc code can't load the
#   embedded Sparkle framework under library validation), skips notarization, and says so.
#   Stub output is unnotarized: macOS blocks it on first open (docs/TESTERS.md).
# Sparkle: once App/Info.plist has a real SUPublicEDKey, sign_update signs the zip with the private
#   key in the login keychain (generate_keys) and the item goes into gh-pages' appcast.xml.
set -euo pipefail
cd "${0:A:h}/.."

version=$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' Config/Version.xcconfig)
build=$(awk -F' = ' '/^CURRENT_PROJECT_VERSION/ {print $2}' Config/Version.xcconfig)
pre=$(awk -F' = ' '/^PRERELEASE/ {print $2}' Config/Version.xcconfig)
name=$version${pre:+-$pre}
tag=v$name
# The feed lives on gh-pages; check it out in a worktree (recreated if make clean removed it).
pages=build.noindex/gh-pages
appcast=$pages/appcast.xml
if [[ ! -e $pages/.git ]]; then
  git worktree prune
  git worktree add -q $pages gh-pages
fi
if [[ -n "$(git -C $pages status --porcelain)" ]]; then
  echo "error: $pages has uncommitted changes" >&2
  exit 1
fi
if grep -q "<sparkle:version>$build</sparkle:version>" $appcast; then
  echo "error: build $build is already in $appcast; bump CURRENT_PROJECT_VERSION or remove that item" >&2
  exit 1
fi
out=build.noindex/release
archive=$out/uawake.xcarchive
rm -rf $out && mkdir -p $out/export

identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$identity" && -n "${TEAM_ID:-}" ]]; then
  echo "==> Signed release $name ($build) with: $identity"
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
hdiutil create -volname "uawake $name" -srcfolder $staging -ov -format UDZO -quiet $out/uawake-$name.dmg
ditto -c -k --keepParent $out/export/uawake.app $out/uawake-$name.zip
rm -rf $staging

if (( signed )); then
  [[ -n "${NOTARY_PROFILE:-}" ]] && xcrun notarytool submit $out/uawake-$name.dmg --keychain-profile "$NOTARY_PROFILE" --wait \
    && xcrun stapler staple $out/uawake-$name.dmg
else
  echo "==> STUB: ad-hoc signed, not notarized."
fi

# Release notes: this version's CHANGELOG section.
awk -v h="## [$name]" 'index($0, h) == 1 {on = 1; next} on && /^## / {exit} on' CHANGELOG.md > $out/notes.md
[[ -s $out/notes.md ]] || echo "warning: CHANGELOG.md has no \"## [$name]\" section" >&2

# Sparkle: sign the zip and add the appcast item (pre-releases go on the beta channel).
sparkle=build.noindex/DerivedData-release/SourcePackages/artifacts/sparkle/Sparkle/bin
key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist)
appcasted=0
if [[ $key == REPLACE_* ]]; then
  echo "==> No SUPublicEDKey in App/Info.plist: skipped Sparkle signing and the appcast."
else
  if [[ "$($sparkle/generate_keys -p)" != "$key" ]]; then
    echo "error: the keychain's Sparkle key doesn't match SUPublicEDKey in App/Info.plist" >&2
    exit 1
  fi
  enclosure=$($sparkle/sign_update $out/uawake-$name.zip)
  notes=$(<$out/notes.md)
  item="    <item>
      <title>uawake $name</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$name</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>${pre:+
      <sparkle:channel>beta</sparkle:channel>}
      <sparkle:fullReleaseNotesLink>https://github.com/Underscoretec/uawake/releases/tag/$tag</sparkle:fullReleaseNotesLink>
      <description sparkle:format=\"markdown\"><![CDATA[$notes
]]></description>
      <enclosure url=\"https://github.com/Underscoretec/uawake/releases/download/$tag/uawake-$name.zip\" type=\"application/octet-stream\" $enclosure/>
    </item>"
  # Newest first: the item goes right after <language>.
  ITEM=$item awk '{print} /<language>/ {print ENVIRON["ITEM"]}' $appcast > $out/appcast.xml && mv $out/appcast.xml $appcast
  xmllint --noout $appcast
  git -C $pages commit -q -m "Appcast: uawake $name ($build)" -- appcast.xml
  appcasted=1
  echo "==> Committed $name ($build) to appcast.xml on gh-pages"
fi
# Only the DMG and zip are deliverables; drop every app copy so Launch Services has none to pick.
rm -rf $archive $out/export build.noindex/DerivedData-release $out/notarize.zip
scripts/clean-apps.sh --unregister >/dev/null

ls -la $out/*.dmg $out/*.zip
cat <<EOS

==> To publish, after committing main, in this order (gh-pages puts the feed live, so the zip must exist first):
  git tag $tag && git push origin $tag
  gh release create $tag $out/uawake-$name.dmg $out/uawake-$name.zip --verify-tag --title "uawake $name"${pre:+ --prerelease} --notes-file $out/notes.md
EOS
if (( appcasted )); then
  echo "  git push origin gh-pages"
else
  echo "  (no appcast item was added: existing installs won't be offered this build)"
fi
echo "  git push origin main"
