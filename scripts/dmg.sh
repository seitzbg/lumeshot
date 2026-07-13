#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/ShareX for Mac.app"
[ -d "$APP" ] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }
STAGE="dist/dmg-root"
DMG="dist/ShareX-for-Mac-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ShareX for Mac" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"
