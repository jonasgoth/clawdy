#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications DMG: build/Clawdy-<version>.dmg
#
# The app is ad-hoc signed unless a "Developer ID Application" certificate is in your keychain.
# Ad-hoc builds run fine locally; other people must right-click > Open the first time.
# To ship without that warning you need an Apple Developer account, then:
#   1. codesign --force --options runtime --timestamp --sign "Developer ID Application: …" build/Clawdy.app
#   2. xcrun notarytool submit build/Clawdy-<version>.dmg --keychain-profile <profile> --wait
#   3. xcrun stapler staple build/Clawdy-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Clawdy.app/Contents/Info.plist)"
STAGE="build/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/Clawdy.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="build/Clawdy-${VERSION}.dmg"
rm -f "$OUT"
hdiutil create -volname "Clawdy" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
