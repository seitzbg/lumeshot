#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/Lumeshot.app"
[ -d "$APP" ] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }
STAGE="dist/dmg-root"
DMG="dist/Lumeshot-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lumeshot" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Sign the disk image itself when signing for real. The .app inside is already
# signed; signing the container too is what lets `spctl -a -t open` evaluate the
# dmg a user actually downloads, and it is required before the notary ticket can
# be stapled to it.
if [ "${DEVELOPER_ID_SIGNING:-0}" = "1" ] && [ -n "${CODESIGN_ID:-}" ]; then
    codesign --force --sign "$CODESIGN_ID" --timestamp \
        ${CODESIGN_KEYCHAIN:+--keychain "$CODESIGN_KEYCHAIN"} "$DMG"
    codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'
fi

echo "Built $DMG"
