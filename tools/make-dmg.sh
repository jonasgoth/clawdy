#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications DMG: build/Clawdy-<version>.dmg
# The disk image opens as a window with the crab on the left, Applications on the
# right and an arrow in between (Assets/dmg/background.tiff, drawn by
# tools/make-dmg-background.py).
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

VOL="Clawdy"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Clawdy.app/Contents/Info.plist)"
OUT="build/Clawdy-${VERSION}.dmg"
STAGE="build/dmg-stage"
RW="build/dmg-rw.dmg"
# Icon centres in the window; keep in step with tools/make-dmg-background.py.
APP_X=170; APPS_X=490; ICON_Y=200
WIN_W=660; WIN_H=420

# Anything still mounted from a previous run would steal the volume name.
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R build/Clawdy.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Assets/dmg/background.tiff "$STAGE/.background/background.tiff"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 24 ))
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW \
               -size "${SIZE_MB}m" -ov "$RW" >/dev/null

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL"

# Lay the window out. This drives Finder, so the first run asks for permission to
# control it; say yes, or the DMG still works but opens as a plain file list.
if ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 140, $((240 + WIN_W)), $((140 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Clawdy.app" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "Warning: could not drive Finder, so the DMG has no custom layout."
  echo "         Allow this terminal to control Finder (System Settings > Privacy & Security > Automation) and re-run."
fi

# The mounted disk wears the crab too. This has to happen after Finder is done
# with the window: laying out the window wipes a .VolumeIcon.icns staged earlier.
cp Assets/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$STAGE" "$RW"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
