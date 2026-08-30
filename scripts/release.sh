#!/bin/bash
# Builds Lexicon and packages it for a GitHub release. Set both
# LEXICON_SIGNING_IDENTITY and LEXICON_NOTARY_PROFILE for a public artifact;
# the latter names credentials previously stored with `notarytool`.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Lexicon.app"
ARCHIVE="dist/Lexicon.zip"
CHECKSUM_FILE="dist/Lexicon.zip.sha256"
NOTARY_ARCHIVE="dist/Lexicon-notarization.zip"
NOTARY_PROFILE="${LEXICON_NOTARY_PROFILE:-}"

if [[ -n "$NOTARY_PROFILE" \
      && ( -z "${LEXICON_SIGNING_IDENTITY:-}" || "$LEXICON_SIGNING_IDENTITY" == "-" ) ]]; then
    echo "error: notarization requires LEXICON_SIGNING_IDENTITY to name a Developer ID Application certificate" >&2
    exit 2
fi

scripts/make_app.sh

mkdir -p dist
rm -f "$ARCHIVE" "$CHECKSUM_FILE" "$NOTARY_ARCHIVE"
trap 'rm -f "$NOTARY_ARCHIVE"' EXIT

if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "warning: LEXICON_NOTARY_PROFILE is unset; this archive is for internal testing, not public distribution" >&2
fi

codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
CHECKSUM="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$CHECKSUM" "$(basename "$ARCHIVE")" > "$CHECKSUM_FILE"

echo "Release artifact: $ARCHIVE"
echo "SHA-256: $CHECKSUM"
echo "Verify: (cd dist && shasum -a 256 -c Lexicon.zip.sha256)"
