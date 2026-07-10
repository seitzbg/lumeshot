#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ShareX for Mac.app"
VERSION="${VERSION:-0.1.0}"
CODESIGN_ID="${CODESIGN_ID:--}"   # '-' = ad-hoc; set a stable dev cert to keep TCC grants across rebuilds

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SXApp "$APP/Contents/MacOS/SXApp"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "$CODESIGN_ID" --identifier org.sharexmac.app "$APP"
echo "Built $APP (version $VERSION, sign: $CODESIGN_ID)"
