#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Lumeshot.app"
VERSION="${VERSION:-0.1.0}"
ENTITLEMENTS="Resources/Lumeshot.entitlements"

# Signing identity resolution, in priority order:
#
#   1. $CODESIGN_ID              — explicit override (CI passes the imported
#                                  Developer ID hash here).
#   2. the dev signing keychain  — the self-signed `lumeshot-dev` identity
#                                  from scripts/setup-signing.sh.
#   3. ad-hoc ("-")              — last resort.
#
# Ad-hoc signatures change every build, resetting the TCC Screen Recording
# grant. A stable identity keeps the grant across rebuilds because TCC keys off
# the cert identity, not the binary hash. We use a dedicated signing keychain
# rather than the login keychain, because the login keychain is locked to
# non-interactive ssh sessions ("User interaction is not allowed") and codesign
# can't reach its keys. Sign by SHA-1 hash, not name, to avoid ambiguity with
# any same-named cert in other keychains.
SIGN_KC="$HOME/Library/Keychains/lumeshot-signing.keychain-db"
SIGN_PW_FILE="$HOME/.config/lumeshot/signing.pw"
CODESIGN_ID="${CODESIGN_ID:-}"
SIGN_KC_ARGS=()

if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    SIGN_KC_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
elif [ -z "$CODESIGN_ID" ]; then
    if [ -f "$SIGN_KC" ] && [ -f "$SIGN_PW_FILE" ]; then
        security unlock-keychain -p "$(cat "$SIGN_PW_FILE")" "$SIGN_KC" >/dev/null 2>&1 || true
        CODESIGN_ID="$(security find-identity -p codesigning "$SIGN_KC" \
            | awk '/[0-9A-F]{40}/{print $2; exit}')"
        SIGN_KC_ARGS=(--keychain "$SIGN_KC")
    fi
fi
CODESIGN_ID="${CODESIGN_ID:--}"   # ad-hoc if still unset

# A secure timestamp is mandatory for notarization, but it needs a real CA-issued
# certificate and a round trip to Apple's timestamp server. The self-signed dev
# identity can neither obtain nor need one, and requiring it would make the
# offline/ssh dev loop fail. Opt in only when signing for real.
if [ "${DEVELOPER_ID_SIGNING:-0}" = "1" ]; then
    TIMESTAMP_ARG=(--timestamp)
else
    TIMESTAMP_ARG=(--timestamp=none)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LumeshotApp "$APP/Contents/MacOS/LumeshotApp"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# --options runtime is what notarization actually requires. It is applied on
# every path, not just releases, so the dev loop exercises the same runtime
# restrictions the shipped app will run under instead of discovering a library
# validation failure at notarization time.
codesign --force --sign "$CODESIGN_ID" \
    --identifier org.lumeshot.app \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "${TIMESTAMP_ARG[@]}" \
    ${SIGN_KC_ARGS[@]+"${SIGN_KC_ARGS[@]}"} \
    "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "Built $APP (version $VERSION, sign: $CODESIGN_ID)"
