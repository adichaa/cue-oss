#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

source build.env

VERSION=${1:-"0.1"}
DMG_NAME="cue-${VERSION}.dmg"
STAGING="$(mktemp -d)/dmg-staging"

echo "→ Building app…"
bash build-app.sh

echo "→ Staging DMG contents…"
mkdir -p "$STAGING"
cp -R /Applications/Cue.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating DMG…"
hdiutil create \
  -volname "cue" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "dist/$DMG_NAME"

rm -rf "$(dirname "$STAGING")"

echo "→ Notarizing…"
xcrun notarytool submit "dist/$DMG_NAME" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait 2>&1

echo "→ Stapling…"
xcrun stapler staple "dist/$DMG_NAME" 2>&1

echo "✓ dist/$DMG_NAME (notarized)"
