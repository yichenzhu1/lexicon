#!/bin/bash
# Builds Lexicon.app into ./build from the SwiftPM executable.
# Usage: scripts/make_app.sh [debug|release]   (default: release)
#
# Optional environment variables:
#   LEXICON_VERSION           User-facing version (defaults to 0.1.0)
#   LEXICON_BUILD_NUMBER      Monotonically increasing integer (defaults to 1)
#   LEXICON_SIGNING_IDENTITY  Developer ID identity; unset uses ad-hoc signing
#
# CFBundleIdentifier below is how macOS identifies the app (preferences,
# permissions). Forks should change it, along with the matching suite name in
# LibraryModel.settings.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
VERSION="${LEXICON_VERSION:-0.1.0}"
BUILD_NUMBER="${LEXICON_BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${LEXICON_SIGNING_IDENTITY:--}"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    echo "error: configuration must be 'debug' or 'release'" >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must contain three numeric components, such as 0.1.0" >&2
    exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: build number must be a positive integer" >&2
    exit 2
fi

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
cp "LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>  <string>en</string>
    <key>CFBundleDisplayName</key>        <string>Lexicon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key>              <string>Lexicon</string>
    <key>CFBundleIdentifier</key>        <string>com.yichenzhu.Lexicon</string>
    <key>CFBundleExecutable</key>        <string>Lexicon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>Lexicon.icns</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.reference</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
    if [[ "$CONFIGURATION" == "release" ]]; then
        echo "warning: built with an ad-hoc signature; do not publish this bundle as a public release" >&2
    fi
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP"
fi

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Lexicon")"
echo "Built $APP ($VERSION, build $BUILD_NUMBER, $ARCHITECTURES)"
