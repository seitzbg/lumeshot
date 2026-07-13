# M5b — Release (dmg) + Robustness & UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an ad-hoc-signed `.dmg` release pipeline for ShareX for Mac (a packaging script plus a tag-triggered GitHub Actions release job) and land a curated set of small robustness and UI-polish fixes identified from live-source review — three hardening fixes (B1–B3) and three visual/UX fixes (P1–P3) — without expanding scope beyond the ratified M5b architecture contract. Imgur OAuth stays deferred.

**Architecture:** R1/R2 build directly on the existing `scripts/bundle.sh` (which already produces an ad-hoc-signed `dist/ShareX for Mac.app` — the dev signing keychain from `scripts/setup-signing.sh` doesn't exist on CI runners, so `bundle.sh` falls back to `codesign --sign -` automatically): `scripts/dmg.sh` (new) stages that `.app` plus an `Applications` symlink and calls `hdiutil create` to emit a compressed `.dmg`; `.github/workflows/release.yml` (new) is a second workflow, triggered only on `v*` tags, that runs `swift build -c release` → `bundle.sh` → `dmg.sh` → `gh release create` on a `macos-15` runner, mirroring `ci.yml`'s runner/checkout. B1–B3 harden three independent seams without touching any call site: `S3Credentials.store`/`SFTPCredentials.store` become all-or-nothing (purge-then-rethrow on partial Keychain-write failure), `CurlFTPTransport` gets a low-speed abort so a stalled mid-transfer can't hang `curl_easy_perform` forever, and `ScreenRecorder` gets a TCC-free test seam (`_assertIdleForTesting`) that lets CI exercise the `alreadyRecording` re-entrancy guard without a live `SCContentFilter`. P1–P3 close visual gaps in state that already exists: `AppDelegate` gains a stored `recordingStartedAt` so a mid-recording `rebuildMenu()` computes the elapsed label instead of re-hardcoding `"● 0:00"`; `HistoryView`'s `GifExportSheet` adds an indeterminate `ProgressView` to its already-correct `isExporting` gate; `EditorModel`/`EditorView` sync the toolbar inspector to the selected annotation's real values and key the inspector switch on the selection's shape kind (not just the active tool), using the selection machinery (`selectedID`, `selectedAnnotation`, `applyInspectorToSelection()`) that already exists from M3b.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (tools 6.0), macOS 15+, swift-testing (`@Test`/`#expect`/`@Suite`, zero XCTest). GitHub Actions `macos-15` runners for both `ci.yml` and the new `release.yml`. `hdiutil`/`codesign --sign -` for ad-hoc dmg packaging — no Apple Developer account, no notarization.

## Global Constraints

*Every task's requirements implicitly include this section. Values are copied verbatim from the ratified M5b architecture contract.*

- Swift 6 strict concurrency; `swift-tools-version: 6.0`; `platforms: [.macOS(.v15)]`. NO downgrade. CI (macos-15/Xcode16.4/Swift6.0) is the gate.
- Secrets Keychain-only (B1 must strengthen, not regress, this). Local-first/fail-loud. No `nonisolated(unsafe)`/`@unchecked` in production. No AI-attribution boilerplate anywhere (commits, workflow yaml, docs, comments).
- Release workflow is ad-hoc-signed (`codesign --sign -`), no notarization. The dev signing keychain doesn't exist on CI runners, so `bundle.sh` lands on the ad-hoc fallback automatically.
- **Current-state facts (ground truth, verified live):** `scripts/bundle.sh` outputs `dist/ShareX for Mac.app`; takes a `VERSION` env (default `0.1.0`) sed-substituted into `Resources/Info.plist`'s `@VERSION@`; codesigns with a keychain-derived identity or `-` (ad-hoc) as fallback; assumes `swift build -c release` already ran (it does not build); no icns, no entitlements; `dist/` is gitignored. `Resources/Info.plist` has `CFBundleIdentifier org.sharexmac.app`, `CFBundleExecutable SXApp`, `CFBundleName/DisplayName "ShareX for Mac"`. `.github/workflows/ci.yml` is 21 lines: `push branches:[main]` + `pull_request`, `runs-on: macos-15`, `checkout@v4` → `swift build` → `swift test`, no explicit Swift setup. `scripts/remote.sh run` already does `swift build -c release && scripts/bundle.sh` — so `dmg.sh` must run strictly after `bundle.sh`, consuming its output.
- **Test framework:** swift-testing (`import Testing`, `@Test`, `#expect`, `@Suite`). Zero XCTest.
- **No `SXAppTests` target** (established M4/M5a precedent): `SXApp` is an `.executableTarget` with top-level code (`Sources/SXApp/main.swift`), which a test target cannot `@testable import`. `AppDelegate`/`HistoryView`/`EditorView` changes (P1, P2, P3's View half) are therefore build-only + Mac-smoke; only the library-target halves that are genuinely unit-testable (`S3Credentials`/`SFTPCredentials` in `SXCoreTests`, `ScreenRecorder` in `SXRecordTests`, `EditorModel` in `SXAnnotateTests`) get CI tests.
- **Build/test loop:** `scripts/remote.sh build` and `scripts/remote.sh test` rsync to the Mac and run over SSH; `scripts/remote.sh run` rebuilds+bundles+launches for interactive smoke; `scripts/remote.sh ssh '<cmd>'` runs an arbitrary command in the synced tree (used by R1's dmg + mount verification). `build`/`test` do NOT re-bundle the `.app` or build a dmg.
- **B1 secrets invariant:** `DestinationsView`'s `addS3`/`addSFTP` call sites (`Sources/SXApp/DestinationsView.swift`) stay UNCHANGED — they already `catch { AppLog.log(...); return }` around the `store(...)` call and separately roll back with `try? *Credentials.purge(...)` if the subsequent `persist(...)` fails. B1 only changes what happens *inside* `S3Credentials.store`/`SFTPCredentials.store` themselves; `FTPCredentials.store` writes exactly one key so it needs no change.

## File Structure

**Modified:** `Sources/SXCore/Upload/S3Credentials.swift`, `Sources/SXCore/Upload/SFTPCredentials.swift`, `Sources/SXUpload/CurlFTPTransport.swift`, `Sources/SXRecord/ScreenRecorder.swift`, `Sources/SXApp/AppDelegate.swift`, `Sources/SXApp/HistoryView.swift`, `Sources/SXAnnotate/Editor/EditorModel.swift`, `Sources/SXApp/EditorView.swift`.
**New:** `scripts/dmg.sh` (executable), `.github/workflows/release.yml`, `docs/smoke-m5b.md`, `docs/RELEASING.md`.
**Modified tests:** `Tests/SXCoreTests/S3CredentialsTests.swift`, `Tests/SXCoreTests/SFTPCredentialsTests.swift`, `Tests/SXRecordTests/ScreenRecorderTests.swift`, `Tests/SXAnnotateTests/EditorModelTests.swift`.

---
### Task 1: B1 — atomic Keychain store (S3Credentials + SFTPCredentials) + orphan tests

**Files:**
- Modify: `Sources/SXCore/Upload/S3Credentials.swift`
- Modify: `Sources/SXCore/Upload/SFTPCredentials.swift`
- Test: Modify `Tests/SXCoreTests/S3CredentialsTests.swift`
- Test: Modify `Tests/SXCoreTests/SFTPCredentialsTests.swift`

**Interfaces:**
- No signature changes. `S3Credentials.store(accessKeyID:secretAccessKey:id:into:)` and `SFTPCredentials.store(password:privateKeyPEM:passphrase:id:into:)` keep their exact current signatures — only their bodies become all-or-nothing (purge every write for `id` on any internal `setSecret` failure, then rethrow the original error).
- `FTPCredentials.store` is NOT touched (single-key write; nothing to roll back).
- `DestinationsView`'s `addS3`/`addSFTP` call sites (`Sources/SXApp/DestinationsView.swift`) are UNCHANGED — their existing `catch { return }` and post-persist `try? purge(...)` rollback keep working exactly as before; B1 just means the Keychain itself never holds a half-written credential in the first place.

- [ ] **Step 1: Write the failing orphan-purge tests**

Append to `Tests/SXCoreTests/S3CredentialsTests.swift` (inside `@Suite struct S3CredentialsTests`, alongside the existing `DictCredentialStore`):

```swift
private final class FailingAfterNStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    private var callCount = 0
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws {
        callCount += 1
        if callCount == failAt { throw UploadError.transport("simulated failure") }
        store[account] = value
    }
    func deleteSecret(for account: String) throws { store[account] = nil }
}
```

```swift
    @Test func storeRollsBackTheFirstWriteWhenTheSecondFails() throws {
        let creds = FailingAfterNStore(failAt: 2)   // fails writing secretAccessKey (the 2nd setSecret)
        #expect(throws: (any Error).self) {
            try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        }
        // The first write (accessKeyID) must be purged too — no orphan left behind.
        #expect(creds.store["d1/s3/accessKeyID"] == nil)
        #expect(creds.store["d1/s3/secretAccessKey"] == nil)
    }
```

Append to `Tests/SXCoreTests/SFTPCredentialsTests.swift` (same `FailingAfterNStore` double, duplicated per-file — mirrors the existing per-file `DictCredentialStore` precedent):

```swift
private final class FailingAfterNStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    private var callCount = 0
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws {
        callCount += 1
        if callCount == failAt { throw UploadError.transport("simulated failure") }
        store[account] = value
    }
    func deleteSecret(for account: String) throws { store[account] = nil }
}
```

```swift
    @Test func storeRollsBackAllWritesWhenALaterOneFails() throws {
        let creds = FailingAfterNStore(failAt: 2)   // fails writing privateKeyPEM (the 2nd setSecret)
        #expect(throws: (any Error).self) {
            try SFTPCredentials.store(password: "pw", privateKeyPEM: "key", passphrase: "phrase",
                                      id: "d1", into: creds)
        }
        // The first write (password) must be purged too — no orphan left behind.
        #expect(creds.store["d1/sftp/password"] == nil)
        #expect(creds.store["d1/sftp/privateKey"] == nil)
        #expect(creds.store["d1/sftp/passphrase"] == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `store` already rethrows today (so the `#expect(throws:)` half passes), but neither method purges on partial failure yet, so the orphaned first write (`d1/s3/accessKeyID` / `d1/sftp/password`) is still present and the `== nil` assertions fail.

- [ ] **Step 3: Make both `store` methods atomic**

Replace `Sources/SXCore/Upload/S3Credentials.swift`'s `store` in full:

```swift
    public static func store(accessKeyID: String, secretAccessKey: String,
                             id: String, into credentials: CredentialStore) throws {
        do {
            try credentials.setSecret(accessKeyID, for: account(id, "accessKeyID"))
            try credentials.setSecret(secretAccessKey, for: account(id, "secretAccessKey"))
        } catch {
            try? purge(id: id, from: credentials)   // purge is idempotent (deleteSecret ignores not-found)
            throw error
        }
    }
```

Replace `Sources/SXCore/Upload/SFTPCredentials.swift`'s `store` in full:

```swift
    /// Stores only the non-nil fields — a key-only destination never writes a
    /// "password" account, and vice versa. All-or-nothing: any internal write
    /// failure purges everything written for `id` so far, so a partial Keychain
    /// write never lingers as an orphan.
    public static func store(password: String?, privateKeyPEM: String?, passphrase: String?,
                             id: String, into c: CredentialStore) throws {
        do {
            if let password { try c.setSecret(password, for: account(id, "password")) }
            if let privateKeyPEM { try c.setSecret(privateKeyPEM, for: account(id, "privateKey")) }
            if let passphrase { try c.setSecret(passphrase, for: account(id, "passphrase")) }
        } catch {
            try? purge(id: id, from: c)   // purge is idempotent (deleteSecret ignores not-found)
            throw error
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — the two new orphan-purge tests, plus every pre-existing `S3CredentialsTests`/`SFTPCredentialsTests` case (round-trip, partial-secret, missing-credential, purge-on-never-stored) unaffected, since the happy path through the `do` block is identical to before.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/S3Credentials.swift Sources/SXCore/Upload/SFTPCredentials.swift Tests/SXCoreTests/S3CredentialsTests.swift Tests/SXCoreTests/SFTPCredentialsTests.swift
git commit -m "Make S3Credentials.store and SFTPCredentials.store atomic (purge orphans on failure)"
```

---
### Task 2: B2 — FTP mid-transfer stall abort (CurlFTPTransport)

**Files:**
- Modify: `Sources/SXUpload/CurlFTPTransport.swift`
- Test: none (real libcurl network transport is Mac-smoke-only; no live FTP server in CI — same posture as the rest of this file's `// VERIFY on Mac` code). Build-only.

**Interfaces:** No signature change — two additional `curl_easy_setopt` calls inside the existing `upload(_:to:username:password:useTLS:)` closure, alongside the existing `CURLOPT_CONNECTTIMEOUT` line.

- [ ] **Step 1: Add the low-speed abort**

In `Sources/SXUpload/CurlFTPTransport.swift`, change:

```swift
                    // An unreachable/stalled server would otherwise block curl_easy_perform
                    // forever, leaving the continuation unresumed — fail loud instead.
                    _ = clibcurl_set_long(curl, CURLOPT_CONNECTTIMEOUT, 30)
                    _ = clibcurl_set_infilesize(curl, curl_off_t(data.count))
```

to:

```swift
                    // An unreachable/stalled server would otherwise block curl_easy_perform
                    // forever, leaving the continuation unresumed — fail loud instead.
                    _ = clibcurl_set_long(curl, CURLOPT_CONNECTTIMEOUT, 30)
                    // A stalled mid-transfer (server stops reading, dead connection after connect) would otherwise
                    // hang curl_easy_perform forever — abort if throughput < 1 byte/sec for 60 consecutive seconds.
                    _ = clibcurl_set_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
                    _ = clibcurl_set_long(curl, CURLOPT_LOW_SPEED_TIME, 60)
                    _ = clibcurl_set_infilesize(curl, curl_off_t(data.count))
```

`clibcurl_set_long` already covers these `long`-typed options — no `Clibcurl` shim change needed.

- [ ] **Step 2: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite, unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/SXUpload/CurlFTPTransport.swift
git commit -m "Abort stalled FTP transfers via CURLOPT_LOW_SPEED_LIMIT/TIME"
```

---
### Task 3: B3 — ScreenRecorder `_assertIdleForTesting` CI test seam

**Files:**
- Modify: `Sources/SXRecord/ScreenRecorder.swift`
- Test: Modify `Tests/SXRecordTests/ScreenRecorderTests.swift` (add to the CI-safe `ScreenRecorderStateMachineTests` suite, NOT the TCC-gated `ScreenRecorderLiveTests` suite)

**Interfaces:**
- Produces: `func _assertIdleForTesting() throws` on `ScreenRecorder` (package-internal, `@MainActor` via the enclosing class) — mirrors `start()`'s re-entrancy guard (`guard state == .idle else { throw RecordingError.alreadyRecording }`) without constructing an `SCContentFilter`, so CI (which has no Screen Recording TCC grant) can exercise the guard.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SXRecordTests/ScreenRecorderTests.swift`, inside `@MainActor @Suite struct ScreenRecorderStateMachineTests`:

```swift
    @Test func secondStartWhileRecordingThrowsAlreadyRecording() {
        let r = ScreenRecorder()
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in }
        #expect(throws: RecordingError.alreadyRecording) { try r._assertIdleForTesting() }
    }
```

`RecordingError` is already `Equatable` (`Sources/SXRecord/RecordingError.swift`), so `#expect(throws:)` can compare the exact case.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `_assertIdleForTesting` does not exist yet, so `ScreenRecorderTests.swift` fails to compile.

- [ ] **Step 3: Add the test seam**

In `Sources/SXRecord/ScreenRecorder.swift`, add immediately after `_beginForTesting(outputURL:onFinish:)`:

```swift
    /// Test-only: mirrors start()'s re-entrancy guard without constructing an SCContentFilter
    /// (which needs the Screen Recording TCC grant). Lets CI verify the guard fires.
    func _assertIdleForTesting() throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — the new `secondStartWhileRecordingThrowsAlreadyRecording` test (runs unconditionally, no TCC gate) plus every pre-existing `ScreenRecorderStateMachineTests`/`ScreenRecorderLiveTests` case, unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXRecord/ScreenRecorder.swift Tests/SXRecordTests/ScreenRecorderTests.swift
git commit -m "Add ScreenRecorder._assertIdleForTesting CI seam for the re-entrancy guard"
```

---
### Task 4: P1 — elapsed-timer flash fix (AppDelegate)

**Files:**
- Modify: `Sources/SXApp/AppDelegate.swift`
- Test: none (AppKit `NSMenu`/`Timer` UI — no `SXAppTests` target). Build-only + Mac Smoke Checklist.

**Interfaces:** No public signature changes — `updateRecordingUI(_:)`, `buildRecordingItems(into:)`, and `tickElapsed(since:)` are all private methods on `AppDelegate`. Adds a stored `private var recordingStartedAt: Date?` and a private helper `elapsedLabel(since:)`.

**Bug being fixed:** `buildRecordingItems` hardcodes the elapsed menu item's title to `"● 0:00"` every time it runs. `updateRecordingUI` calls `rebuildMenu()` unconditionally on every state change, and other handlers (e.g. `toggleSystemAudio`) also call `rebuildMenu()` mid-recording — each rebuild flashes the elapsed label back to `0:00` for up to 1s until the next `tickElapsed` tick corrects it.

- [ ] **Step 1: Add the stored start time and the shared label helper**

In `Sources/SXApp/AppDelegate.swift`, change:

```swift
    private var elapsedMenuItem: NSMenuItem?
    private var elapsedTimer: Timer?
```

to:

```swift
    private var elapsedMenuItem: NSMenuItem?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
```

Add, near `tickElapsed` (private helper, no `@objc`):

```swift
    private func elapsedLabel(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", s/60, s%60)
    }
```

- [ ] **Step 2: Set `recordingStartedAt` before `rebuildMenu()` and use it for the timer**

Change `updateRecordingUI(_:)` from:

```swift
    private func updateRecordingUI(_ recording: Bool) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        rebuildMenu()
        guard recording else {
            statusItem?.setRecording(false)
            return
        }
        statusItem?.setRecording(true)
        let start = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed(since: start) }
        }
    }
```

to:

```swift
    private func updateRecordingUI(_ recording: Bool) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = recording ? Date() : nil
        rebuildMenu()
        guard recording, let start = recordingStartedAt else {
            statusItem?.setRecording(false)
            return
        }
        statusItem?.setRecording(true)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed(since: start) }
        }
    }
```

- [ ] **Step 3: Compute the elapsed item's title from `recordingStartedAt` instead of hardcoding it**

In `buildRecordingItems(into:)`, change:

```swift
            let elapsed = NSMenuItem(title: "● 0:00", action: nil, keyEquivalent: "")
```

to:

```swift
            let elapsed = NSMenuItem(title: "● \(recordingStartedAt.map(elapsedLabel(since:)) ?? "0:00")",
                                     action: nil, keyEquivalent: "")
```

- [ ] **Step 4: Route `tickElapsed` through the shared helper**

Change `tickElapsed(since:)` from:

```swift
    private func tickElapsed(since start: Date) {
        let seconds = Int(Date().timeIntervalSince(start))
        let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
        elapsedMenuItem?.title = "● \(label)"
        statusItem?.setTitle(label)
    }
```

to:

```swift
    private func tickElapsed(since start: Date) {
        let label = elapsedLabel(since: start)
        elapsedMenuItem?.title = "● \(label)"
        statusItem?.setTitle(label)
    }
```

- [ ] **Step 5: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 6: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite, unchanged (AppDelegate has no test target).

- [ ] **Step 7: Commit**

```bash
git add Sources/SXApp/AppDelegate.swift
git commit -m "Fix elapsed-timer flash to 0:00 on mid-recording menu rebuild"
```

---
### Task 5: P2 — GIF-export progress indicator (HistoryView)

**Files:**
- Modify: `Sources/SXApp/HistoryView.swift`
- Test: none (SwiftUI view — no `SXAppTests` target). Build-only + Mac Smoke Checklist.

**Interfaces:** No API change. `GifExportSheet`'s existing `@State private var isExporting` already disables both buttons for the duration of the export (`Sources/SXApp/HistoryView.swift:183,209,219`) — the gap is purely visual: two disabled buttons with no spinner reads as a frozen sheet. No `GifConverter` API change (an indeterminate spinner satisfies "in progress"; a determinate bar would need an `onProgress` callback — out of scope, DEFER).

- [ ] **Step 1: Add the spinner + label to the button row**

In `Sources/SXApp/HistoryView.swift`, change `GifExportSheet.body`'s button `HStack` from:

```swift
            HStack {
                Spacer()
                Button("Cancel") { model.exportingEntry = nil }
                    .disabled(isExporting)
                Button("Export") {
                    isExporting = true
                    // Non-numeric, zero, or negative input means "no max
                    // width" — never pass a <= 0 width down to the GIF
                    // converter's `maximumSize`.
                    let width = Int(maxWidthText).flatMap { $0 > 0 ? $0 : nil }
                    Task { await model.exportGif(for: entry, fps: Int(fps), maxWidth: width) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
```

to:

```swift
            HStack {
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").foregroundStyle(.secondary)
                }
                Button("Cancel") { model.exportingEntry = nil }
                    .disabled(isExporting)
                Button("Export") {
                    isExporting = true
                    // Non-numeric, zero, or negative input means "no max
                    // width" — never pass a <= 0 width down to the GIF
                    // converter's `maximumSize`.
                    let width = Int(maxWidthText).flatMap { $0 > 0 ? $0 : nil }
                    Task { await model.exportGif(for: entry, fps: Int(fps), maxWidth: width) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
```

- [ ] **Step 2: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite, unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/SXApp/HistoryView.swift
git commit -m "Add an exporting spinner to the GIF-export sheet"
```

---
### Task 6: P3 — inspector keyed on selection (EditorModel + EditorView)

**Files:**
- Modify: `Sources/SXAnnotate/Editor/EditorModel.swift`
- Modify: `Sources/SXApp/EditorView.swift`
- Test: Modify `Tests/SXAnnotateTests/EditorModelTests.swift`

**Interfaces:**
- `EditorModel.beginSelectGesture(at:)` (private) gains a call to a new private helper `syncInspector(to:)` when a hit is found, syncing the already-`@Published` inspector vars (`strokeColor`, `strokeWidth`, `blurRadius`, `pixelScale`, `textFontSize`) from the selected `Annotation`'s `style`/`shape`. No public API change.
- `EditorView.inspector` (private `@ViewBuilder`) switches on a new private computed `effectiveInspectorTool: EditorTool` instead of `model.activeTool` directly — the selected annotation's own kind when `.select` is active and something matching an inspector-backed shape (`.text`/`.blur`/`.pixelate`) is selected, else `model.activeTool` unchanged. No public API change; `applyInspectorToSelection()` (already existing, unchanged) is what commits an inspector edit back onto the selected annotation.
- **Scope decision — item #3 (stroke push) is DEFERRED, not implemented.** The contract offers stroke-push (extending `applyInspectorToSelection()` to also stamp `style.strokeColor`/`strokeWidth`, plus wiring the toolbar's stroke `ColorPicker`/`Slider` to commit on release) as optional if it stays clean. It doesn't: SwiftUI's `ColorPicker` has no `onEditingChanged` parameter (only `Slider`/`Stepper` do), so committing stroke-color edits would need either a per-tick `.onChange(of:)` (pushing a history entry on every color drag tick, unlike every other inspector control's release-based commit) or new debounce state to fake an editing-changed boundary — real new surface, not a small fold-in. Per the contract's own escape hatch ("If this widens the diff too much, DEFER #3 and note it — #1+#2 are the required MVP"), #3 is deferred here; #1 (sync-on-select) and #2 (effective-kind inspector) are the full MVP and are implemented below.

- [ ] **Step 1: Write the failing EditorModel tests**

Append to `Tests/SXAnnotateTests/EditorModelTests.swift` (inside `@MainActor @Suite struct EditorModelTests`, using the existing `base()` helper):

```swift
    @Test func selectingABlurAnnotationSyncsBlurRadiusFromItsShape() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.blurRadius = 12
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.blurRadius = 30   // simulate the inspector default drifting after drawing
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 25, y: 25))   // inside the blur rect
        #expect(m.blurRadius == 12)
    }

    @Test func selectingAnAnnotationSyncsStrokeColorAndWidth() {
        let m = EditorModel(baseImage: base())
        m.strokeWidth = 9
        m.strokeColor = RGBAColor(r: 0, g: 1, b: 0, a: 1)
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.strokeWidth = 2
        m.strokeColor = .red
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 35, y: 35))   // inside the rect
        #expect(m.strokeWidth == 9)
        #expect(m.strokeColor == RGBAColor(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func applyInspectorToSelectionUpdatesTheJustSyncedBlurAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.blurRadius = 12
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 25, y: 25))   // selects + syncs blurRadius to 12
        m.blurRadius = 20                          // simulated inspector edit
        m.applyInspectorToSelection()
        guard case .blur(_, let radius) = m.annotations[0].shape else {
            Issue.record("expected .blur shape"); return
        }
        #expect(radius == 20)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `beginSelectGesture` doesn't sync the inspector vars yet, so `m.blurRadius`/`m.strokeWidth`/`m.strokeColor` still hold whatever was last set before selecting (30 / 2 / `.red`, not 12 / 9 / green), failing the first two tests' assertions; the third test then applies onto the wrong baseline too.

- [ ] **Step 3: Add the sync-on-select helper and wire it into `beginSelectGesture`**

In `Sources/SXAnnotate/Editor/EditorModel.swift`, change:

```swift
    private func beginSelectGesture(at point: CGPoint) {
        // Resize takes priority when a selected shape's handle is under the cursor.
        if let selected = selectedAnnotation,
           let handle = selected.handle(at: point, tolerance: handleTolerance) {
            activeHandle = handle
            return
        }
        // Otherwise pick the topmost annotation under the point.
        if let hit = annotations.last(where: { $0.hitTest(point, tolerance: hitTolerance) }) {
            selectedID = hit.id
            lastDragPoint = point
        } else {
            selectedID = nil
        }
    }
```

to:

```swift
    private func beginSelectGesture(at point: CGPoint) {
        // Resize takes priority when a selected shape's handle is under the cursor.
        if let selected = selectedAnnotation,
           let handle = selected.handle(at: point, tolerance: handleTolerance) {
            activeHandle = handle
            return
        }
        // Otherwise pick the topmost annotation under the point.
        if let hit = annotations.last(where: { $0.hitTest(point, tolerance: hitTolerance) }) {
            selectedID = hit.id
            lastDragPoint = point
            syncInspector(to: hit)
        } else {
            selectedID = nil
        }
    }

    /// Mirrors the selected annotation's real values into the published inspector
    /// vars, so the toolbar reflects the selection instead of stale values left
    /// over from whatever tool was last drawn with.
    private func syncInspector(to annotation: Annotation) {
        strokeColor = annotation.style.strokeColor
        strokeWidth = annotation.style.strokeWidth
        switch annotation.shape {
        case .blur(_, let radius):      blurRadius = radius
        case .pixelate(_, let scale):   pixelScale = scale
        case .text(_, _, let fontSize): textFontSize = fontSize
        default: break
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all three new `EditorModelTests` cases, plus every pre-existing `SXAnnotateTests` case (in particular the other `EditorModelTests` selection/undo/history cases, unaffected since `syncInspector` only writes the `@Published` inspector vars, never `annotations`).

- [ ] **Step 5: Key the inspector switch on the selected annotation's kind, not just the active tool**

In `Sources/SXApp/EditorView.swift`, change:

```swift
    /// Tool-specific creation parameters. Editing a control changes the model's
    /// published default; releasing it (`onEditingChanged == false`) applies the value
    /// to a matching selected shape via `applyInspectorToSelection()`.
    @ViewBuilder private var inspector: some View {
        switch model.activeTool {
        case .text:
```

to:

```swift
    /// The tool the inspector should key on: the SELECTED annotation's own kind when
    /// the Select tool is active and something matching an inspector-backed shape is
    /// selected, else the active drawing tool. Otherwise selecting an existing text/
    /// blur/pixelate annotation would show an empty inspector (`.select` → EmptyView),
    /// making it un-editable via the toolbar.
    private var effectiveInspectorTool: EditorTool {
        guard model.activeTool == .select, let selected = model.selectedAnnotation else {
            return model.activeTool
        }
        switch selected.shape {
        case .text: return .text
        case .blur: return .blur
        case .pixelate: return .pixelate
        default: return model.activeTool
        }
    }

    /// Tool-specific creation parameters. Editing a control changes the model's
    /// published default; releasing it (`onEditingChanged == false`) applies the value
    /// to a matching selected shape via `applyInspectorToSelection()`.
    @ViewBuilder private var inspector: some View {
        switch effectiveInspectorTool {
        case .text:
```

(The remaining `case .blur:`/`case .pixelate:`/`default: EmptyView()` arms are unchanged — only the `switch` subject and the added computed property above it change.)

- [ ] **Step 6: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!` — `SXApp` (EditorView) compiles against the unchanged `EditorModel` public surface.

- [ ] **Step 7: Run the full test suite**

Run: `scripts/remote.sh test`
Expected: PASS — every suite from Step 4 plus no regressions (EditorView has no test target).

- [ ] **Step 8: Commit**

```bash
git add Sources/SXAnnotate/Editor/EditorModel.swift Sources/SXApp/EditorView.swift Tests/SXAnnotateTests/EditorModelTests.swift
git commit -m "Sync editor inspector to the selected annotation's real values"
```

---
### Task 7: R1 — `scripts/dmg.sh` (NEW)

**Files:**
- Create: `scripts/dmg.sh` (committed executable)
- Test: none (shell script). Verified by a Mac build + `hdiutil attach`/`detach` mount check.

**Interfaces:**
- Consumes: `dist/ShareX for Mac.app` (produced by `scripts/bundle.sh`, which must already have run) and a `VERSION` env var (default `0.1.0`, same default as `bundle.sh`).
- Produces: `dist/ShareX-for-Mac-<VERSION>.dmg` — a compressed (`UDZO`) disk image containing the `.app` plus an `Applications` symlink, so dragging the app onto the symlink installs it (the standard macOS dmg convention).

- [ ] **Step 1: Create the script**

Create `scripts/dmg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/ShareX for Mac.app"
[ -d "$APP" ] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }
STAGE="dist/dmg-root"
DMG="dist/ShareX-for-Mac-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ShareX for Mac" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/dmg.sh
```

- [ ] **Step 3: Verify on the Mac — build, bundle, and package**

Run: `scripts/remote.sh ssh 'swift build -c release && scripts/bundle.sh && VERSION=0.1.0 scripts/dmg.sh'`
Expected: ends with `Built dist/ShareX-for-Mac-0.1.0.dmg`; `swift build`/`bundle.sh` succeed exactly as `scripts/remote.sh run` already exercises them.

- [ ] **Step 4: Verify the dmg mounts and contains the right layout**

Run: `scripts/remote.sh ssh 'hdiutil attach "dist/ShareX-for-Mac-0.1.0.dmg" -mountpoint /tmp/sxmac-dmg-check -nobrowse -quiet && ls -la /tmp/sxmac-dmg-check && hdiutil detach /tmp/sxmac-dmg-check -quiet'`
Expected: the `ls -la` output lists `ShareX for Mac.app` and an `Applications` symlink (`Applications -> /Applications`); `hdiutil detach` exits 0.

Report the dmg's size (`scripts/remote.sh ssh 'ls -lh dist/ShareX-for-Mac-0.1.0.dmg'`) and the mount-check result before proceeding — this is the task's actual verification, since there's no unit test.

- [ ] **Step 5: Commit**

```bash
git add scripts/dmg.sh
git commit -m "Add scripts/dmg.sh to package the built app into a distributable dmg"
```

---
### Task 8: R2 — `.github/workflows/release.yml` (NEW)

**Files:**
- Create: `.github/workflows/release.yml`
- Test: none (GitHub Actions workflow; only fully exercises on a real `v*` tag push). Verified via YAML validity + structural comparison against `ci.yml`.

**Interfaces:**
- Trigger: `push: tags: ['v*']`. Runs `swift build -c release` → `VERSION="${GITHUB_REF_NAME#v}" scripts/bundle.sh` → `VERSION="${GITHUB_REF_NAME#v}" scripts/dmg.sh` → `gh release create "${GITHUB_REF_NAME}" dist/*.dmg --title "${GITHUB_REF_NAME}" --generate-notes` on `runs-on: macos-15`, using `permissions: contents: write` and `GH_TOKEN: ${{ github.token }}` for the `gh` CLI (already present on `macos-15` runners — zero new dependency).

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build (release)
        run: swift build -c release
      - name: Bundle app
        run: VERSION="${GITHUB_REF_NAME#v}" scripts/bundle.sh
      - name: Create dmg
        run: VERSION="${GITHUB_REF_NAME#v}" scripts/dmg.sh
      - name: Publish GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "${GITHUB_REF_NAME}" dist/*.dmg --title "${GITHUB_REF_NAME}" --generate-notes
```

- [ ] **Step 2: Verify YAML validity**

Run: `scripts/remote.sh ssh 'python3 -c "import yaml, sys; yaml.safe_load(open(\"'"'"'.github/workflows/release.yml'"'"'\"))" && echo VALID'`
(Or equivalently, if `python3`+`pyyaml` are available locally: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('VALID')"`.)
Expected: prints `VALID` — no YAML syntax errors.

- [ ] **Step 3: Confirm it mirrors `ci.yml`'s runner/checkout and reuses R1's dmg.sh**

Manually diff against `.github/workflows/ci.yml`: same `runs-on: macos-15`, same `actions/checkout@v4` as step 1, no explicit Swift toolchain setup (macos-15 ships one, same assumption `ci.yml` already makes). Confirm the `Create dmg` step calls `scripts/dmg.sh` (Task 7) and the `Bundle app` step calls the existing `scripts/bundle.sh` — no duplicated packaging logic.

- [ ] **Step 4: Do NOT cut a tag in this task**

The workflow only fully executes on a real `v*` tag push. Do not run `git tag`/`git push --tags` here — whether to test-tag is a decision for the controller at the end of the M5b branch, not this task.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add ad-hoc-signed release workflow triggered on v* tags"
```

---
### Task 9: D1 — `docs/smoke-m5b.md` + `docs/RELEASING.md`

**Files:**
- Create: `docs/smoke-m5b.md`
- Create: `docs/RELEASING.md`
- Test: none (docs). This task also runs a final full build+test pass as its own verification.

**Interfaces:** Consumes everything built in Tasks 1–8. No code changes.

- [ ] **Step 1: Write `docs/smoke-m5b.md`**

Create `docs/smoke-m5b.md`:

```markdown
# M5b manual smoke checklist (release dmg + robustness/UI polish)

Run on the Mac after `scripts/remote.sh run` (for the UI items) and via `scripts/remote.sh ssh`
(for the dmg packaging item). Diagnostics: `~/Library/Logs/ShareX-Mac.log`. B1 (atomic Keychain
store), B2 (FTP stall abort), and B3 (recorder re-entrancy guard) are covered by their
SXCoreTests/SXRecordTests unit tests plus the existing SFTP/FTP live-upload smoke in
`docs/smoke-m5a.md` — not re-verified here.

- [ ] **dmg builds, mounts, and drag-installs (R1):** `scripts/remote.sh ssh 'swift build -c
      release && scripts/bundle.sh && VERSION=0.1.0 scripts/dmg.sh'`; confirm
      `dist/ShareX-for-Mac-0.1.0.dmg` is created. Double-click it in Finder (or `hdiutil attach`);
      confirm a Finder window opens showing "ShareX for Mac.app" and an "Applications" symlink;
      drag the app onto Applications and launch it from there.
- [ ] **Elapsed timer no longer flashes 0:00 (P1):** Start a recording, wait a few seconds, then
      trigger any menu rebuild mid-recording (e.g. toggle **System Audio**, which calls
      `rebuildMenu()`). Confirm the elapsed menu item's time does NOT reset to `0:00` even
      momentarily — it keeps counting from where it was.
- [ ] **GIF-export shows a spinner (P2):** History → export an mp4 as GIF. While `isExporting` is
      true (Cancel/Export both disabled), confirm a spinner + "Exporting…" text is visible next to
      the buttons, not just two disabled buttons that look frozen.
- [ ] **Inspector reflects the selected annotation (P3):** In the editor, draw a blur, a pixelate,
      and a text annotation, each with a distinct blur radius / pixel scale / font size. Switch to
      the **Select** tool and click each one in turn; confirm the toolbar inspector shows the
      matching control (Slider/Slider/Stepper, not empty) pre-filled with THAT annotation's real
      value (not whatever was last set while drawing). Adjust the control and release; confirm it
      updates that specific annotation only.
- [ ] **Release workflow YAML sanity:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
      exits 0. (The workflow itself only fully runs on a real `v*` tag push — not exercised here.)

M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`. M1 capture smoke: see `docs/smoke-m1.md`. M2a upload
smoke: see `docs/smoke-m2a.md`. M4 recording smoke: see `docs/smoke-m4.md`.
```

- [ ] **Step 2: Write `docs/RELEASING.md`**

Create `docs/RELEASING.md`:

```markdown
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
```

- [ ] **Step 3: Run the full build + test suite one last time**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

Run: `scripts/remote.sh test`
Expected: PASS — every suite added or touched across Tasks 1–6 (`S3CredentialsTests`, `SFTPCredentialsTests`, `ScreenRecorderStateMachineTests`, `EditorModelTests`) plus every pre-existing M1–M5a suite, unchanged.

- [ ] **Step 4: Commit**

```bash
git add docs/smoke-m5b.md docs/RELEASING.md
git commit -m "Add the M5b manual smoke checklist and release docs"
```

- [ ] **Step 5: Run the Mac Smoke Checklist**

Deploy with `scripts/remote.sh run` (and `scripts/remote.sh ssh` for the dmg step), then work through `docs/smoke-m5b.md` (reproduced below) before considering M5b done.

---
## Mac Smoke Checklist (run after Task 9, before finishing the branch)

This is the same checklist authored into `docs/smoke-m5b.md` by Task 9, reproduced here per the plan-format convention established in M5a. Deploy with `scripts/remote.sh run` (and `scripts/remote.sh ssh` for item 1), then:

1. **dmg builds, mounts, drag-installs (R1):** `scripts/remote.sh ssh 'swift build -c release && scripts/bundle.sh && VERSION=0.1.0 scripts/dmg.sh'` → `dist/ShareX-for-Mac-0.1.0.dmg` exists. Mount it; confirm the app + `Applications` symlink are inside; drag-install and launch from `/Applications`.
2. **Elapsed timer no longer flashes 0:00 (P1):** Start a recording, wait a few seconds, trigger a mid-recording menu rebuild (e.g. toggle System Audio); confirm the elapsed label doesn't reset.
3. **GIF-export spinner (P2):** Export an mp4 as GIF from History; confirm a spinner + "Exporting…" appear while `isExporting` is true.
4. **Inspector reflects selection (P3):** Draw a blur/pixelate/text annotation each with a distinct value; switch to Select, click each; confirm the matching inspector control shows with that annotation's real value, and edits apply only to the selected one.
5. **Release workflow YAML sanity:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"` exits 0.

B1/B2/B3 are covered by their unit tests (`S3CredentialsTests`, `SFTPCredentialsTests`, `ScreenRecorderStateMachineTests`) plus the existing SFTP/FTP live-upload smoke — not re-verified manually here.

M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`. M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`. M4 recording smoke: see `docs/smoke-m4.md`.

---
## Self-Review

*(Author checklist against the M5b architecture contract.)*

**1. Contract coverage** — each contract task → the plan task that satisfies it:
- B1 (atomic `S3Credentials.store`/`SFTPCredentials.store`, purge-then-rethrow, `FTPCredentials` untouched, `DestinationsView` call sites unchanged) → Task 1, verbatim contract code, `FailingAfterNStore` orphan-purge tests for both S3 and SFTP in `SXCoreTests`. ✅
- B2 (`CurlFTPTransport` `CURLOPT_LOW_SPEED_LIMIT`/`TIME` after `CURLOPT_CONNECTTIMEOUT`) → Task 2, verbatim contract code, build-only per the contract's own "no live FTP in CI" call. ✅
- B3 (`ScreenRecorder._assertIdleForTesting` seam + CI test in the non-gated suite) → Task 3, verbatim contract code and test, added to `ScreenRecorderStateMachineTests` (not `ScreenRecorderLiveTests`). ✅
- P1 (`AppDelegate` `recordingStartedAt` + `elapsedLabel(since:)` helper, set-before-`rebuildMenu()`, `buildRecordingItems` computed title, `tickElapsed` reuses the helper) → Task 4, matches the contract's four-part description exactly against the live file (`Sources/SXApp/AppDelegate.swift:172` hardcoded `"● 0:00"`, `:225-238` `updateRecordingUI`, `:243-248` `tickElapsed`, all verified live before editing). ✅
- P2 (`GifExportSheet` `ProgressView` + "Exporting…" in the button row, no `GifConverter` change) → Task 5, verbatim contract code inserted into the live button `HStack` (`Sources/SXApp/HistoryView.swift:206-220`). ✅
- P3 MVP (#1 sync-on-select in `beginSelectGesture`, #2 effective-kind inspector switch in `EditorView`) → Task 6, both implemented against the live `EditorModel`/`EditorView` code with `EditorModelTests` coverage for #1 and the `applyInspectorToSelection()` interaction; #3 (stroke push) explicitly DEFERRED with the SwiftUI `ColorPicker`-has-no-`onEditingChanged` rationale documented in the task's Interfaces section, per the contract's own "if this widens the diff too much, DEFER #3" escape hatch. ✅
- R1 (`scripts/dmg.sh`, chmod +x, consumes `dist/ShareX for Mac.app`, emits `dist/ShareX-for-Mac-<VERSION>.dmg`, Mac mount verification) → Task 7, verbatim contract script, `hdiutil attach`/`detach` verification step, size + mount-check reporting called out explicitly. ✅
- R2 (`.github/workflows/release.yml`, `v*` tag trigger, ad-hoc, `gh release create`, no tag cut in-task) → Task 8, verbatim contract YAML, YAML-validity step, structural diff-against-`ci.yml` step, explicit "do not tag" step. ✅
- D1 (`docs/smoke-m5b.md` + `docs/RELEASING.md`, checkbox convention, no AI-attribution/emoji) → Task 9, both docs written to match `docs/smoke-m4.md`'s established checkbox format, `docs/RELEASING.md` covers the tag → workflow → release chain plus the ad-hoc/Gatekeeper caveat. ✅
- Task ordering (B1→B2→B3→P1→P2→P3→R1→R2→D1) → followed exactly as Tasks 1–9. ✅

**2. Placeholder scan** — grep for `TBD`/`TODO`/`similar to Task`/`add error handling`/trailing `…` as a stand-in for real code: clean. Every code block is either pasted verbatim from the M5b architecture contract (B1's `store` wrapper, B2's two setopt lines, B3's `_assertIdleForTesting` + test, P2's `ProgressView` block, R1's `dmg.sh`, R2's `release.yml`) or a complete, real implementation written to close a gap the contract described only in prose (P1's four call-site diffs, spelled out against the actual live `AppDelegate.swift` text rather than left as "wire it up"; P3's `syncInspector`/`effectiveInspectorTool` bodies, which the contract sketched with one example line each and this plan writes out in full against the live `EditorModel.swift`/`EditorView.swift`; `docs/smoke-m5b.md`/`docs/RELEASING.md`, which the contract described only as bullet requirements). No task ships a stub, a "left for later" comment, or an untested code path that has a test seam available.

**3. CI-tested vs. build-only/smoke-only, matching the Hard Rules exactly:**
- CI-tested: **B1** (`Tests/SXCoreTests/S3CredentialsTests.swift`, `Tests/SXCoreTests/SFTPCredentialsTests.swift` — orphan-purge via `FailingAfterNStore`), **B3** (`Tests/SXRecordTests/ScreenRecorderTests.swift` — `_assertIdleForTesting`), **P3** (`Tests/SXAnnotateTests/EditorModelTests.swift` — sync-on-select + `applyInspectorToSelection` interaction).
- Build-only / script / doc, no unit test: **B2** (live libcurl transport, no FTP server in CI), **P1** (AppKit `NSMenu`/`Timer`, no `SXAppTests` target), **P2** (SwiftUI view, no `SXAppTests` target), **R1** (shell script — verified via the Mac build + `hdiutil` mount check), **R2** (GitHub Actions YAML — verified via YAML-validity + structural diff, no tag cut), **D1** (markdown docs — verified via the final full build+test pass). No task invents a test requiring a live server, a live UI harness, or a real tag push.

**4. B1 secrets invariant** — confirmed not regressed: the happy-path write sequence inside `S3Credentials.store`/`SFTPCredentials.store` is byte-for-byte identical to before (same `setSecret` calls in the same order), so every pre-existing round-trip/partial-secret/purge test in `S3CredentialsTests`/`SFTPCredentialsTests` keeps passing unmodified (Task 1, Step 4). The only behavioral change is on the failure path: what was previously "rethrow, possibly leaving an orphaned partial write in the Keychain" becomes "purge everything written for `id` so far, then rethrow" — strictly narrowing what can be left in the Keychain, never widening it. `DestinationsView.addS3`/`addSFTP` (`Sources/SXApp/DestinationsView.swift:74-119`, read live and confirmed unchanged by this plan) keep their own independent `catch { return }` and post-persist `try? purge(...)` rollback exactly as before — B1 and the existing call-site rollback are two independent layers of the same invariant, not a replacement of one by the other.

**Deliberate scope call surfaced to the human (not a bug — do not "fix" without re-confirming intent):**
- **P3 item #3 (stroke push) is deferred**, per the contract's own conditional wording. Extending `applyInspectorToSelection()` to stamp `style.strokeColor`/`strokeWidth` is a one-line addition, but committing it correctly from the toolbar's stroke `ColorPicker` has no natural "release" boundary in SwiftUI (`ColorPicker` lacks `onEditingChanged`, unlike `Slider`/`Stepper`), so a faithful implementation would add either per-tick history commits (breaking the release-based commit convention every other inspector control follows) or new debounce state — a genuinely separate unit of work, not a fold-in. The MVP (#1 sync-on-select, #2 effective-kind inspector switch) fully satisfies "selecting an existing text/blur/pixelate annotation surfaces the matching control pre-filled with its real value," which is the concrete, testable behavior the contract and `docs/smoke-m5b.md` both check for.
