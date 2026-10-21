#!/bin/bash
# Publishes a release: ./release.sh 0.2.0
# Bumps the version in app/Info.plist, builds and signs (build.sh), notarizes when signed with Developer ID,
# signs the zip for Sparkle, writes appcast.xml and uploads both to the GitHub release v0.2.0. Installed apps
# find it through SUFeedURL (…/releases/latest/download/appcast.xml) within a day, or with Check for Updates….
#
# Needs: a clean git tree, `gh` logged in, the Sparkle key in the login Keychain (generate_keys --account annot),
# and for notarization NOTARY_PROFILE (xcrun notarytool store-credentials), e.g. in signing.env.
set -euo pipefail
cd "$(dirname "$0")"
[ -f signing.env ] && source signing.env

VERSION="${1:?usage: ./release.sh 1.2.3}"
REPO="KLIXPERT-io/annot"
PLIST=app/Info.plist
APP=build/ANNOT.app
ZIP="dist/ANNOT-$VERSION.zip"
SPARKLE=app/.build/artifacts/sparkle/Sparkle/bin

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first"; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "v$VERSION already exists"; exit 1; }

# Sparkle compares CFBundleVersion, so it goes up by one with every release.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
trap 'git checkout -- "$PLIST"' ERR

./build.sh
[ -x "$SPARKLE/sign_update" ] || { echo "Sparkle tools missing: run swift package resolve --package-path app"; exit 1; }

mkdir -p dist
rm -f "$ZIP"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ "$IDENTITY" == "Developer ID Application"* ]] && [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
else
  echo "⚠ Not notarized (needs a Developer ID Application certificate and NOTARY_PROFILE)."
  echo "  Updates still install; a first download needs: xattr -dr com.apple.quarantine /Applications/ANNOT.app"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGNATURE=$("$SPARKLE/sign_update" --account annot "$ZIP") # sparkle:edSignature="…" length="…"

# Release notes: the commit subjects since the last release.
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
NOTES=$(git log --pretty='- %s' --invert-grep --grep='^Release ' ${PREV:+"$PREV..HEAD"})
NOTES="${NOTES:-- Maintenance release}"
NOTES_HTML=$(printf '%s\n' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|^- \(.*\)|<li>\1</li>|')

# One item is enough: Sparkle only needs the newest version.
cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ANNOT</title>
    <item>
      <title>ANNOT $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$NOTES_HTML
</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/ANNOT-$VERSION.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

trap - ERR
git commit -q -m "Release $VERSION" -- "$PLIST"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" dist/appcast.xml --repo "$REPO" --title "ANNOT $VERSION" --notes "$NOTES"
echo "✓ v$VERSION released (build $BUILD)"
