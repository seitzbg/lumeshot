#!/usr/bin/env bash
# One-time: create a dedicated signing keychain with a self-signed code-signing
# identity, so the ssh dev loop can codesign non-interactively and TCC grants
# survive rebuilds. The keychain password protects only a throwaway self-signed
# cert (no real secret), so we store it in a mode-600 file.
set -euo pipefail

KC_DIR="$HOME/Library/Keychains"
KC="$KC_DIR/sharex-signing.keychain-db"
CFG_DIR="$HOME/.config/sharex-mac"
PW_FILE="$CFG_DIR/signing.pw"
CN="sharex-mac-dev"

mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
if [ ! -f "$PW_FILE" ]; then
    /usr/bin/openssl rand -hex 16 > "$PW_FILE"; chmod 600 "$PW_FILE"
fi
PW="$(cat "$PW_FILE")"

# Recreate the keychain cleanly.
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"   # no auto-lock timeout

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:"$PW" -name "$CN"

security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1

# Add to the search list (keep existing entries).
EXISTING="$(security list-keychains -d user | sed 's/["[:space:]]//g')"
security list-keychains -d user -s "$KC" $EXISTING >/dev/null 2>&1 || true

echo "=== signing identities in $KC ==="
security find-identity -p codesigning "$KC"
