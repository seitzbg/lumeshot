# Lumeshot — Status & Roadmap

_Last updated: 2026-09-06._

Single source of truth for where the project is and what's left. Per-milestone
implementation plans live in `docs/superpowers/plans/`; the original design spec is
`docs/superpowers/specs/2026-07-10-sharex-mac-design.md`; per-milestone manual smoke
checklists are `docs/smoke-*.md`.

## Current state

- **Repo:** `github.com/seitzbg/lumeshot` (public, GPL-3.0). Local working copy: `~/git/lumeshot`.
- **Platform:** macOS 15+, Apple Silicon. Bundle ID `org.sharexmac.app` (immutable).
- **Build/test:** over SSH on the dev Mac via `scripts/remote.sh {build,test,run,bundle,ssh}`
  (rsync mirror at `~/git/lumeshot`; git lives on the dev box). CI: GitHub Actions `macos-15` /
  **Swift 6.0** on push-to-main + PRs — the definitive concurrency gate (the dev Mac's newer
  Swift masks 6.0 errors). **CI is green**; **~290 tests** across the library targets.
- **Modules:** `LumeshotApp` (executable) + `LumeshotCore` / `LumeshotCapture` / `LumeshotUpload` /
  `LumeshotAnnotate` / `LumeshotRecord` libraries + `Clibcurl` (system libcurl shim). SwiftPM only.
- **Signing:** ad-hoc / self-signed dev cert (`sharex-mac-dev`) for the SSH dev loop; releases are
  ad-hoc `.dmg` (no Apple Developer account, no notarization).

## Shipped

The v1 milestone arc (M1→M5b) is complete, plus the Preferences window and the Lumeshot rebrand/rename.

| Milestone | What it delivered |
|---|---|
| **M1** — capture core | Menu-bar app; fullscreen / region / window capture (⌥⇧3/4/5); after-capture pipeline (disk→clipboard→notify, local-first); TCC onboarding; JSON settings; ShareX-style `NameParser`; file logger. |
| **M2a** — share/upload | Capture→upload→copy-URL. `.sxcu` custom-uploader engine (request templating + regex/JSON response-URL extraction) + Imgur (anonymous); secrets → Keychain (`SecretVault`); SQLite history store. |
| **M2b** — S3 + history UI | Hand-rolled SigV4 S3 uploader (AWS/R2/MinIO/B2, path + virtual-host, optional ACL, custom result-URL domain); first SwiftUI — searchable history browser + destination-management window. |
| **M3a** — editor core | Non-destructive annotation editor (base image + ordered shape list); v1 vector tools (rectangle/ellipse/line/arrow/freehand), select/move/resize; undo/redo (50-cap); annotate-before-share gate; CoreGraphics flatten. |
| **M3b** — editor v2 | Completed the v1 toolset: crop (non-destructive), text, highlighter, blur, pixelate, step-number badges; Copy / Save / Upload action split; editor queue for multi-capture. |
| **M4** — screen recording | ScreenCaptureKit mp4 recording (region/window/display) + on-demand "Export as GIF…" (mp4 never discarded); ⌥⇧6 record hotkey; local-first delivery. |
| **M5a** — SFTP/FTP | SFTP (Citadel/SwiftNIO-SSH; password + key auth) and FTP/FTPS (libcurl) uploaders — the project's first external dependencies. Stateless connect-per-upload; secrets Keychain-namespaced. |
| **M5b** — release + polish | Ad-hoc `.dmg` release: `scripts/dmg.sh` + `.github/workflows/release.yml` (push a `v*` tag → build → dmg → GitHub Release). Robustness: atomic Keychain store (no orphan secrets), FTP stall-abort, recorder re-entrancy CI seam. UI polish: elapsed-timer flash fix, GIF-export spinner, inspector keyed on selection. |
| **Preferences window** | Dedicated tabbed Settings (⌘,): General / Capture / Hotkeys / Uploads / Recording; live hotkey recorder (re-registers instantly); Destinations folded into the Uploads tab. |
| **Picsur destination** | Native `.picsur` destination kind for self-hosted [Picsur](https://github.com/CaramelFur/Picsur) instances: `PicsurUploader` synthesizes the same custom-uploader template Picsur's own ShareX generator emits (multipart `image`, `Authorization: Api-Key`), API key → Keychain (`<id>/picsur/apiKey`), Add-Picsur sheet with host / serving format / link-style. |
| **Code-review remediation** | All 18 findings of `docs/code-review-2026-09-06.md` fixed. Highlights: SSH host keys pinned on first use and verified after (was `.acceptAnything()`); explicit editor Save no longer gated by the automatic-save preference; recorder start/stop given a real `.starting`/`.stopping` lifecycle with a session token; recordings streamed to uploaders instead of read into memory on the main actor; Keychain/settings mutations made compensable; `.sxcu` RequestURL protected; SFTP/FTP URLs percent-encoded. |
| **Developer ID signing** | Hardened runtime + `Resources/Lumeshot.entitlements` (deliberately empty) + secure timestamp; release workflow imports a Developer ID cert into a throwaway keychain, asserts the signature's team, signs the dmg, notarizes via `scripts/notarize.sh` (App Store Connect API key) and staples. Signing is opt-in on secret presence, so a secret-less repo still publishes. `scripts/setup-developer-id.sh` walks the one-time Apple-portal setup. |
| **Rebrand + rename** | ShareX-for-Mac → **Lumeshot** (repo, app display name, `.app`/dmg); `SX*` modules → `Lumeshot*`; working dir → `~/git/lumeshot`. Bundle ID + signing cert kept (TCC grant preserved). |

## Pending — needs you (live Mac smoke)

The interactive/hardware paths are build + CI verified but not yet manually smoke-tested on the Mac.
Run these when convenient (each is a checklist):

- [ ] **M4 recording** — `docs/smoke-m4.md` (live mp4 start/stop + GIF export; verify `SCStream.addRecordingOutput` starts and the GIF-export error alert presents).
- [ ] **M5a SFTP/FTP** — `docs/smoke-m5a.md` (real password + key SFTP, plain FTP, FTPS; result URL reachable; secrets purged on remove).
- [ ] **M5b dmg + polish** — `docs/smoke-m5b.md` (dmg mounts + drag-installs; elapsed timer; GIF spinner; inspector-on-select).
- [ ] **Picsur** — `docs/smoke-picsur.md` (real upload to a live instance; direct-image link resolves; deletion URL works; bad key surfaces an error).
- [x] **Signing + notarization — distribution half** verified on macOS 26.6.2 (clean Mac, Firefox download): quarantine set, `spctl` → `accepted / source=Notarized Developer ID`, `stapler validate` passes.
- [ ] **Signing + notarization — runtime half** — still open: the app crashed on launch on macOS 26 (`EXC_BREAKPOINT`, main-actor isolation trap in `AppPipelineEffects`), fixed but unverified there. **Notifications firing remains unproven.**
- [ ] **Preferences** — `docs/smoke-prefs.md` (⌘, opens; tabs persist; **live hotkey recorder** re-registers new combo / old combo goes dead; recorder monitor teardown on window close; Uploads add/remove stays Keychain-safe).

## Backlog / deferred (not blocking; grouped by theme)

**Signing & distribution**
- Auto-update mechanism (none today).
- The release is signed + notarized, but **unverified end to end**: no signed release has been cut yet. `docs/smoke-signing.md` is the gate, and the notification fix in particular is a hypothesis until a notarized build runs on a clean Mac.

**Uploaders**
- Custom-uploader `ErrorMessage` (`{json:data.message}`) is decoded but never applied — failures still surface as the raw `.http(status:body:)`. Affects Picsur and any `.sxcu`.
- SFTP/FTP transports still start from a complete `Data`, so a large recording is resident for those two destinations (bounded now, but not streamed). Streaming needs a chunked transport API on both.
- Minor: FTP paths are libcurl login-relative (`//` for filesystem-absolute — UX gotcha); discarded `clibcurl_set_*` return codes; `SFTPUploader`≈`FTPUploader` structural duplication.
- Imgur **OAuth / authenticated albums** (anonymous-only today).
- Supply-chain: Citadel rides a stale personal fork of `swift-nio-ssh` (`Wellz26/swift-nio-ssh` 0.3.4) — watch for an upstream path.

**Editor**
- Effects don't **stack** (each samples the pristine base — fine for redaction, limiting for layered edits); no `bakeEffects`/geometry caching (recompute per repaint).
- Live text field uses systemFont vs the committed HelveticaNeue (editing-time cosmetic).
- Stroke-push (P3 #3): committing a stroke edit from the toolbar `ColorPicker` has no natural "release" boundary in SwiftUI (`ColorPicker` lacks `onEditingChanged`) — needs debounce or a per-tick-history decision.

**Recording**
- Live SCK paths are build + smoke-only (the test binary can't inherit the app's TCC grant). Smoke must confirm the start path and the GIF-export error alert (see `docs/smoke-m4.md`).
- `ffmpeg` palettegen GIF path skipped (native AVFoundation path shipped).

**Concurrency**
- `@MainActor` types handing bare closures to ObjC completion-handler APIs is a live hazard: the closure inherits main-actor isolation, the framework calls it off-main, and the Swift runtime traps on entry (`EXC_BREAKPOINT`). macOS 15's runtime tolerated it, macOS 26's does not, and the compiler does not flag it because the SDK is `@preconcurrency`-imported. Three instances existed in `AppPipelineEffects`; all now take `@Sendable` closures. Worth grepping for on any new completion-handler call site.

**Testing**
- `CaptureCoordinator` has no tests: `LumeshotApp` is an executable target, so there is no test target for it. The save/upload policy split is covered at the `AfterCapturePipeline` layer only. Extracting the coordinator into a library target would close this.

**Preferences**
- No mutual-exclusion between two simultaneously-"recording" hotkey fields (self-heals on next keystroke/tab-switch/close).

**Naming cleanup (cosmetic; deferred to avoid migrating existing user data)**
- Capture save default is still `~/Pictures/ShareX`; app-support dir is `~/Library/Application Support/ShareX-Mac/` (settings + history). Renaming these to Lumeshot would strand existing files/settings — do it with a migration if ever.

## Candidate next milestones (roadmap)

Rough priority order — revisit when picking up again:

1. **Cut the first signed release** and work `docs/smoke-signing.md` — the pipeline exists but has never run against Apple's notary service.
2. **Editor polish pass** — effect stacking + caching, text-font fidelity, stroke inspector commit.
3. **Uploader auth** — Imgur OAuth (SFTP host-key pinning shipped).
4. **App-data rename + migration** — move `~/Pictures/ShareX` / `ShareX-Mac` app-support to Lumeshot with a one-time migration.
5. **Distribution polish** — auto-update, a real app icon, first-run/onboarding refinement.

## How to resume

1. `cd ~/git/lumeshot` (git lives here on the dev box).
2. Dev loop: `scripts/remote.sh build` / `test` / `run [--capture fullscreen]` / `bundle` / `ssh '<cmd>'` — runs on the Mac via SSH.
3. New work follows the brainstorm → spec (`docs/superpowers/specs/`) → plan (`docs/superpowers/plans/`) → subagent-driven-development flow used for every milestone.
4. CI (Swift 6.0) is the merge gate — always let it verify before merging; the dev Mac's Swift masks strict-concurrency errors CI catches.
5. All secrets go to the **Keychain** only (never `settings.json`); disk write precedes any upload (local-first).
