#!/bin/bash
# Builds Lexicon.app into ./build from the SwiftPM executable.
# Usage: scripts/make_app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION"

BINARY=".build/$CONFIGURATION/Lexicon"
APP="build/Lexicon.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Lexicon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Lexicon</string>
    <key>CFBundleDisplayName</key>       <string>Lexicon</string>
    <key>CFBundleIdentifier</key>        <string>fun.diane.lexicon</string>
    <key>CFBundleExecutable</key>        <string>Lexicon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.reference</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || echo "note: ad-hoc codesign failed; the app should still run locally"

echo "Built $APP"
