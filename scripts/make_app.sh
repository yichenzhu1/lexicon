#!/bin/bash
# Builds Lexicon.app into ./build from the SwiftPM executable.
# Usage: scripts/make_app.sh [debug|release]   (default: release)
#
# CFBundleIdentifier below is how macOS identifies the app (preferences,
# permissions). Forks should change it, along with the matching suite name in
# LibraryModel.settings.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION"

BINARY=".build/$CONFIGURATION/Lexicon"
APP="build/Lexicon.app"
ICON="Assets/Lexicon.icns"

if [[ ! -f "$ICON" || "Assets/AppIcon.png" -nt "$ICON" ]]; then
    scripts/make_icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Lexicon"
cp "$ICON" "$APP/Contents/Resources/Lexicon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Lexicon</string>
    <key>CFBundleIdentifier</key>        <string>com.yichenzhu.Lexicon</string>
    <key>CFBundleExecutable</key>        <string>Lexicon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>Lexicon.icns</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || echo "note: ad-hoc codesign failed; the app should still run locally"

echo "Built $APP"
