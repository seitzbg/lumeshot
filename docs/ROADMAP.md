# Lumeshot — Status & Roadmap

_Last updated: 2026-09-07._

Single source of truth for where the project is and what's left. Per-milestone
manual smoke checklists are `docs/smoke-*.md`; `docs/settings-design.md` covers the
Settings layout and `docs/porting-map.md` the ShareX feature mapping.

## Current state

- **Repo:** `github.com/seitzbg/lumeshot` (public, GPL-3.0). Local working copy: `~/git/lumeshot`.
- **Platform:** macOS 15+, Apple Silicon. Bundle ID `org.lumeshot.app`.
- **Build/test:** local Mac development via `swift build` and `swift test`; see
  `docs/local-development.md` for the Command Line Tools test flags. The optional
  SSH workflow remains in `scripts/remote.sh`. CI targets macOS 15 / Swift 6.0.
  v0.1.9 is the current release; the manual signed-build smoke recorded under
  v0.1.7 below has not been repeated for it.
- **Modules:** `LumeshotApp` (executable) + `LumeshotCore` / `LumeshotCapture` / `LumeshotUpload` /
  `LumeshotAnnotate` / `LumeshotRecord` libraries + `Clibcurl` (system libcurl shim). SwiftPM only.
- **Signing:** ad-hoc / self-signed `lumeshot-dev` for local development;
  Developer ID signing and notarization are available in the release pipeline.

## Shipped

The v1 milestone arc (M1→M5b) is complete, plus the Preferences window and the Lumeshot rebrand/rename.

| Milestone | What it delivered |
|---|---|
| **M1** — capture core | Menu-bar app; fullscreen / region / window capture (⌥⇧3/4/5); after-capture pipeline (disk→clipboard→notify, local-first); TCC onboarding; JSON settings; `NameParser`; file logger. |
| **M2a** — share/upload | Capture→upload→copy-URL. `.sxcu` custom-uploader engine (request templating + regex/JSON response-URL extraction) + Imgur (anonymous); secrets → Keychain (`SecretVault`); SQLite history store. |
| **M2b** — S3 + history UI | Hand-rolled SigV4 S3 uploader (AWS/R2/MinIO/B2, path + virtual-host, optional ACL, custom result-URL domain); first SwiftUI — searchable history browser + destination-management window. |
| **M3a** — editor core | Non-destructive annotation editor (base image + ordered shape list); v1 vector tools (rectangle/ellipse/line/arrow/freehand), select/move/resize; undo/redo (50-cap); annotate-before-share gate; CoreGraphics flatten. |
| **M3b** — editor v2 | Completed the v1 toolset: crop (non-destructive), text, highlighter, blur, pixelate, step-number badges; Copy / Save / Upload action split; editor queue for multi-capture. |
| **M4** — screen recording | ScreenCaptureKit mp4 recording (region/window/display) + on-demand "Export as GIF…" (mp4 never discarded); ⌥⇧6 record hotkey; local-first delivery. |
| **M5a** — SFTP/FTP | SFTP (Citadel/SwiftNIO-SSH; password + key auth) and FTP/FTPS (libcurl) uploaders — the project's first external dependencies. Stateless connect-per-upload; secrets Keychain-namespaced. |
| **M5b** — release + polish | Ad-hoc `.dmg` release: `scripts/dmg.sh` + `.github/workflows/release.yml` (push a `v*` tag → build → dmg → GitHub Release). Robustness: atomic Keychain store (no orphan secrets), FTP stall-abort, recorder re-entrancy CI seam. UI polish: elapsed-timer flash fix, GIF-export spinner, inspector keyed on selection. |
| **Clipboard and uploader selection** | Upload off copies the image; successful upload copies its URL unless the clipboard has changed in the meantime. Multiple uploaders can be configured with one active selection. New uploaders preserve an existing selection; removing the active uploader disables automatic upload. |
| **Preferences window** | Dedicated tabbed Settings (⌘,): General / Capture / Hotkeys / Uploads / Recording; live hotkey recorder (re-registers instantly); Destinations folded into the Uploads tab. Settings appears in the Dock/app switcher while open. |
| **Picsur destination** | Native `.picsur` destination kind for self-hosted [Picsur](https://github.com/CaramelFur/Picsur) instances: `PicsurUploader` synthesizes the same custom-uploader template Picsur's own custom-uploader generator emits (multipart `image`, `Authorization: Api-Key`), API key → Keychain (`<id>/picsur/apiKey`), Add-Picsur sheet with host / serving format / link-style. |
| **Code-review remediation** | All 18 findings of the 2026-09-06 review fixed. Highlights: SSH host keys pinned on first use and verified after (was `.acceptAnything()`); explicit editor Save no longer gated by the automatic-save preference; recorder start/stop given a real `.starting`/`.stopping` lifecycle with a session token; recordings streamed to uploaders instead of read into memory on the main actor; Keychain/settings mutations made compensable; `.sxcu` RequestURL protected; SFTP/FTP URLs percent-encoded. |
| **Developer ID signing** | Hardened runtime + `Resources/Lumeshot.entitlements` (deliberately empty) + secure timestamp; release workflow imports a Developer ID cert into a throwaway keychain, asserts the signature's team, signs the dmg, notarizes via `scripts/notarize.sh` (App Store Connect API key) and staples. Signing is opt-in on secret presence, so a secret-less repo still publishes. `scripts/setup-developer-id.sh` walks the one-time Apple-portal setup. |
| **Rebrand + rename** | Lumeshot throughout the app, bundle ID (`org.lumeshot.app`), Keychain service, settings/capture/log paths, signing scripts, and documentation. Clean break: no automatic migration; existing data is left untouched. |

## Unreleased

_Nothing yet._

## v0.1.9 — released

[v0.1.9](https://github.com/seitzbg/lumeshot/releases/tag/v0.1.9) is published. The release
workflow signed it with the Developer ID certificate, verified the team identifier, and
notarized and stapled the dmg. See the [release notes](releases/v0.1.9.md) and
[changelog](../CHANGELOG.md).

Validation: 443 tests pass on macOS 26.6.2 / Swift 6.3.3 as well as on CI, and the effect
stacking was checked by rendering pixelate-then-blur and confirming the blur samples the
mosaic rather than the original pixels. The editor and update-check UI have not been
exercised by hand; the manual Gatekeeper, launch, capture and notification smokes below
were last run against v0.1.7.

- Blur and pixelate effects now **stack**. Each samples the accumulated result rather
  than the pristine base, so layering them composes instead of the last one winning.
  Effects over disjoint regions are unchanged, and export matches the preview.
- The baked effect bitmap is cached on the effect annotations, so dragging a vector
  annotation no longer re-runs Core Image over the whole screenshot every frame.
- Text is edited in the face it commits to. The live field used the system font while
  the renderer committed HelveticaNeue, so text reflowed the moment editing ended.
- The toolbar's stroke colour and width now apply to the selected annotation, not only
  to newly drawn ones. A colour-wheel drag collapses to a single undo entry.
- **Check for Updates…** in the Lumeshot menu compares the running build against the
  latest published release and links to it. It does not download or install anything.
- The Screen Recording permission window is laid out rather than hand-positioned, so its
  explanation no longer clips at larger system text sizes.

## v0.1.8 — released

[v0.1.8](https://github.com/seitzbg/lumeshot/releases/tag/v0.1.8) is published. The release
workflow signed it with the Developer ID certificate, verified the team identifier, and
notarized and stapled the dmg. See the [release notes](releases/v0.1.8.md) and
[changelog](../CHANGELOG.md).

The manual Gatekeeper, launch, capture and notification smokes below were last run against
v0.1.7 and have not been repeated for this build.

- Shortcut recording controls reserve space for the clear button, keeping set
  and unset rows aligned. Verified with mixed, all-set, and all-unset rendered
  layouts; release build passed.
- README screenshots now show v0.1.7 General, Uploads, and uploader configuration,
  plus the corrected shortcut layout included in v0.1.8.

## v0.1.7 — released

[v0.1.7](https://github.com/seitzbg/lumeshot/releases/tag/v0.1.7) is published.
See the [release notes](releases/v0.1.7.md) and [changelog](../CHANGELOG.md).

Upload recovery and History polish are implemented: upload activity in the menu
bar and History, generated-image uploader tests, retry/reupload with stable
destination IDs, filters, larger thumbnails, Space-bar previews, and separate
history/remote deletion actions. Existing history databases migrate in place.
The compact About window includes offline dependency credits and is accessible
from Settings. Uploader selection wraps long names instead of truncating them.

Local validation: 410 automated tests pass. The user confirmed capture permission
onboarding, normal capture/upload, failed-upload retry, and generated-image Picsur
upload/deletion. About and uploader layout were reviewed interactively. History
preview was shown in a screenshot; not every History action was individually
confirmed. Imgur deletion is covered with a fake transport, not a live account.

PR CI, merged-main CI, and the release workflow passed. The published DMG passed
local SHA-256 verification, stapled-ticket validation, and Gatekeeper assessment
as a Notarized Developer ID release. The signed app launched successfully on
macOS 26.6.2 from `dist/test/Lumeshot.app`, displayed version 0.1.7 in Settings,
and reported notification authorization granted. Its launch check reported Screen
Recording access missing; granting that access and confirming a visible capture
notification on this signed build remain manual checks.

## Remaining live Mac checks

Automated checks cover the delivery logic. GUI and hardware checks for the current bundle remain manual. Earlier release observations below predate the clean-break identity.
Run these when convenient (each is a checklist):

- [ ] **M4 recording** — `docs/smoke-m4.md` (live mp4 start/stop + GIF export; verify `SCStream.addRecordingOutput` starts and the GIF-export error alert presents).
- [ ] **M5a SFTP/FTP** — `docs/smoke-m5a.md` (real password + key SFTP, plain FTP, FTPS; result URL reachable; secrets purged on remove).
- [ ] **M5b dmg + polish** — `docs/smoke-m5b.md` (dmg mounts + drag-installs; elapsed timer; GIF spinner; inspector-on-select).
- [x] **Picsur upload and deletion** — generated-image test succeeded against the user's instance, including authenticated deletion. Alternate formats and viewer-page links remain separate optional checks in `docs/smoke-picsur.md`.
- [x] **Signing + notarization — distribution half** verified on macOS 26.6.2 (clean Mac, Firefox download): quarantine set, `spctl` → `accepted / source=Notarized Developer ID`, `stapler validate` passes.
- [x] **Signed release launch** — v0.1.7 launches and opens Settings on macOS 26.6.2; the earlier main-actor launch crash did not recur. Notification authorization is granted.
- [ ] **Signed release capture and notifications** — grant Screen Recording access to the signed v0.1.9 build, capture, and verify the notification appears and its action works. Authorization alone does not prove delivery.
- [ ] **Preferences** — `docs/smoke-prefs.md` (⌘, opens; tabs persist; **live hotkey recorder** re-registers new combo / old combo goes dead; recorder monitor teardown on window close; Uploads add/remove stays Keychain-safe).

## Backlog / deferred (not blocking; grouped by theme)

**Signing & distribution**
- Auto-update: **Check for Updates…** reports whether a newer release exists and links
  to it. Self-installing updates are still absent — Sparkle would need an EdDSA key
  pair, a hosted appcast and update-signing in the release workflow, which is a
  separate decision.
- v0.1.9 is signed and notarized. v0.1.7 was the last build verified locally end to end; complete the remaining capture-permission and visible-notification checks against v0.1.9 in `docs/smoke-signing.md`.

**Uploaders**
- Custom-uploader `ErrorMessage` (`{json:data.message}`) is decoded but never applied. User-facing failures now use generic messages that omit raw server responses; safely supporting uploader-specific messages remains deferred.
- SFTP/FTP transports still start from a complete `Data`, so a large recording is resident for those two destinations (bounded now, but not streamed). Streaming needs a chunked transport API on both.
- Minor: FTP paths are libcurl login-relative (`//` for filesystem-absolute — UX gotcha); discarded `clibcurl_set_*` return codes; `SFTPUploader`≈`FTPUploader` structural duplication.
- Imgur OAuth / authenticated albums: **not planned** (decided 2026-09-07). Anonymous
  upload stays. OAuth would need a registered app whose client secret cannot be kept
  secret in a distributed binary, plus a redirect scheme or a loopback listener inside
  the hardened runtime — a lot of surface for a service we do not want to lean on.
  `.sxcu` custom uploaders and the self-hosted backends cover the same need.
- Supply-chain: Citadel rides a stale personal fork of `swift-nio-ssh` (`Wellz26/swift-nio-ssh` 0.3.4) — watch for an upstream path.

**Recording**
- Live SCK paths are build + smoke-only (the test binary can't inherit the app's TCC grant). Smoke must confirm the start path and the GIF-export error alert (see `docs/smoke-m4.md`).
- `ffmpeg` palettegen GIF path skipped (native AVFoundation path shipped).

**Concurrency**
- `@MainActor` types handing bare closures to ObjC completion-handler APIs is a live hazard: the closure inherits main-actor isolation, the framework calls it off-main, and the Swift runtime traps on entry (`EXC_BREAKPOINT`). macOS 15's runtime tolerated it, macOS 26's does not, and the compiler does not flag it because the SDK is `@preconcurrency`-imported. Three instances existed in `AppPipelineEffects`; all now take `@Sendable` closures. Worth grepping for on any new completion-handler call site.

**Testing**
- `LumeshotAppTests` imports the executable target and covers `CaptureCoordinator` persistence with and without an outcome callback, including editor Save/Upload. GUI overlay interaction and real upload delivery still need manual smoke coverage.

**Preferences**
- No mutual-exclusion between two simultaneously-"recording" hotkey fields (self-heals on next keystroke/tab-switch/close).

## Candidate next milestones (roadmap)

Rough priority order — revisit when picking up again:

1. **Finish signed-release smoke checks** — launch was verified on v0.1.7; re-run against the shipping v0.1.9 build, then confirm capture permissions and visible notifications using `docs/smoke-signing.md`. The checklists were audited against the shipped UI on 2026-09-07; only the hands-on passes remain.
2. **Distribution polish** — auto-update and first-run/onboarding refinement (app icon shipped in v0.1.6).

Dropped: **uploader auth (Imgur OAuth)** — see the backlog note under Uploaders.
Done: **editor polish pass** — effect stacking + caching, text-font fidelity and the
stroke push all landed; see Unreleased.

## How to resume

1. `cd ~/git/lumeshot` (git lives here on the dev box).
2. Local dev loop: `swift build`, `swift test`, and `scripts/bundle.sh`; see `docs/local-development.md` for Command Line Tools test flags. `scripts/remote.sh` remains available for SSH development.
3. New work follows the brainstorm → spec → plan → subagent-driven-development flow used for every milestone. Those planning artifacts stay outside the repo; only code, tests and user-facing docs are committed.
4. CI (Swift 6.0) is the merge gate — always let it verify before merging; the dev Mac's Swift masks strict-concurrency errors CI catches.
5. All secrets go to the **Keychain** only (never `settings.json`); disk write precedes any upload (local-first).
