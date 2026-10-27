#!/bin/bash
# Signs a file with the Sparkle private key the way make-appcast.sh does,
# then checks the signature with the public key, so you know the two halves
# belong together before any user depends on them. Prints only pass or fail.
#
#   SPARKLE_KEY_FILE=key.txt SPARKLE_PUBLIC_KEY=... \
#     scripts/release/check-sparkle-key.sh build/release/Vision-One-0.1.0.dmg
#
# Needs OpenSSL 3 (brew install openssl@3) and Sparkle's sign_update from
# the package Xcode downloaded.
set -euo pipefail

FILE=${1:?path to the file to sign, like the .dmg}
: "${SPARKLE_KEY_FILE:?path to the Sparkle private key}" "${SPARKLE_PUBLIC_KEY:?Sparkle public key}"
DERIVED=${DERIVED:-build/DerivedData}

sign_update=${SIGN_UPDATE:-$(find "$DERIVED" -path '*Sparkle*/bin/sign_update' -type f 2>/dev/null | head -1)}
[[ -x "$sign_update" ]] || { echo "Can't find Sparkle's sign_update under $DERIVED" >&2; exit 1; }
openssl=${OPENSSL:-$(brew --prefix openssl@3 2>/dev/null)/bin/openssl}
[[ -x "$openssl" ]] || openssl=openssl

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Prints: sparkle:edSignature="..." length="..."
signature=$("$sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$FILE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
[[ -n "$signature" ]] || { echo "sign_update gave no signature" >&2; exit 1; }
printf '%s' "$signature" | base64 --decode > "$work/sig"

# An Ed25519 public key in DER is a fixed 12-byte header and the 32 raw bytes.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$SPARKLE_PUBLIC_KEY" | base64 --decode; } > "$work/pub.der"
[[ $(wc -c < "$work/pub.der") -eq 44 ]] || { echo "SPARKLE_PUBLIC_KEY isn't a 32-byte Ed25519 key" >&2; exit 1; }

if "$openssl" pkeyutl -verify -pubin -inkey "$work/pub.der" -keyform DER -rawin \
    -in "$FILE" -sigfile "$work/sig" >/dev/null 2>&1; then
  echo "Sparkle key pair OK: the private key's signature checks out with the public key."
else
  echo "Sparkle key pair MISMATCH: SPARKLE_PRIVATE_KEY and SPARKLE_PUBLIC_KEY don't belong together." >&2
  exit 1
fi
