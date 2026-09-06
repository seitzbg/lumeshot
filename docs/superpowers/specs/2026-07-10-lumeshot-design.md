# Lumeshot — Design Spec

**Date:** 2026-07-10
**Status:** Historical design; naming updated 2026-09-06. See the roadmap for shipped behavior.
**License:** GPL-3.0 (derivative-safe: algorithms and formats are ported from GPL-3.0 upstream)

## 1. What and why

Lumeshot is a Swift-native, menu-bar-resident screenshot, annotation, upload, and recording tool for macOS. It is a personal daily-driver first, developed in the open.

**Decision record (from brainstorming, 2026-07-10):**

| Decision | Choice | Why |
|---|---|---|
| Purpose | Personal daily-driver, open source | Scope ruthlessly to owner's needs; community welcome |
| Approach | Swift-native rewrite (over .NET/Avalonia reuse or hybrid) | The hard subsystems (capture, hotkeys, recording, TCC) are native work in any stack; Swift makes them easier and yields a permanently better resident app (~15MB-class RSS vs 150–250MB CLR; native chrome). Agent-driven development against a fully-specified reference flips the usual rewrite-cost calculus |
| Platform | macOS 15+ (Sequoia), Apple Silicon (arm64) only | `SCRecordingOutput` makes recording nearly free; covers current + previous major release as of mid-2026 |
| v1 features | Capture + annotate, upload + share URL, screen recording | OCR and power tools deferred |
| Uploaders | .sxcu custom-uploader engine, S3-compatible, SFTP/FTP, Imgur-style | Owner's actual destinations; .sxcu preserves upstream config compatibility |
| Name / license | `lumeshot` / GPL-3.0 | Lumeshot branding; GPL-3.0 for the project |
| Dev loop | Orchestrate from Linux (DGX Spark), build/test on an Apple Silicon Mac over SSH | Git is source of truth; `scripts/remote.sh` drives remote build/test |

**Platform approach:** capture, hotkeys, menu-bar integration, and clipboard use native macOS APIs. The settings and `.sxcu` formats provide portable configuration.

## 2. Architecture

**App shape.** Single `.app` bundle, `LSUIElement` (menu-bar only, no Dock icon while idle). Swift 6 with strict concurrency. AppKit for the shell — `NSStatusItem`, capture-overlay `NSWindow`s, editor canvas `NSView` — and SwiftUI for chrome: settings, history browser, editor inspector. No runtime dependencies outside the bundle.

**Build system.** SwiftPM-first; no checked-in Xcode project. `swift build` produces the executable; `scripts/bundle.sh` assembles the `.app` (Info.plist from template, icns, entitlements, codesign — ad-hoc by default). Everything is CLI-drivable over SSH; Xcode users open `Package.swift`. Stable bundle and signing identities keep TCC grants across rebuilds. The current clean-break identity requires fresh grants.

**Identity.** App display name: **Lumeshot**. Bundle ID: `org.lumeshot.app`. The clean-break rebrand does not migrate settings or credentials from earlier identities.

**Modules** (SwiftPM targets; each is independently buildable and testable):

| Target | Purpose | upstream counterpart (the spec) |
|---|---|---|
| `SXApp` (exe) | Menu bar, global hotkeys, TCC onboarding, wiring | upstream-main shell / TrayIcon |
| `SXCore` | Workflow pipeline, settings store, naming templates, history (SQLite), single-instance | TaskManager/WorkerTask, NameParser, HelpersLib portable subset |
| `SXCapture` | ScreenCaptureKit stills, region overlay, window picker | ScreenCaptureLib (capture) |
| `SXAnnotate` | Annotation document model, CG rendering, editor UI | ImageEditor |
| `SXUpload` | Uploader protocol, .sxcu engine, S3, SFTP/FTP, Imgur | UploadersLib |
| `SXRecord` | SCRecordingOutput → mp4, GIF export | ScreenCaptureLib (recording) + MediaLib |

**Data flow** (upstream's mental model, kept): trigger (hotkey / menu action) → capture → per-workflow after-capture chain (`annotate? → save to disk → copy to clipboard → upload`) → after-upload chain (copy URL, notification, history row). **Local-first invariant:** every capture is written to disk before any upload attempt; a failed upload never loses the artifact.

**Global hotkeys** use Carbon `RegisterEventHotKey` — reliable, no Accessibility permission. Defaults avoid colliding with system ⌘⇧3/4/5; fully user-configurable.

**Implementation map.** `docs/porting-map.md` lists the Swift types and their responsibilities.

## 3. Subsystems

### 3.1 Capture (`SXCapture`)
- Stills via `SCScreenshotManager`; captured at native Retina scale; converted to sRGB on export.
- **Fullscreen**: per-display or all displays.
- **Window**: picker overlay from `SCShareableContent` with hover-highlight.
- **Region** (flagship UX): borderless overlay `NSWindow` per display spanning all `NSScreen`s; crosshair, magnifier loupe, live dimensions readout; drag to select, Enter/release captures, Escape cancels.
- First-run onboarding flow walks the user through the Screen Recording TCC grant (required by ScreenCaptureKit; the app detects denial and deep-links to System Settings).

### 3.2 Editor (`SXAnnotate`)
- Non-destructive document: base image + ordered annotation list; export flattens via CoreGraphics.
- **v1 toolset:** select/move, crop, rectangle, ellipse, line, arrow, freehand, text, highlighter, blur, pixelate, step-number badges, unlimited undo/redo.
- Canvas: AppKit `NSView` + CoreGraphics (precise hit-testing, Retina rendering); SwiftUI inspector for stroke/fill/font. upstream's shape geometry/hit-test math ports nearly 1:1.
- Editor actions (Copy / Save / Upload) feed back into the pipeline.
- Everything beyond this toolset (effects, smart eraser, cut-out, image effects) is post-v1.

### 3.3 Upload (`SXUpload`)
- Core abstraction: `Uploader` protocol — `upload(data, filename, mime) async throws → UploadResult{url, thumbnailURL, deletionURL}`.
- **.sxcu engine** (compatibility centerpiece): parses upstream custom-uploader JSON — request method/URL, headers, parameters, body types (MultipartFormData, FormURLEncoded, JSON, Binary), `FileFormName`, and response-URL syntax `{json:path}`, `{regex:n|group}`, `{response}`, `{header:name}`, `{input}`, `{prompt}`. Existing .sxcu files import via double-click / drag onto the menu-bar icon and work unchanged. Validated against a corpus of real .sxcu files.
- **S3-compatible**: hand-rolled SigV4 (no AWS SDK), custom endpoints (R2/MinIO/B2), path- and virtual-host-style addressing, optional ACL header, custom result-URL template.
- **SFTP**: Citadel (SwiftNIO-SSH) with password/key auth and remote-path→URL mapping. **FTP**: system libcurl fallback provider.
- **Imgur-style**: anonymous + OAuth2.
- Credentials live in the Keychain; secrets embedded in imported .sxcu files are migrated to Keychain on import (original file untouched).
- **History**: SQLite; SwiftUI window with search, thumbnail grid, copy-URL, open, reveal, delete (including remote deletion-URL invocation).
- Results → `NSPasteboard` + `UNUserNotificationCenter` notification (click opens URL).

### 3.4 Recording (`SXRecord`)
- `SCRecordingOutput` (macOS 15 API — ScreenCaptureKit writes the file) → .mp4, H.264/HEVC via VideoToolbox; reuses the same region/window/display selector as stills.
- Menu-bar icon switches to recording state with elapsed time; stop via hotkey or menu click.
- Optional system audio (native to SCK). Microphone capture deferred (avoids the mic TCC prompt in v1).
- **GIF**: post-convert the recorded mp4 natively (`AVAssetImageGenerator` frames → `CGImageDestination` animated GIF) with fps/scale options; if `ffmpeg` is found on PATH, use palettegen for higher quality — optional, never required.
- Recordings run the same after-capture pipeline (save → upload → URL).

### 3.5 Settings & upstream compatibility
- Versioned Codable JSON under `~/Library/Application Support/Lumeshot/` (file-based like upstream: easy backup/sync; explicit schema-version field with forward migrations). UserDefaults only for window frames and similar cosmetics.
- Naming templates implement the common upstream `NameParser` tokens: `%y %mo %d %h %mi %s %ms %rn %ra %width %height %pn %i %n` and counter/random forms.
- **Explicit non-goal:** importing Windows `ApplicationConfig`/`HotkeysConfig` wholesale — the input models differ too much. Only .sxcu import is promised.

## 4. Repo, dev loop, CI

```
lumeshot/
├── Package.swift              # SXApp exe + 5 library targets + test targets
├── Sources/{SXApp,SXCore,SXCapture,SXAnnotate,SXUpload,SXRecord}/
├── Tests/                     # mirrors library targets
├── Resources/                 # Info.plist template, entitlements, icns, assets
├── scripts/                   # bundle.sh, sign.sh, notarize.sh, remote.sh
├── docs/porting-map.md        # Swift type → upstream class map
├── docs/superpowers/specs/    # this document
├── LICENSE                    # GPL-3.0
└── .github/workflows/ci.yml
```

- Independent repository at `github.com/seitzbg/lumeshot`.
- **Dev loop:** git is source of truth; the Mac (`seitz@macmini1.fiber.house`) holds a clone at `~/git/lumeshot`. `scripts/remote.sh` drives the tight loop from the Linux box: sync → `ssh seitz@macmini1.fiber.house 'cd ~/git/lumeshot && swift build && swift test && scripts/bundle.sh'` → stream results. Interactive verification (TCC prompts, overlay feel, hotkeys) happens on the Mac against a per-milestone smoke checklist.
- **CI:** GitHub Actions `macos-15` (arm64): build + unit tests on push; release workflow assembles .app and .dmg (`hdiutil`). Signing is ad-hoc by default; Developer ID signing + `notarytool` + `stapler` light up via repo secrets if/when an Apple Developer account exists. Sparkle auto-update is post-v1.

## 5. Error handling

- Typed error enums per module; user-visible failures surface as notifications, with a "recent errors" panel in settings.
- **Never lose a capture:** disk write precedes upload; failed uploads keep file + history row with a retry action.
- **Fail loud:** no silent catch-and-drop (the audit found upstream silently swallowing `PlatformNotSupportedException` — e.g. recycle-bin deletes that no-op; this project treats unexpected errors as bugs and surfaces them).
- Upload retries with exponential backoff; timeout and cancellation propagate through Swift structured concurrency.

## 6. Testing

- **Unit (CI-run):** .sxcu parser against a real-file corpus; SigV4 against AWS test vectors; naming templates; annotation geometry/hit-testing; history store; settings migration round-trips.
- **Snapshot (CI-run):** render annotation documents → PNG, pixel-diff against goldens.
- **Manual smoke (per milestone, on the Mac):** scripted checklist for capture modes, TCC flows, hotkeys, recording start/stop, and end-to-end hotkey→capture→annotate→upload→URL-on-clipboard.
- CI cannot grant TCC, so capture/recording integration is deliberately out of CI scope.

## 7. v1 non-goals

OCR, scrolling capture, watch folders, image-effects pipeline, color picker/ruler, indexer, hotkey-config import from Windows, Intel Macs, App Store distribution, Sparkle updater, full upstream editor parity, microphone audio in recordings.

## 8. Milestones

Each milestone ends with the app more daily-drivable than before:

1. **M1 — Capture core:** scaffold, menu bar, hotkeys, TCC onboarding, fullscreen/region/window stills → clipboard/disk + notifications. *(Replaces ⌘⇧4.)*
2. **M2 — Share:** workflow pipeline, history, .sxcu engine + Imgur + S3 → copy-URL flow. *(Daily-drivable.)*
3. **M3 — Editor v1:** annotate-before-share.
4. **M4 — Recording:** mp4 + GIF.
5. **M5 — SFTP/FTP, polish, CI release + dmg.**

## 9. Risks

| Risk | Mitigation |
|---|---|
| Editor scope creep toward upstream's 281-file editor | v1 toolset is enumerated in §3.2; anything else needs a spec change |
| .sxcu syntax long tail (functions like `{base64:...}`, `{random:...}`) | Corpus-driven: implement what real configs use; unknown syntax → clear import error, not silent misparse |
| SwiftPM-built .app + TCC quirks (bundle identity, ad-hoc signing) | Stable bundle ID + consistent signing identity from M1; verified in the M1 smoke checklist |
| Citadel/SwiftNIO-SSH gaps for exotic SFTP servers | SFTP lands in M5 after core value is proven; libcurl fallback exists |
| Blind-driving native UI over SSH | Per-milestone human smoke checklist; screenshots/screen recordings from the Mac feed back into sessions |
