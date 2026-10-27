#!/bin/bash
# Packs Vision One.app into a compressed DMG with an Applications shortcut,
# so installing is one drag.
#
#   scripts/release/make-dmg.sh "build/release/Vision One.app" build/release/Vision-One-0.1.0.dmg
#
# With SIGN=1 and TEAM_ID set, the DMG is signed with Developer ID too.
set -euo pipefail

APP=${1:?path to Vision One.app}
DMG=${2:?path for the .dmg}
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Vision One.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Vision One" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"

if [[ "${SIGN:-0}" == 1 ]]; then
  : "${TEAM_ID:?set TEAM_ID}"
  identity=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | awk '{print $2}')
  [[ -n "$identity" ]] || { echo "No Developer ID Application certificate for $TEAM_ID" >&2; exit 1; }
  codesign --sign "$identity" --timestamp "$DMG"
fi
echo "Made $DMG ($(du -h "$DMG" | cut -f1))"
