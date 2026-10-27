#!/bin/bash
# Writes the Sparkle appcast for one release: the DMG's link, size and
# EdDSA signature, plus the release notes. Apps read it from
# releases/latest/download/appcast.xml.
#
#   SPARKLE_KEY_FILE=key.txt VERSION=0.1.0 BUILD_NUMBER=42 \
#     DOWNLOAD_URL=https://github.com/.../Vision-One-0.1.0.dmg NOTES=notes.md \
#     scripts/release/make-appcast.sh build/release/Vision-One-0.1.0.dmg build/release/appcast.xml
#
# SPARKLE_KEY_FILE holds the private key from Sparkle's `generate_keys -x`.
# sign_update comes from the Sparkle package Xcode downloaded.
set -euo pipefail

DMG=${1:?path to the .dmg}
APPCAST=${2:?path for appcast.xml}
: "${VERSION:?}" "${BUILD_NUMBER:?}" "${DOWNLOAD_URL:?}" "${SPARKLE_KEY_FILE:?}"
DERIVED=${DERIVED:-build/DerivedData}

sign_update=${SIGN_UPDATE:-$(find "$DERIVED" -path '*Sparkle*/bin/sign_update' -type f 2>/dev/null | head -1)}
[[ -x "$sign_update" ]] || { echo "Can't find Sparkle's sign_update under $DERIVED" >&2; exit 1; }

# Prints: sparkle:edSignature="..." length="..."
signature=$("$sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG")

VERSION=$VERSION BUILD_NUMBER=$BUILD_NUMBER DOWNLOAD_URL=$DOWNLOAD_URL \
SIGNATURE=$signature NOTES=${NOTES:-} \
  python3 -I "$(dirname "$0")/appcast.py" > "$APPCAST"
echo "Wrote $APPCAST"
