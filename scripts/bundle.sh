#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ShareX for Mac.app"
VERSION="${VERSION:-0.1.0}"
# Ad-hoc signatures change every build, which resets the TCC Screen Recording
# grant. Prefer the stable "sharex-mac-dev" self-signed cert when the machine
# has one (dev Macs); fall back to ad-hoc (CI).
# Note: no -v — a self-signed dev cert is untrusted as a root but still signs
# fine locally, and TCC keys off the stable cert identity, not its trust.
if [ -z "${CODESIGN_ID:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "sharex-mac-dev"; then
        CODESIGN_ID="sharex-mac-dev"
    else
        CODESIGN_ID="-"
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SXApp "$APP/Contents/MacOS/SXApp"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "$CODESIGN_ID" --identifier org.sharexmac.app "$APP"
echo "Built $APP (version $VERSION, sign: $CODESIGN_ID)"
