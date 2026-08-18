#!/bin/bash
# Builds Lexicon and packages it for a GitHub release.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make_app.sh

mkdir -p dist
rm -f dist/Lexicon.zip
ditto -c -k --sequesterRsrc --keepParent build/Lexicon.app dist/Lexicon.zip

echo "Release artifact: dist/Lexicon.zip"
