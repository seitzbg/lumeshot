# Releasing Lumeshot

Releases are built by `.github/workflows/release.yml` on a version tag push, and are
**Developer ID signed and notarized** when the signing secrets are present.

## Cut a release

Write `docs/releases/<tag>.md` and commit it before creating the tag. Describe
user-visible changes and upgrade steps in plain language, with no author mentions
or attribution trailers. The workflow requires this file and publishes it verbatim;
it does not generate notes from PR titles. For example, `v0.2.0` requires
`docs/releases/v0.2.0.md`. Keep it to changes in the shipped app — repository
housekeeping such as refreshed screenshots is not a release note.

The tag supplies the version to the *build* (see below), but several documents carry
the version by hand. Work this checklist in the release-prep commit; nothing verifies
it for you, and v0.1.8 shipped with four stale `v0.1.7` references because it was done
from memory.

- [ ] `docs/releases/<tag>.md` — the release body, user-visible changes only.
- [ ] `CHANGELOG.md` — promote what is under `## Unreleased` to a new version
      bullet under the existing `## Releases` heading (do not add a second one),
      then leave `## Unreleased` behind with `_Nothing yet._`.
- [ ] `docs/ROADMAP.md` — same promotion for its `## Unreleased` section; retitle it
      `## <tag> — released`, and re-point anything that says "current release",
      "latest validation", or names the previous version in a *pending* check.
- [ ] `README.md` — the **Status:** line, the Download link, and any screenshot
      caption that names a version.
- [ ] Screenshots — when replacing one, update *every* page that embeds it.
      `scripts/check-doc-links.sh` fails CI on a reference that no longer resolves.
- [ ] `bash scripts/check-doc-links.sh` passes locally.

Then tag:

    git tag v0.2.0
    git push origin v0.2.0

Publishing is not instant — notarization can take minutes and the release only appears
after step 8 below. Confirm `gh release view <tag>` shows the dmg before treating the
README's "released" claim as true.

Pushing a `v*` tag triggers the `Release` workflow on `macos-15`, which:

1. `swift test` — the tag may point at a commit the push/PR workflow never saw, so the
   suite is re-run rather than trusted.
2. `swift build -c release`
3. Imports the Developer ID certificate into a throwaway keychain (skipped if unsigned).
4. `scripts/bundle.sh` — bundles `.build/release/LumeshotApp` into `dist/Lumeshot.app`,
   signed with the hardened runtime, `Resources/Lumeshot.entitlements`, and a secure timestamp.
   It passes `RELEASE_CHANNEL=release`, which stamps `LumeshotReleaseChannel` into
   `Info.plist`. Nothing else sets it, so every local bundle is a development build and
   **Check for Updates…** refuses to compare it against published releases — the
   `VERSION` default of 0.1.0 would otherwise look like a real, older release.
5. Verifies the signature's `TeamIdentifier` matches the `TEAM_ID` secret.
6. `scripts/dmg.sh` — packages the `.app` into `dist/Lumeshot-<version>.dmg` and signs the dmg.
7. `scripts/notarize.sh` — submits to Apple's notary service, waits for the verdict, staples
   the ticket into the dmg, and runs a Gatekeeper assessment.
8. Publishes the tag as a GitHub Release with the dmg and `SHA256SUMS.txt` attached.
9. Adds the release to the Sparkle appcast on the `gh-pages` branch, which GitHub Pages
   serves at `https://seitzbg.github.io/lumeshot/appcast.xml`. Only that file is pushed —
   the dmg stays on the release CDN and the feed points at it.

Installed copies check that feed, so **a release that fails at step 9 is invisible to
existing users** even though the GitHub Release exists. The step fails loudly rather than
skipping if `SPARKLE_PRIVATE_KEY` is missing or the feed comes back unchanged.

Step 9 is skipped for unsigned builds. Advertising an ad-hoc build to installed copies
would offer an update Gatekeeper then refuses.

### Sparkle keys

`SUPublicEDKey` in `Resources/Info.plist` is public and verifies signatures.
`SPARKLE_PRIVATE_KEY` is a repository secret holding the private half, exported from the
login Keychain with `generate_keys -x`. **Back up the Keychain copy.** Losing it means
installed copies can never verify another update — recovery requires shipping a new public
key in a build users install by hand.

To confirm the secret still matches what the app ships, run the `verify-sparkle-key`
workflow. It derives the public half of the secret and compares it, without publishing
anything. Worth doing before a release and after any key rotation, because a mismatch does
not fail the release — see below.

**A missing `sparkle:edSignature` is a broken release, not a quirk.** `generate_appcast`
signs an archive when the `SUPublicEDKey` inside the app matches the public half of the
private key it was given. On a mismatch it prints a *warning* and carries on, producing a
feed whose entry has no signature — which installed copies then refuse. Notarization has
nothing to do with it; there is no notarization check in that code path
(`generate_appcast/Appcast.swift`, the `publicEdKey == expectedPublicKey` branch).

An earlier version of this document claimed the omission was expected for notarized dmgs.
That came from comparing a released dmg against an ad-hoc build of newer source, which
varied two things at once: the released build predated Sparkle and carried no
`SUPublicEDKey` at all, and an app without that key is skipped silently by the same code.
Believing the old explanation would mean shrugging off the one symptom a key mismatch
produces.

So after a release, check that the new `appcast.xml` entry has a `sparkle:edSignature`.

### The feed is cached for ten minutes

**No update offered right after publishing is normal, not a fault.** GitHub Pages serves
`appcast.xml` with `cache-control: max-age=600`, so the CDN keeps handing out the previous
feed for up to ten minutes after the workflow pushes a new one. The workflow's own guard
only proves the file it pushed to `gh-pages` changed; it says nothing about what Pages is
currently serving.

That gap produced a false alarm on v0.1.16: `gh-pages` had the new entry within three
seconds of the release, Pages reported `built` three seconds after that, and the served
feed still advertised only the previous version — so **Check for Updates…** correctly
reported nothing. Compare against the branch, not the URL, before concluding anything:

    # what is actually deployed
    gh api "repos/seitzbg/lumeshot/contents/appcast.xml?ref=gh-pages" --jq .content | base64 -d

    # what the world is being served, and how stale it is
    curl -sI https://seitzbg.github.io/lumeshot/appcast.xml | grep -iE 'age|x-cache'

If the branch has the entry and the served copy does not, wait for the window to expire.
Sparkle keeps its own URL cache too, so relaunch the app before retrying.

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
reaches the dev Mac. They get the hardened runtime, so the dev loop exercises the runtime
restrictions the shipped app runs under, with one exception: they sign with
`Resources/Lumeshot-dev.entitlements`, which disables library validation. That check
requires the app and Sparkle.framework to share a Team ID, and `codesign` derives one only
from an Apple-issued certificate, so no local build can satisfy it. Release builds use the
empty `Resources/Lumeshot.entitlements`; `scripts/bundle.sh` picks by `DEVELOPER_ID_SIGNING`.

## Why notarization matters here

Two user-visible things depended on it:

- **Notifications.** A self-signed app is not registered with Notification Center, so
  capture/upload notifications silently never fire.
- **Gatekeeper.** An ad-hoc dmg requires the right-click → Open dance on first launch
  ("can't be opened because Apple cannot check it for malicious software").
