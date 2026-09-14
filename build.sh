#!/bin/bash
# Builds build/Clawdy.app from the Swift package. Add --run to launch it afterwards.
#   ./build.sh          just build
#   ./build.sh --run    build, then (re)launch the app
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.5.0"
APP="build/Clawdy.app"

echo "Compiling Clawdy…"
swift build -c release
BIN=".build/release/Clawdy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clawdy"
# Animated Clawd pets (frame sheets baked by tools/render-pets.py).
mkdir -p "$APP/Contents/Resources/pets"
cp Assets/pets/*.png Assets/pets/manifest.json "$APP/Contents/Resources/pets/"
# The slice of the Hugeicons font the menu icons are drawn from.
mkdir -p "$APP/Contents/Resources/fonts"
cp Assets/fonts/*.ttf "$APP/Contents/Resources/fonts/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clawdy</string>
  <key>CFBundleDisplayName</key><string>Clawdy</string>
  <key>CFBundleIdentifier</key><string>app.clawdy.Clawdy</string>
  <key>CFBundleExecutable</key><string>Clawdy</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>MIT. Unofficial; not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Strip Finder metadata (codesign rejects it), then sign so macOS lets it run locally.
# An ad-hoc signature changes on every build, and macOS ties the Accessibility grant to
# the exact signature — so "Window checks" turns itself off after each rebuild even though
# System Settings still lists Clawdy. Signing with a self-signed certificate instead keeps
# the grant. Make one in Keychain Access (Certificate Assistant > Create a Certificate,
# type "Code Signing") and name it Clawdy Dev, or point CLAWDY_SIGN_IDENTITY at your own.
xattr -cr "$APP"
IDENTITY="${CLAWDY_SIGN_IDENTITY:-Clawdy Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Clawdy 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Launched. Look for the crab in your menu bar and along the bottom of the screen."
fi
