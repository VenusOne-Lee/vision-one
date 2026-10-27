#!/bin/bash
# Builds a Release copy of Vision One.app into $OUT (default build/release).
#
#   VERSION=0.1.0 BUILD_NUMBER=42 scripts/release/build-app.sh
#
# With SIGN=1 it signs with your Developer ID Application certificate
# (needs TEAM_ID and the certificate in a keychain) and exports the app the
# way Xcode's Organizer does, which also signs Sparkle's helpers. Without
# it the app is ad hoc signed: fine to test the DMG, not to ship.
# SPARKLE_PUBLIC_KEY turns on update checks in the built app.
set -euo pipefail

: "${VERSION:?set VERSION, like 0.1.0}"
: "${BUILD_NUMBER:?set BUILD_NUMBER, a whole number that only goes up}"
OUT=${OUT:-build/release}
DERIVED=${DERIVED:-build/DerivedData}
ARCHIVE="$OUT/Vision One.xcarchive"

rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate

settings=(
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
  ARCHS=arm64
)
if [[ "${SIGN:-0}" == 1 ]]; then
  : "${TEAM_ID:?set TEAM_ID, your Apple team ID}"
  settings+=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=Developer ID Application"
    DEVELOPMENT_TEAM="$TEAM_ID"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
else
  settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

xcodebuild archive \
  -project VisionOne.xcodeproj -scheme VisionOne -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  "${settings[@]}" | tee "$OUT/archive.log" | grep -E '^(\*\*|error|warning: .*Sparkle)' || true
[[ -d "$ARCHIVE/Products/Applications/Vision One.app" ]] || {
  echo "Archive failed. Last lines of $OUT/archive.log:" >&2
  tail -40 "$OUT/archive.log" >&2
  exit 1
}

if [[ "${SIGN:-0}" == 1 ]]; then
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"
  mv "$OUT/export/Vision One.app" "$OUT/"
  codesign --verify --deep --strict --verbose=2 "$OUT/Vision One.app"
else
  ditto "$ARCHIVE/Products/Applications/Vision One.app" "$OUT/Vision One.app"
fi

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' \
  "$OUT/Vision One.app/Contents/Info.plist"
echo "Built $OUT/Vision One.app"
