#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Lumeshot.app"
VERSION="${VERSION:-0.1.0}"

# Ad-hoc signatures change every build, resetting the TCC Screen Recording
# grant. A stable self-signed identity keeps the grant across rebuilds because
# TCC keys off the cert identity, not the binary hash. We use a dedicated
# signing keychain (created by scripts/setup-signing.sh) rather than the login
# keychain, because the login keychain is locked to non-interactive ssh
# sessions ("User interaction is not allowed") and codesign can't reach its
# keys. Sign by SHA-1 hash, not name, to avoid ambiguity with any same-named
# cert in other keychains. Fall back to ad-hoc when the keychain is absent (CI).
SIGN_KC="$HOME/Library/Keychains/sharex-signing.keychain-db"
SIGN_PW_FILE="$HOME/.config/sharex-mac/signing.pw"
CODESIGN_ID="${CODESIGN_ID:-}"
SIGN_KC_ARGS=()

if [ -z "$CODESIGN_ID" ]; then
    if [ -f "$SIGN_KC" ] && [ -f "$SIGN_PW_FILE" ]; then
        security unlock-keychain -p "$(cat "$SIGN_PW_FILE")" "$SIGN_KC" >/dev/null 2>&1 || true
        CODESIGN_ID="$(security find-identity -p codesigning "$SIGN_KC" \
            | awk '/[0-9A-F]{40}/{print $2; exit}')"
        SIGN_KC_ARGS=(--keychain "$SIGN_KC")
    fi
    CODESIGN_ID="${CODESIGN_ID:--}"   # ad-hoc if still unset
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SXApp "$APP/Contents/MacOS/SXApp"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "$CODESIGN_ID" --identifier org.sharexmac.app ${SIGN_KC_ARGS[@]+"${SIGN_KC_ARGS[@]}"} "$APP"
echo "Built $APP (version $VERSION, sign: $CODESIGN_ID)"
