#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${BUNDLE_OUTPUT:-dist/Lumeshot.app}"
VERSION="${VERSION:-0.1.0}"
# Only the release workflow sets this. Everything else is a development build,
# which the in-app update check refuses to compare against published releases —
# the VERSION default above would otherwise look like a real, older release.
RELEASE_CHANNEL="${RELEASE_CHANNEL:-development}"
# Release builds ship the empty entitlements. Local builds need one hardened
# runtime exception (library validation) because they have no Apple-issued
# certificate and therefore no Team ID to match Sparkle's — see the comment in
# Resources/Lumeshot-dev.entitlements. Selected by the same flag that gates the
# secure timestamp, so "real signing" is one decision, not two.
if [ "${DEVELOPER_ID_SIGNING:-0}" = "1" ]; then
    ENTITLEMENTS="Resources/Lumeshot.entitlements"
else
    ENTITLEMENTS="Resources/Lumeshot-dev.entitlements"
fi

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

# SwiftPM links the executable with @loader_path only, which resolves
# @rpath/Sparkle.framework while the binary sits next to the framework in
# .build/release. Moving it into Contents/MacOS breaks that: the framework goes
# to Contents/Frameworks, so the executable must also search there. Without this
# the bundle builds, signs and verifies cleanly, then dies at exec with
# "Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle".
# Done here rather than in Package.swift because it is a fact about the app
# bundle layout, which only this script knows. Must precede codesign: editing
# load commands invalidates any existing signature.
install_name_tool -add_rpath @executable_path/../Frameworks \
    "$APP/Contents/MacOS/LumeshotApp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Sources/LumeshotApp/Resources/OpenSourceCredits.json "$APP/Contents/Resources/"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@CHANNEL@/$RELEASE_CHANNEL/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# Sparkle ships ad-hoc signed and contains nested code — Updater.app and the
# Autoupdate helper — so it must be re-signed with our identity, innermost first.
# Signing the outer app does not reach inside a nested bundle, and notarization
# rejects anything left ad-hoc.
#
# The XPC services are removed rather than signed: they exist for sandboxed apps,
# Lumeshot is not sandboxed (Resources/Lumeshot.entitlements is deliberately
# empty), and deleting them drops two more nested bundles from the signing surface.
SPARKLE_SRC=".build/release/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    rm -rf "$FW/Versions/B/XPCServices"
    for nested in "$FW/Versions/B/Updater.app" "$FW/Versions/B/Autoupdate" "$FW/Versions/B"; do
        [ -e "$nested" ] || continue
        codesign --force --sign "$CODESIGN_ID" \
            --options runtime \
            "${TIMESTAMP_ARG[@]}" \
            ${SIGN_KC_ARGS[@]+"${SIGN_KC_ARGS[@]}"} \
            "$nested"
    done
else
    # Sparkle is a mandatory link-time dependency: a bundle without it cannot
    # launch at all, so shipping one is worse than failing the build here.
    echo "error: $SPARKLE_SRC not found — the executable links Sparkle and" \
         "cannot start without it. Run 'swift build -c release' first." >&2
    exit 1
fi

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

# Launch smoke test. A valid signature says nothing about whether dyld can
# resolve the bundle's dynamic libraries: the rpath bug above produced a bundle
# that built, signed and verified, and then failed at exec. This runs the real
# signed binary, so an unresolvable @rpath fails the build instead of shipping.
#
# --version exits before NSApplication starts and touches no capture API, so it
# cannot register with TCC or re-point the installed app's Screen Recording
# grant the way a genuine second instance would.
echo "Launch smoke test:"
if ! SMOKE="$("$APP/Contents/MacOS/LumeshotApp" --version 2>&1)"; then
    echo "  FAILED: the bundled executable did not start" >&2
    echo "$SMOKE" | sed 's/^/  /' >&2
    exit 1
fi
echo "  $SMOKE"

echo "Built $APP (version $VERSION, channel: $RELEASE_CHANNEL, sign: $CODESIGN_ID)"
