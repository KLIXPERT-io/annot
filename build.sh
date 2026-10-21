#!/bin/bash
# Builds build/ANNOT.app (universal: Apple silicon + Intel) and signs it.
# Signs with CODESIGN_IDENTITY (from the environment or a git-ignored signing.env next to this script),
# else the first Developer ID / Apple Development identity, else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"
[ -f signing.env ] && source signing.env

APP="build/ANNOT.app"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release --package-path app "${ARCHS[@]}"
BIN="$(swift build -c release --package-path app "${ARCHS[@]}" --show-bin-path)/ANNOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/ANNOT"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/ANNOT"
# Sparkle (updates). ANNOT isn't sandboxed, so it doesn't need Sparkle's XPC services.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/Resources/overlay.js "$APP/Contents/Resources/overlay.js"

# App icon: app/AppIcon.icon (Icon Composer) → Assets.car (Liquid Glass on macOS 26, flat before) + AppIcon.icns.
# actool exits 0 even when it compiles nothing, so check for the result.
xcrun actool app/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --app-icon AppIcon \
  --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" app/Info.plist)" \
  --output-partial-info-plist /dev/null >/dev/null || true
[ -f "$APP/Contents/Resources/Assets.car" ] || echo "⚠ No app icon: compiling app/AppIcon.icon needs Xcode 26"

# Always the same certificate: macOS ties granted permissions to the signature, and Sparkle only installs
# updates signed by the same team. Put CODESIGN_IDENTITY="..." in signing.env to pin it.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2}' | head -1)}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2}' | sort | head -1)}"
# Inside out: Sparkle's helpers, the framework, then the app. Developer ID gets the secure timestamp notarization
# needs. Ad-hoc skips the hardened runtime, whose library validation would refuse a framework without a team ID.
sign() {
  local flags=(--force --options runtime --sign "$1")
  case "$1" in
    -) flags=(--force --sign -) ;;
    "Developer ID Application"*) flags+=(--timestamp) ;;
  esac
  local fw="$APP/Contents/Frameworks/Sparkle.framework"
  codesign "${flags[@]}" "$fw/Versions/B/Autoupdate" &&
  codesign "${flags[@]}" "$fw/Versions/B/Updater.app" &&
  codesign "${flags[@]}" "$fw" &&
  codesign "${flags[@]}" --entitlements app/ANNOT.entitlements "$APP"
}
if [ -n "$IDENTITY" ] && sign "$IDENTITY"; then
  echo "✓ $APP  (signed: $IDENTITY)"
else
  sign - && echo "✓ $APP  (ad-hoc signed — macOS may ask for permissions again after each rebuild)"
fi
