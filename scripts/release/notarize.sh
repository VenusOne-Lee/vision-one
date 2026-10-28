#!/bin/bash
# Sends a file to Apple's notary service, waits, and staples the ticket.
# Works for the .app (zipped for upload) and the .dmg.
#
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER_ID=... \
#     scripts/release/notarize.sh "build/release/Vision One.app"
set -euo pipefail

TARGET=${1:?path to the .app or .dmg}
: "${NOTARY_KEY:?path to the App Store Connect API key (.p8)}"
: "${NOTARY_KEY_ID:?App Store Connect key ID}"
: "${NOTARY_ISSUER_ID:?App Store Connect issuer ID}"

upload=$TARGET
if [[ "$TARGET" == *.app ]]; then
  upload="${TARGET%.app}.zip"
  ditto -c -k --keepParent "$TARGET" "$upload"
fi

result=$(xcrun notarytool submit "$upload" --wait --output-format json \
  --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
echo "$result"
id=$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
status=$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
if [[ "$status" != "Accepted" ]]; then
  echo "Notarization said: ${status:-no answer}. Apple's log:" >&2
  if [[ -n "$id" ]]; then
    xcrun notarytool log "$id" \
      --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2
  fi
  exit 1
fi

# Apple's ticket can take a few minutes to reach its servers after
# "Accepted", and the lookup sometimes drops the connection, so retry.
for attempt in 1 2 3 4 5 6; do
  if xcrun stapler staple "$TARGET"; then break; fi
  if (( attempt == 6 )); then
    echo "Couldn't staple the ticket after $attempt tries." >&2
    exit 1
  fi
  echo "Stapling failed (try $attempt), trying again in $((attempt * 20))s." >&2
  sleep $((attempt * 20))
done
if [[ "$upload" != "$TARGET" ]]; then rm -f "$upload"; fi
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
