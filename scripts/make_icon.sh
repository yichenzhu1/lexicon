#!/bin/bash
# Builds the macOS .icns file from the canonical 1024×1024 PNG.
# The source must be full-bleed and opaque. macOS 26 places pre-masked legacy
# icons with transparent corners inside a smaller gray compatibility plate.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Assets/AppIcon.png"
OUTPUT="Assets/Lexicon.icns"
TEMP_DIR="$(mktemp -d /tmp/lexicon-icon.XXXXXX)"
ICONSET="$TEMP_DIR/Lexicon.iconset"

trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$ICONSET"

make_size() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

make_size 32 icon_16x16@2x.png
make_size 64 icon_32x32@2x.png
make_size 128 icon_128x128.png
make_size 256 icon_128x128@2x.png
make_size 256 icon_256x256.png
make_size 512 icon_256x256@2x.png
make_size 512 icon_512x512.png
make_size 1024 icon_512x512@2x.png

perl scripts/make_icon.pl "$ICONSET" "$OUTPUT"
echo "Built $OUTPUT"
