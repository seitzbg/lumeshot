#!/usr/bin/env bash
# Submit a signed dmg to Apple's notary service, wait for the verdict, and
# staple the resulting ticket into the dmg so it validates offline.
#
# Requires an App Store Connect API key (a .p8) rather than an Apple ID and
# app-specific password: it is independently revocable, survives password
# changes, and needs no 2FA interaction on a CI runner.
#
# Env:
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXX.p8
#   ASC_KEY_ID     the key's 10-character Key ID
#   ASC_ISSUER_ID  the issuer UUID from App Store Connect → Integrations → Keys
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
[ -n "$DMG" ] || { echo "usage: notarize.sh <path-to-dmg>" >&2; exit 2; }
[ -f "$DMG" ] || { echo "error: $DMG not found" >&2; exit 1; }

for var in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    [ -n "${!var:-}" ] || { echo "error: \$$var is not set" >&2; exit 1; }
done
[ -f "$ASC_KEY_PATH" ] || { echo "error: key file $ASC_KEY_PATH not found" >&2; exit 1; }

echo "==> Submitting $DMG to the notary service (this usually takes 1-5 minutes)"
# --wait blocks until Apple reaches a verdict. Without it the command returns
# immediately with a submission id and a later staple would fail confusingly.
set +e
SUBMIT_OUTPUT="$(xcrun notarytool submit "$DMG" \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 30m --output-format json 2>&1)"
SUBMIT_STATUS=$?
set -e
echo "$SUBMIT_OUTPUT"

SUBMISSION_ID="$(printf '%s' "$SUBMIT_OUTPUT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
STATUS="$(printf '%s' "$SUBMIT_OUTPUT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"

if [ "$SUBMIT_STATUS" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
    echo "error: notarization did not succeed (status: ${STATUS:-unknown})" >&2
    # The log is the only place that says *why* — a rejected submission
    # otherwise gives you nothing actionable.
    if [ -n "$SUBMISSION_ID" ]; then
        echo "==> Notary log for $SUBMISSION_ID:" >&2
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
    fi
    exit 1
fi

echo "==> Stapling the ticket into $DMG"
# Stapling is what makes the dmg validate without a network round trip on the
# user's machine. Notarization alone is not enough for an offline first launch.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment"
# The real question is whether a downloaded dmg opens, so assess it the way
# Gatekeeper will rather than trusting "Accepted" alone.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Notarized and stapled: $DMG"
