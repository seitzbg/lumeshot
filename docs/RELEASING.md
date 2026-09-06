# Releasing Lumeshot

Releases are built by `.github/workflows/release.yml` on a version tag push, and are
**Developer ID signed and notarized** when the signing secrets are present.

## Cut a release

Write `docs/releases/<tag>.md` and commit it before creating the tag. Describe
user-visible changes and upgrade steps in plain language, with no author mentions
or attribution trailers. The workflow requires this file and publishes it verbatim;
it does not generate notes from PR titles. For example, `v0.2.0` requires
`docs/releases/v0.2.0.md`.

    git tag v0.2.0
    git push origin v0.2.0

Pushing a `v*` tag triggers the `Release` workflow on `macos-15`, which:

1. `swift test` — the tag may point at a commit the push/PR workflow never saw, so the
   suite is re-run rather than trusted.
2. `swift build -c release`
3. Imports the Developer ID certificate into a throwaway keychain (skipped if unsigned).
4. `scripts/bundle.sh` — bundles `.build/release/LumeshotApp` into `dist/Lumeshot.app`,
   signed with the hardened runtime, `Resources/Lumeshot.entitlements`, and a secure timestamp.
5. Verifies the signature's `TeamIdentifier` matches the `TEAM_ID` secret.
6. `scripts/dmg.sh` — packages the `.app` into `dist/Lumeshot-<version>.dmg` and signs the dmg.
7. `scripts/notarize.sh` — submits to Apple's notary service, waits for the verdict, staples
   the ticket into the dmg, and runs a Gatekeeper assessment.
8. Publishes the tag as a GitHub Release with the dmg and `SHA256SUMS.txt` attached.

The version in `Info.plist` and the dmg filename come from the tag (`GITHUB_REF_NAME` with
the leading `v` stripped) — no separate version bump is needed.

Checksums are generated *after* notarization on purpose: stapling rewrites the dmg, so sums
taken earlier would not match what people download.

## One-time signing setup

Run the wizard, which walks through the Apple portals and uploads the secrets:

    scripts/setup-developer-id.sh

**Run it on the machine where `gh` is authenticated and the git checkout lives** — for this
project that is the Linux dev box, over ssh. Not the Mac mirror: rsync excludes `.git` there
and `gh` is not installed, so setting secrets would silently do nothing.

That box is headless, so the wizard prints each URL for you to open on whatever machine has
a browser, rather than pretending to launch one. Files move in both directions: it offers to
print the CSR for copy/paste (a CSR is public — it is a public key and a subject), and each
download can arrive as a local path, an `scp` pull (`host:path`), or pasted base64.

It generates a private key and CSR locally, has you create a **Developer ID Application**
certificate, packages it as a `.p12` (with Apple's G2 intermediate — omitting that is the
usual cause of `errSecInternalComponent` on a clean runner), creates an App Store Connect
API key for notarization, and sets six repository secrets:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12` | base64 of the `.p12` (private key + cert + intermediate) |
| `DEVELOPER_ID_P12_PASSWORD` | random password protecting that `.p12` |
| `ASC_KEY_P8` | base64 of the App Store Connect API key |
| `ASC_KEY_ID` | that key's 10-character Key ID |
| `ASC_ISSUER_ID` | the issuer UUID |
| `TEAM_ID` | 10-character Apple Team ID; asserted against the signature |

Notarization uses an App Store Connect API key rather than an Apple ID and app-specific
password: it is independently revocable, survives password changes, and needs no 2FA
interaction on a runner.

**Back up the `.p12` before letting the wizard clean up.** GitHub secrets are write-only —
once `DEVELOPER_ID_P12` is set, nothing can read it back, so the working copy is the only
one you can still reach. Apple will not re-issue the private key; losing it means revoking
the certificate and using another Developer ID slot. Published releases are unaffected
(they are notarized, stapled and timestamped), so this costs a re-issue, not a broken
release. Recovering the key out of the secret via a workflow artifact is **not** an option
on a public repo: artifacts are downloadable by anyone who can view the run.

**Signing is opt-in.** The workflow enables it only when both `DEVELOPER_ID_P12` and
`ASC_KEY_P8` exist. Without them the release still builds and publishes — ad-hoc signed and
unnotarized, with a `::warning::` in the log — so a fork or a secret-less repo is not a
broken release.

## Verifying a published dmg

See `docs/smoke-signing.md`. The short version, on a Mac that has never run Lumeshot:

    spctl --assess --type open --context context:primary-signature -v Lumeshot-0.2.0.dmg
    xcrun stapler validate Lumeshot-0.2.0.dmg

## Local (manual) build

    scripts/remote.sh ssh 'swift build -c release && scripts/bundle.sh && VERSION=0.2.0 scripts/dmg.sh'

Local builds use the self-signed `lumeshot-dev` identity from `scripts/setup-signing.sh`,
not the Developer ID certificate — the real private key stays in GitHub secrets and never
reaches the dev Mac. They still get the hardened runtime and the same entitlements, so the
dev loop exercises the runtime restrictions the shipped app runs under.

## Why notarization matters here

Two user-visible things depended on it:

- **Notifications.** A self-signed app is not registered with Notification Center, so
  capture/upload notifications silently never fire.
- **Gatekeeper.** An ad-hoc dmg requires the right-click → Open dance on first launch
  ("can't be opened because Apple cannot check it for malicious software").
