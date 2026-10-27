#!/bin/bash
# Fills in packaging/homebrew/vision-one.rb for a release and pushes it to
# the tap repo (VenusOne-Lee/homebrew-tap, Casks/vision-one.rb).
#
#   TAP_TOKEN=... VERSION=0.1.0 scripts/release/update-cask.sh build/release/Vision-One-0.1.0.dmg
set -euo pipefail

DMG=${1:?path to the released .dmg}
: "${VERSION:?}" "${TAP_TOKEN:?a token that can push to the tap repo}"
TAP_REPO=${TAP_REPO:-VenusOne-Lee/homebrew-tap}
TEMPLATE="$(cd "$(dirname "$0")/../.." && pwd)/packaging/homebrew/vision-one.rb"

sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
tap=$(mktemp -d)
trap 'rm -rf "$tap"' EXIT

git clone --depth 1 "https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git" "$tap"
mkdir -p "$tap/Casks"
sed -e "s/{{VERSION}}/$VERSION/" -e "s/{{SHA256}}/$sha/" "$TEMPLATE" > "$tap/Casks/vision-one.rb"

cd "$tap"
if git diff --quiet && [[ -z "$(git status --porcelain)" ]]; then
  echo "Cask already at $VERSION"
  exit 0
fi
git add Casks/vision-one.rb
git -c user.name="vision-one-release" -c user.email="actions@users.noreply.github.com" \
  commit -m "vision-one $VERSION"
git push
echo "Pushed vision-one $VERSION to $TAP_REPO"
