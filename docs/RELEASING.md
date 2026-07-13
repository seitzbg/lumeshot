# Releasing ShareX for Mac

Releases are ad-hoc signed (no Apple Developer account, no notarization) and built by
`.github/workflows/release.yml` on a version tag push.

## Cut a release

    git tag v0.2.0
    git push origin v0.2.0

Pushing a `v*` tag triggers the `Release` workflow on `macos-15`, which:

1. `swift build -c release`
2. `scripts/bundle.sh` — bundles `.build/release/SXApp` into `dist/ShareX for Mac.app`, ad-hoc
   signed (`codesign --sign -`; no dev signing keychain exists on CI runners).
3. `scripts/dmg.sh` — packages the `.app` into `dist/ShareX-for-Mac-<version>.dmg` via `hdiutil`.
4. `gh release create` — publishes the tag as a GitHub Release with the `.dmg` attached and
   auto-generated release notes.

The version embedded in `Info.plist` and the dmg filename come from the tag itself
(`GITHUB_REF_NAME` with the leading `v` stripped) — no separate version bump is needed elsewhere.

## Ad-hoc signing caveat

The release build is signed with `codesign --sign -` (ad-hoc), not a Developer ID certificate —
there is no Apple Developer account or notarization in this pipeline. On first launch, macOS
Gatekeeper will refuse to open the app with a plain double-click ("can't be opened because Apple
cannot check it for malicious software"). Users need to **right-click → Open** (or
`xattr -d com.apple.quarantine "ShareX for Mac.app"`) once to bypass this; subsequent launches
work normally.

## Local (manual) build

To build a dmg without cutting a tag, e.g. to test packaging:

    scripts/remote.sh ssh 'swift build -c release && scripts/bundle.sh && VERSION=0.2.0 scripts/dmg.sh'
