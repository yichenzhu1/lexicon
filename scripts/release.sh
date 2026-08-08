#!/bin/bash
# Produces a ZIP and checksum suitable for a GitHub Release.
# Signed mode notarizes and staples the app. `--unsigned` creates an explicitly
# labelled ad-hoc-signed build for testing or an early public preview.
#
# Before running, create a Developer ID Application certificate and a
# notarytool keychain profile, then export:
#   LEXICON_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)"
#   LEXICON_NOTARY_PROFILE="lexicon-notary"
#
# Usage:
#   scripts/release.sh [version] [build-number]
#   scripts/release.sh --unsigned [version] [build-number]
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="signed"
if [[ "${1:-}" == "--unsigned" ]]; then
    MODE="unsigned"
    shift
fi

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${2:-1}"
SIGNING_IDENTITY="${LEXICON_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LEXICON_NOTARY_PROFILE:-}"
SOURCE_VERSION="$(tr -d '[:space:]' < VERSION)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must contain three numeric components, such as 0.1.0" >&2
    exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: build number must be a positive integer" >&2
    exit 2
fi

if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
    echo "error: requested version $VERSION does not match VERSION ($SOURCE_VERSION)" >&2
    exit 2
fi

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "error: commit or stash all source changes before creating a release" >&2
    exit 2
fi

if [[ "$MODE" == "signed" ]]; then
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "error: set LEXICON_SIGNING_IDENTITY to a Developer ID Application identity" >&2
        exit 2
    fi

    if [[ -z "$NOTARY_PROFILE" ]]; then
        echo "error: set LEXICON_NOTARY_PROFILE to a notarytool keychain profile" >&2
        exit 2
    fi

    if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
        echo "error: signing identity is not available in the current keychain" >&2
        exit 2
    fi
else
    SIGNING_IDENTITY="-"
fi

export LEXICON_VERSION="$VERSION"
export LEXICON_BUILD_NUMBER="$BUILD_NUMBER"
export LEXICON_SIGNING_IDENTITY="$SIGNING_IDENTITY"
scripts/make_app.sh release

APP="build/Lexicon.app"
DIST="dist"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Lexicon" | tr ' ' '-')"
BASENAME="Lexicon-$VERSION-macOS-$ARCHITECTURES"
if [[ "$MODE" == "unsigned" ]]; then
    BASENAME="$BASENAME-unsigned"
fi
NOTARY_ZIP="$DIST/.$BASENAME-notarization.zip"
RELEASE_ZIP="$DIST/$BASENAME.zip"
CHECKSUM="$RELEASE_ZIP.sha256"

mkdir -p "$DIST"
rm -f "$NOTARY_ZIP" "$RELEASE_ZIP" "$CHECKSUM"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$MODE" == "unsigned" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_ZIP"
    (
        cd "$DIST"
        shasum -a 256 "$(basename "$RELEASE_ZIP")" > "$(basename "$CHECKSUM")"
    )
    echo "warning: this build is not Developer ID signed or notarized" >&2
    echo "Unsigned release artifact: $RELEASE_ZIP"
    echo "Checksum: $CHECKSUM"
    exit 0
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"

xcrun notarytool submit \
    "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_ZIP"
rm -f "$NOTARY_ZIP"

(
    cd "$DIST"
    shasum -a 256 "$(basename "$RELEASE_ZIP")" > "$(basename "$CHECKSUM")"
)

echo "Release artifact: $RELEASE_ZIP"
echo "Checksum: $CHECKSUM"
