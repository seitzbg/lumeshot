# M4 — Screen Recording (mp4 + GIF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add screen recording (region, window, and display modes) that always produces an mp4 through the existing local-first save/upload pipeline, plus an on-demand native GIF export from History.

**Architecture:** A new `SXRecord` library target owns the concurrency-hardened `ScreenRecorder` (SCStream + SCRecordingOutput via a `@Sendable`-sink delegate shim that hops to `@MainActor`), the pure `RecordingDimensions`/`RecordingError` types, and the native `GifConverter` (`AVAssetImageGenerator` → animated GIF), while `SXCapture` gains small SCK object-resolution helpers so `SXApp`'s new `RecordingCoordinator` can build a live `SCContentFilter` from the same region-overlay/window-picker/display-enumeration UX already used for stills. Every recording is always an mp4, delivered through a new file-based delivery path on `CaptureCoordinator` (`deliverRecording`) that shares its history+upload plumbing with the still-image path via a generalized `UploadService.upload(data:filename:mime:destination:)`; GIF is a separate, on-demand "Export as GIF…" action in the History window that converts an existing mp4 into a sibling `.gif` with its own history row, never replacing the mp4.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (tools 6.0), macOS 15+, AppKit + SwiftUI, AVFoundation + ScreenCaptureKit (`SCRecordingOutput`) + ImageIO + CoreImage (all system frameworks — no SwiftPM dependency), swift-testing.

## Global Constraints

*Every task's requirements implicitly include this section. Values are copied verbatim from the ratified M4 architecture contract and the project's standing rules.*

- Swift 6 strict concurrency; `swift-tools-version: 6.0`; `platforms: [.macOS(.v15)]`. NO downgrade.
- **CI-SDK trap (M1-class):** the dev Mac (Swift 6.3) MASKS strict-concurrency errors that CI (macos-15 / Xcode 16.4 / Swift 6.0) ENFORCES. Every new type crossing an actor boundary needs explicit isolation. ScreenCaptureKit is imported `@preconcurrency`. Delegate callbacks arrive on background queues and MUST hop to `@MainActor` — never touch MainActor state synchronously from a delegate method.
- **Local-first invariant:** `SCRecordingOutput` writes the mp4 to disk itself; the file exists before any upload. A failed upload never loses the recording (history row + file remain, `uploadFailed = true`).
- **Fail-loud:** surface recording/conversion/upload errors via `AppLog.log` + `effects.notify(...)`. No silent catch-and-drop.
- **Secrets:** unchanged — none introduced here; uploads reuse the existing `UploadService`/Keychain path.
- **No AI-attribution boilerplate** anywhere (commits, docs, comments).
- **Ratified — GIF model:** recording ALWAYS produces mp4 (the primary artifact, delivered through the normal save/optional-upload path). GIF is an on-demand **"Export as GIF…"** action in the History window (fps/scale sheet), producing a derived `.gif` file next to the mp4 and its own history row. The mp4 is never discarded.
- **Ratified — Modes:** all three — region, window, display — reusing the existing region overlay, window picker, and display enumeration.
- **Test framework:** swift-testing (`import Testing`, `@Test`, `#expect`, `@Suite`; `@MainActor @Suite` for MainActor units). Zero XCTest.
- **Build/test loop:** `scripts/remote.sh build` and `scripts/remote.sh test` rsync to the Mac and run over SSH; `scripts/remote.sh run` rebuilds+bundles+launches for interactive smoke. `build`/`test` do NOT re-bundle the `.app`.
- **SCK live tests** self-skip in CI: gate with `@Test(.enabled(if: CGPreflightScreenCaptureAccess()))`.

## File Structure

**New target (`SXRecord`):** `Sources/SXRecord/RecordingError.swift`, `RecordingDimensions.swift`, `ScreenRecorder.swift`, `GifConverter.swift`. Test target `Tests/SXRecordTests/`.

**No new `SXApp` test target.** `SXApp` is an `.executableTarget` containing top-level code (`Sources/SXApp/main.swift`); a test target **cannot** `@testable import` an executable with a `main`, so an `SXAppTests` target would fail to build, and splitting SXApp into a thin `main` + library would rename the binary and break `scripts/bundle.sh` / `Resources/Info.plist` `CFBundleExecutable` / the `pkill` patterns in `scripts/remote.sh` (out of scope for M4). Therefore **every unit-testable piece of M4 logic lives in a library target** (`SXCore`/`SXRecord`/`SXUpload`) and is tested in that target's existing test target; the `SXApp` types (`CaptureCoordinator`, `RecordingCoordinator`, `HistoryModel`, `Thumbnail`) stay thin glue over those library helpers and are exercised only by the Mac Smoke Checklist. Package.swift's only M4 additions are `SXRecord` + `SXRecordTests`.

**Modified (`SXCore`):** `AppSettings.swift` (+`RecordingSettings`, +`HotkeySettings.record`). New `RecordingSettings.swift`, `MIMEType.swift` (`forExtension` + `isVideo`), `RecordingDelivery.swift` (the testable history-insert→upload ordering core `deliver`, plus the pure `outputURL`/`gifOutputURL` path helpers).

**Modified (`SXCapture`):** `DisplayCapture.swift` (+`shareableContent()`, +`scDisplay(for:in:)`), `WindowCapture.swift` (+`scWindow(for:in:)`, `backingScale(forCGGlobalFrame:)` made `public`).

**Modified (`SXApp`):** `CaptureCoordinator.swift` (adds `deliverRecording` glue over `RecordingDelivery.deliver`; its own `effects: AppPipelineEffects` stored property is left UNCHANGED — M1–M3b shipped code), `UploadService.swift` (additive `upload(data:filename:mime:destination:)`), `RegionOverlay.swift` (`RegionSelectionView`/`KeyableWindow` made internal for reuse), `StatusItemController.swift` (+recording icon/elapsed title), `AppDelegate.swift` (Record menu, hotkey, end-to-end wiring), `HistoryView.swift` + `HistoryWindowController.swift` (video thumbnails via `MIMEType.isVideo`, Export as GIF sheet via `RecordingDelivery.gifOutputURL`). New `RecordingRegionSession.swift`, `RecordingCoordinator.swift`.

**Modified (bundle):** `Resources/Info.plist` (mp4/gif document types, optional).

---
### Task 1: RecordingSettings + AppSettings/HotkeySettings integration + migration tests

**Files:**
- Create: `Sources/SXCore/RecordingSettings.swift`
- Modify: `Sources/SXCore/AppSettings.swift`
- Test: Create `Tests/SXCoreTests/RecordingSettingsTests.swift`

**Interfaces:**
- Consumes: nothing new (pure `Codable` types, following the existing `EditorSettings` no-schema-bump precedent already in `AppSettings.swift`).
- Produces:
  - `public struct RecordingSettings: Codable, Equatable, Sendable { systemAudio: Bool; videoCodec: VideoCodec; gifFPS: Int; gifMaxWidth: Int? }` with `enum VideoCodec: String, Codable, Equatable, Sendable { case h264, hevc }` and `static let default = RecordingSettings()` (`systemAudio: false, videoCodec: .h264, gifFPS: 15, gifMaxWidth: 640`).
  - `AppSettings.recording: RecordingSettings` (defaults via `decodeIfPresent`, no schema bump).
  - `HotkeySettings.record: HotkeyCombo?`, default `HotkeyCombo(keyCode: 22, modifiers: 2560)` (⌥⇧6) baked into `AppSettings.default`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXCoreTests/RecordingSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import SXCore

@Suite struct RecordingSettingsTests {
    @Test func defaultsMatchSpec() {
        let r = RecordingSettings.default
        #expect(r.systemAudio == false)
        #expect(r.videoCodec == .h264)
        #expect(r.gifFPS == 15)
        #expect(r.gifMaxWidth == 640)
    }

    @Test func settingsRoundTripPreservesRecording() throws {
        var s = AppSettings.default
        s.recording.systemAudio = true
        s.recording.videoCodec = .hevc
        s.recording.gifFPS = 24
        s.recording.gifMaxWidth = nil
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.recording.systemAudio == true)
        #expect(decoded.recording.videoCodec == .hevc)
        #expect(decoded.recording.gifFPS == 24)
        #expect(decoded.recording.gifMaxWidth == nil)
    }

    @Test func legacyFileWithoutRecordingKeyDefaultsIt() throws {
        // A settings JSON that predates the recording field (and the record
        // hotkey) must still decode — same v2-no-bump treatment as `editor`.
        let json = """
        {"schemaVersion":2,"captureSavePath":"~/Pictures/ShareX","filenameTemplate":"x",
         "saveToDisk":true,"copyToClipboard":true,"showNotification":true,
         "hotkeys":{"fullscreen":null,"region":null,"window":null}}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.recording == RecordingSettings.default)
        #expect(decoded.hotkeys.record == nil)
    }

    @Test func defaultHotkeysIncludeRecord() {
        #expect(AppSettings.default.hotkeys.record == HotkeyCombo(keyCode: 22, modifiers: 2560))  // ⌥⇧6
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `RecordingSettings` does not exist yet and `HotkeySettings` has no `record` member, so `RecordingSettingsTests.swift` fails to compile.

- [ ] **Step 3: Add RecordingSettings and wire it into AppSettings**

Create `Sources/SXCore/RecordingSettings.swift`:

```swift
import Foundation

public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Capture system (device) audio into the recording. Uses Screen Recording TCC (already granted); no mic prompt.
    public var systemAudio: Bool
    /// H.264 vs HEVC. Stored as a stable string; default h264 for broad compatibility.
    public var videoCodec: VideoCodec
    /// Default fps for GIF export sheet.
    public var gifFPS: Int
    /// Default max width (px) for GIF export; nil = source width.
    public var gifMaxWidth: Int?

    public enum VideoCodec: String, Codable, Equatable, Sendable { case h264, hevc }

    public init(systemAudio: Bool = false,
                videoCodec: VideoCodec = .h264,
                gifFPS: Int = 15,
                gifMaxWidth: Int? = 640) {
        self.systemAudio = systemAudio
        self.videoCodec = videoCodec
        self.gifFPS = gifFPS
        self.gifMaxWidth = gifMaxWidth
    }

    public static let `default` = RecordingSettings()
}
```

In `Sources/SXCore/AppSettings.swift`, replace the whole file with:

```swift
import Foundation

public struct HotkeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32     // Carbon virtual key code
    public var modifiers: UInt32   // Carbon modifier mask
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HotkeySettings: Codable, Equatable, Sendable {
    public var fullscreen: HotkeyCombo?
    public var region: HotkeyCombo?
    public var window: HotkeyCombo?
    public var record: HotkeyCombo?
    public init(fullscreen: HotkeyCombo?, region: HotkeyCombo?, window: HotkeyCombo?,
                record: HotkeyCombo? = nil) {
        self.fullscreen = fullscreen
        self.region = region
        self.window = window
        self.record = record
    }
}

public struct EditorSettings: Codable, Equatable, Sendable {
    public var annotateBeforeShare: Bool
    public init(annotateBeforeShare: Bool) {
        self.annotateBeforeShare = annotateBeforeShare
    }
    public static let `default` = EditorSettings(annotateBeforeShare: false)
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureSavePath: String     // supports leading ~
    public var filenameTemplate: String    // NameParser template, no extension
    public var saveToDisk: Bool
    public var copyToClipboard: Bool
    public var showNotification: Bool
    public var hotkeys: HotkeySettings
    public var upload: UploadSettings
    public var editor: EditorSettings
    public var recording: RecordingSettings

    public init(schemaVersion: Int, captureSavePath: String, filenameTemplate: String,
                saveToDisk: Bool, copyToClipboard: Bool, showNotification: Bool,
                hotkeys: HotkeySettings, upload: UploadSettings,
                editor: EditorSettings = .default, recording: RecordingSettings = .default) {
        self.schemaVersion = schemaVersion
        self.captureSavePath = captureSavePath
        self.filenameTemplate = filenameTemplate
        self.saveToDisk = saveToDisk
        self.copyToClipboard = copyToClipboard
        self.showNotification = showNotification
        self.hotkeys = hotkeys
        self.upload = upload
        self.editor = editor
        self.recording = recording
    }

    // Tolerate older settings files: a v1 file lacks `upload` (SettingsStore migrates it
    // to schemaVersion 2); a pre-editor v2 file lacks `editor`; a pre-recording v2 file
    // lacks `recording` — none of these bump the version. The decoder defaults each
    // missing key; every other field is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        captureSavePath = try c.decode(String.self, forKey: .captureSavePath)
        filenameTemplate = try c.decode(String.self, forKey: .filenameTemplate)
        saveToDisk = try c.decode(Bool.self, forKey: .saveToDisk)
        copyToClipboard = try c.decode(Bool.self, forKey: .copyToClipboard)
        showNotification = try c.decode(Bool.self, forKey: .showNotification)
        hotkeys = try c.decode(HotkeySettings.self, forKey: .hotkeys)
        upload = try c.decodeIfPresent(UploadSettings.self, forKey: .upload) ?? .disabled
        editor = try c.decodeIfPresent(EditorSettings.self, forKey: .editor) ?? .default
        recording = try c.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? .default
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureSavePath, filenameTemplate, saveToDisk,
             copyToClipboard, showNotification, hotkeys, upload, editor, recording
    }

    // Carbon: optionKey(2048) | shiftKey(512) = 2560; kVK_ANSI_3=20, _4=21, _5=23, _6=22
    public static let `default` = AppSettings(
        schemaVersion: 2,
        captureSavePath: "~/Pictures/ShareX",
        filenameTemplate: "Screenshot_%y-%mo-%d_%h-%mi-%s",
        saveToDisk: true,
        copyToClipboard: true,
        showNotification: true,
        hotkeys: HotkeySettings(
            fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560),
            region: HotkeyCombo(keyCode: 21, modifiers: 2560),
            window: HotkeyCombo(keyCode: 23, modifiers: 2560),
            record: HotkeyCombo(keyCode: 22, modifiers: 2560)
        ),
        upload: .disabled,
        editor: .default,
        recording: .default
    )
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `RecordingSettingsTests`, and every pre-existing `SXCoreTests` suite (in particular `EditorSettingsTests` and `SettingsStoreTests.defaultsHaveExpectedHotkeys`, which do not reference `record`/`recording` and are unaffected by the additive change).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/RecordingSettings.swift Sources/SXCore/AppSettings.swift Tests/SXCoreTests/RecordingSettingsTests.swift
git commit -m "Add RecordingSettings and the record hotkey to AppSettings"
```

---
### Task 2: SXRecord target scaffold + RecordingError + RecordingDimensions

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SXRecord/RecordingError.swift`
- Create: `Sources/SXRecord/RecordingDimensions.swift`
- Test: Create `Tests/SXRecordTests/RecordingDimensionsTests.swift`

**Interfaces:**
- Consumes: nothing (pure `CoreGraphics`).
- Produces:
  - `public enum RecordingError: Error, Equatable { case alreadyRecording, notRecording, startFailed(String), recordingFailed(String), conversionFailed(String) }`
  - `public struct RecordingDimensions: Equatable, Sendable { width: Int; height: Int; sourceRect: CGRect? }` with factories `.display(pointWidth:pointHeight:scale:)`, `.region(rectInPoints:scale:)`, `.window(pointWidth:pointHeight:scale:)`, all rounding output pixels down to even (`max(2, v - v % 2)`).

- [ ] **Step 1: Scaffold the SXRecord target and add RecordingError**

In `Package.swift`, replace the whole file with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharex-mac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SXApp", dependencies: ["SXCore", "SXCapture", "SXUpload", "SXAnnotate", "SXRecord"]),
        .target(name: "SXCore"),
        .target(name: "SXCapture", dependencies: ["SXCore"]),
        .target(name: "SXUpload", dependencies: ["SXCore"]),
        .target(name: "SXAnnotate"),
        .target(name: "SXRecord", dependencies: ["SXCore"]),
        .testTarget(name: "SXCoreTests", dependencies: ["SXCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SXCaptureTests", dependencies: ["SXCapture"]),
        .testTarget(name: "SXUploadTests", dependencies: ["SXUpload"]),
        .testTarget(name: "SXAnnotateTests", dependencies: ["SXAnnotate"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SXRecordTests", dependencies: ["SXRecord"]),
    ]
)
```

Create `Sources/SXRecord/RecordingError.swift`:

```swift
import Foundation

public enum RecordingError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case startFailed(String)
    case recordingFailed(String)
    case conversionFailed(String)
}
```

- [ ] **Step 2: Write the failing test for RecordingDimensions**

Create `Tests/SXRecordTests/RecordingDimensionsTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXRecord

@Suite struct RecordingDimensionsTests {
    @Test func displayConvertsPointsToPixelsAtScale() {
        let d = RecordingDimensions.display(pointWidth: 1512, pointHeight: 982, scale: 2)
        #expect(d.width == 3024)
        #expect(d.height == 1964)
        #expect(d.sourceRect == nil)
    }

    @Test func displayRoundsToEvenWhenScaledSizeIsOdd() {
        let d = RecordingDimensions.display(pointWidth: 375.5, pointHeight: 200.5, scale: 1)
        // 375.5 rounds to 376 (already even); 200.5 rounds to 201 (odd) -> 200.
        #expect(d.width == 376)
        #expect(d.height == 200)
    }

    @Test func regionPassesThroughSourceRectAndScalesOutput() {
        let rect = CGRect(x: 10, y: 20, width: 401, height: 301)
        let d = RecordingDimensions.region(rectInPoints: rect, scale: 2)
        #expect(d.width == 802)
        #expect(d.height == 602)
        #expect(d.sourceRect == rect)
    }

    @Test func regionRoundsOddScaledDimensionsToEven() {
        let rect = CGRect(x: 0, y: 0, width: 15, height: 15)
        let d = RecordingDimensions.region(rectInPoints: rect, scale: 1)
        #expect(d.width == 14)
        #expect(d.height == 14)
    }

    @Test func windowHasNoCropAndScalesLikeDisplay() {
        let d = RecordingDimensions.window(pointWidth: 800, pointHeight: 600, scale: 2)
        #expect(d.width == 1600)
        #expect(d.height == 1200)
        #expect(d.sourceRect == nil)
    }

    @Test func degenerateZeroSizeClampsToTheEvenMinimumOfTwo() {
        let d = RecordingDimensions.display(pointWidth: 0, pointHeight: 0, scale: 2)
        #expect(d.width == 2)
        #expect(d.height == 2)
    }

    @Test func equatableComparesAllFields() {
        let a = RecordingDimensions(width: 100, height: 50, sourceRect: CGRect(x: 1, y: 1, width: 2, height: 2))
        let b = RecordingDimensions(width: 100, height: 50, sourceRect: CGRect(x: 1, y: 1, width: 2, height: 2))
        let c = RecordingDimensions(width: 100, height: 50, sourceRect: nil)
        #expect(a == b)
        #expect(a != c)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `RecordingDimensions` does not exist yet, so `RecordingDimensionsTests.swift` fails to compile.

- [ ] **Step 4: Add RecordingDimensions**

Create `Sources/SXRecord/RecordingDimensions.swift`:

```swift
import CoreGraphics

/// Output pixel dimensions + optional crop region for an SCStreamConfiguration.
/// Video encoders require EVEN width/height; all factories round down to even.
public struct RecordingDimensions: Equatable, Sendable {
    public let width: Int          // output pixels
    public let height: Int         // output pixels
    public let sourceRect: CGRect? // points, display-local top-left; nil = whole filter

    public init(width: Int, height: Int, sourceRect: CGRect?) {
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
    }

    static func even(_ v: Int) -> Int { max(2, v - (v % 2)) }

    /// Whole display: capture at native pixel resolution, no crop.
    public static func display(pointWidth: CGFloat, pointHeight: CGFloat, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((pointWidth * scale).rounded())),
                            height: even(Int((pointHeight * scale).rounded())),
                            sourceRect: nil)
    }

    /// Region within a display: sourceRect in display-local points; output = region * scale, rounded even.
    public static func region(rectInPoints: CGRect, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((rectInPoints.width * scale).rounded())),
                            height: even(Int((rectInPoints.height * scale).rounded())),
                            sourceRect: rectInPoints)
    }

    /// Whole window: output = window size * scale, no crop (window filter already scopes content).
    public static func window(pointWidth: CGFloat, pointHeight: CGFloat, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((pointWidth * scale).rounded())),
                            height: even(Int((pointHeight * scale).rounded())),
                            sourceRect: nil)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `RecordingDimensionsTests`, and every pre-existing suite in the other four test targets (the new `SXRecordTests` target is additive).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SXRecord/RecordingError.swift Sources/SXRecord/RecordingDimensions.swift Tests/SXRecordTests/RecordingDimensionsTests.swift
git commit -m "Scaffold the SXRecord target with RecordingError and RecordingDimensions"
```

---
### Task 3: SCK filter-resolution helpers in SXCapture

**Files:**
- Modify: `Sources/SXCapture/DisplayCapture.swift`
- Modify: `Sources/SXCapture/WindowCapture.swift`
- Test: Modify `Tests/SXCaptureTests/DisplayCaptureTests.swift`
- Test: Create `Tests/SXCaptureTests/WindowCaptureTests.swift`

**Interfaces:**
- Consumes: nothing new — `@preconcurrency import ScreenCaptureKit` already used in both files (M1).
- Produces:
  - `DisplayCapture.shareableContent() async throws -> SCShareableContent` (`@MainActor`).
  - `DisplayCapture.scDisplay(for displayID: CGDirectDisplayID, in content: SCShareableContent) -> SCDisplay?` (`@MainActor`).
  - `WindowCapture.scWindow(for windowID: UInt32, in content: SCShareableContent) -> SCWindow?` (`@MainActor`).

`captureAllDisplays`/`candidates` deliberately hide the raw SCK objects behind `FrozenDisplay`/`WindowCandidate`; Task 9's `RecordingCoordinator` needs the live `SCDisplay`/`SCWindow` to build an `SCContentFilter` for an in-progress recording, so these helpers resolve them from fresh `SCShareableContent` without changing the existing still-capture API.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SXCaptureTests/DisplayCaptureTests.swift` (inside the existing `@MainActor @Suite struct DisplayCaptureTests`):

```swift
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func shareableContentResolvesEveryConnectedDisplay() async throws {
        let content = try await DisplayCapture.shareableContent()
        #expect(!content.displays.isEmpty)
        for display in content.displays {
            let resolved = DisplayCapture.scDisplay(for: display.displayID, in: content)
            #expect(resolved?.displayID == display.displayID)
        }
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func scDisplayReturnsNilForAnUnknownDisplayID() async throws {
        let content = try await DisplayCapture.shareableContent()
        #expect(DisplayCapture.scDisplay(for: 999_999, in: content) == nil)
    }
```

Create `Tests/SXCaptureTests/WindowCaptureTests.swift`:

```swift
import CoreGraphics
import Testing
// @preconcurrency: see DisplayCapture.swift — keeps the non-Sendable
// SCShareableContent building under Swift 6 strict concurrency on this SDK.
@preconcurrency import ScreenCaptureKit
@testable import SXCapture

@Suite struct WindowCaptureTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func scWindowResolvesACandidatesWindowID() async throws {
        let content = try await DisplayCapture.shareableContent()
        guard let firstWindow = content.windows.first else { return }   // nothing on screen to assert against
        let resolved = WindowCapture.scWindow(for: firstWindow.windowID, in: content)
        #expect(resolved?.windowID == firstWindow.windowID)
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func scWindowReturnsNilForAnUnknownWindowID() async throws {
        let content = try await DisplayCapture.shareableContent()
        #expect(WindowCapture.scWindow(for: 0, in: content) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `DisplayCapture.shareableContent`/`scDisplay` and `WindowCapture.scWindow` do not exist yet, so both files fail to compile.

- [ ] **Step 3: Add the resolution helpers**

In `Sources/SXCapture/DisplayCapture.swift`, add to the `DisplayCapture` enum (after `captureAllDisplays`):

```swift
    /// Fresh shareable-content snapshot, exposing the raw SCK objects that
    /// `captureAllDisplays` deliberately hides behind `FrozenDisplay`. Recording
    /// (M4) needs the live `SCDisplay` to build an `SCContentFilter`.
    public static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Resolves the `SCDisplay` matching `displayID` from a `shareableContent()` snapshot.
    public static func scDisplay(for displayID: CGDirectDisplayID,
                                 in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == displayID }
    }
```

In `Sources/SXCapture/WindowCapture.swift`, add to the `WindowCapture` enum (after `candidates`):

```swift
    /// Resolves the `SCWindow` matching `windowID` from a `shareableContent()` snapshot.
    /// `candidates` deliberately hides the raw SCK object behind `WindowCandidate`;
    /// recording (M4) needs the live `SCWindow` to build an `SCContentFilter`.
    public static func scWindow(for windowID: UInt32, in content: SCShareableContent) -> SCWindow? {
        content.windows.first { $0.windowID == windowID }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — the new gated tests when run on the Mac (with Screen Recording granted); self-skip in CI. Every pre-existing `SXCaptureTests` suite stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCapture/DisplayCapture.swift Sources/SXCapture/WindowCapture.swift Tests/SXCaptureTests/DisplayCaptureTests.swift Tests/SXCaptureTests/WindowCaptureTests.swift
git commit -m "Add SCK filter-resolution helpers for display and window recording"
```

---
### Task 4: ScreenRecorder (SCStream + SCRecordingOutput, concurrency-hardened)

**Files:**
- Create: `Sources/SXRecord/ScreenRecorder.swift`
- Test: Create `Tests/SXRecordTests/ScreenRecorderTests.swift`

**Interfaces:**
- Consumes: `RecordingDimensions`, `RecordingError` (Task 2).
- Produces:
  - `enum RecordingEvent: Sendable { case started, finished, failed(String) }` (module-internal).
  - `final class RecordingDelegateShim: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable` — immutable `@Sendable` sink, no mutable state.
  - `@MainActor public final class ScreenRecorder` with `enum State: Equatable { case idle, recording }`, `private(set) var state: State`, `func start(filter:dimensions:capturesAudio:codec:outputURL:onFinish:) async throws`, `func stop() async`, `func handle(_ event: RecordingEvent)` (internal, not `private` — a deliberate test seam), `func _beginForTesting(outputURL:onFinish:)` (internal, test-only — bypasses SCStream/SCRecordingOutput so the fire-once/state-reset logic is unit-testable without live ScreenCaptureKit access).

This is the concurrency-critical file: the delegate shim's callbacks land on an SCK-owned background queue and MUST NOT touch `@MainActor` state directly — each callback wraps its sink call in `Task { @MainActor in self?.handle(event) }`.

- [ ] **Step 1: Write the failing pure state-machine tests**

Create `Tests/SXRecordTests/ScreenRecorderTests.swift`:

```swift
import Foundation
import Testing
@testable import SXRecord

@MainActor @Suite struct ScreenRecorderStateMachineTests {
    @Test func startsIdle() {
        let r = ScreenRecorder()
        #expect(r.state == .idle)
    }

    @Test func finishedEventDeliversSuccessAndResetsToIdle() {
        let r = ScreenRecorder()
        let url = URL(fileURLWithPath: "/tmp/rec.mp4")
        var delivered: Result<URL, RecordingError>?
        r._beginForTesting(outputURL: url) { delivered = $0 }
        r.handle(.finished)
        #expect(r.state == .idle)
        switch delivered {
        case .success(let deliveredURL): #expect(deliveredURL == url)
        default: Issue.record("expected .success")
        }
    }

    @Test func failedEventDeliversFailureAndResetsToIdle() {
        let r = ScreenRecorder()
        var delivered: Result<URL, RecordingError>?
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { delivered = $0 }
        r.handle(.failed("stream stopped"))
        #expect(r.state == .idle)
        switch delivered {
        case .failure(.recordingFailed(let msg)): #expect(msg == "stream stopped")
        default: Issue.record("expected .failure(.recordingFailed)")
        }
    }

    @Test func startedEventDoesNotDeliverOrChangeState() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        r.handle(.started)
        #expect(r.state == .recording)
        #expect(deliveries == 0)
    }

    @Test func deliversOnlyOncePerSession() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        r.handle(.finished)
        r.handle(.failed("late error after finish"))   // must be swallowed — already delivered
        #expect(deliveries == 1)
        #expect(r.state == .idle)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `ScreenRecorder` does not exist yet, so `ScreenRecorderTests.swift` fails to compile.

- [ ] **Step 3: Implement ScreenRecorder**

Create `Sources/SXRecord/ScreenRecorder.swift`:

```swift
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Sendable event surfaced from background delegate callbacks.
enum RecordingEvent: Sendable {
    case started
    case finished
    case failed(String)
}

/// nonisolated delegate shim: no mutable state, only an immutable @Sendable sink. Safe to receive
/// callbacks on SCK's background queue. Retained by ScreenRecorder (SCK delegates are weak).
final class RecordingDelegateShim: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let sink: @Sendable (RecordingEvent) -> Void
    init(sink: @escaping @Sendable (RecordingEvent) -> Void) { self.sink = sink }

    // SCRecordingOutputDelegate
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { sink(.started) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { sink(.failed(error.localizedDescription)) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { sink(.finished) }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) { sink(.failed(error.localizedDescription)) }
}

@MainActor
public final class ScreenRecorder {
    public enum State: Equatable { case idle, recording }
    public private(set) var state: State = .idle

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var shim: RecordingDelegateShim?
    private var outputURL: URL?
    private var onFinish: ((Result<URL, RecordingError>) -> Void)?
    private var didDeliver = false   // fire onFinish exactly once per session

    public init() {}

    /// Start recording `filter` to `url`. `onFinish` is invoked once on MainActor when the file is
    /// finalized (success) or the session fails (failure). Throws synchronously only if start fails.
    public func start(filter: SCContentFilter,
                      dimensions: RecordingDimensions,
                      capturesAudio: Bool,
                      codec: AVVideoCodecType,
                      outputURL url: URL,
                      onFinish: @escaping (Result<URL, RecordingError>) -> Void) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }

        let config = SCStreamConfiguration()
        config.width = dimensions.width
        config.height = dimensions.height
        if let sr = dimensions.sourceRect { config.sourceRect = sr }
        config.showsCursor = true
        config.capturesAudio = capturesAudio
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = codec

        let shim = RecordingDelegateShim { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let output = SCRecordingOutput(configuration: recConfig, delegate: shim)
        let stream = SCStream(filter: filter, configuration: config, delegate: shim)
        try stream.addRecordingOutput(output)   // VERIFY on Mac: if startCapture requires a stream output, add a no-op SCStreamOutput on a bg queue.

        self.stream = stream
        self.recordingOutput = output
        self.shim = shim
        self.outputURL = url
        self.onFinish = onFinish
        self.didDeliver = false

        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw RecordingError.startFailed(error.localizedDescription)
        }
        state = .recording
    }

    /// Stop; the file is delivered via the delegate `finished` event (do NOT deliver here).
    public func stop() async {
        guard state == .recording, let stream else { return }
        do { try await stream.stopCapture() }
        catch { deliver(.failure(.recordingFailed(error.localizedDescription))); return }
        // success delivered by recordingOutputDidFinishRecording
    }

    /// Test-only seam: puts the recorder into `.recording` with a synthetic
    /// completion, bypassing SCStream/SCRecordingOutput entirely, so the pure
    /// state machine (fire-once `deliver`, `handle` event -> outcome mapping,
    /// reset-to-idle) is unit-testable without live ScreenCaptureKit access or
    /// the Screen Recording TCC grant.
    func _beginForTesting(outputURL: URL, onFinish: @escaping (Result<URL, RecordingError>) -> Void) {
        self.outputURL = outputURL
        self.onFinish = onFinish
        self.didDeliver = false
        state = .recording
    }

    func handle(_ event: RecordingEvent) {
        switch event {
        case .started: break
        case .finished:
            if let url = outputURL { deliver(.success(url)) } else { deliver(.failure(.recordingFailed("no output url"))) }
        case .failed(let msg):
            deliver(.failure(.recordingFailed(msg)))
        }
    }

    private func deliver(_ result: Result<URL, RecordingError>) {
        guard !didDeliver else { return }
        didDeliver = true
        let cb = onFinish
        reset()
        cb?(result)
    }

    private func reset() {
        stream = nil; recordingOutput = nil; shim = nil; outputURL = nil; onFinish = nil
        state = .idle
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `ScreenRecorderStateMachineTests`.

- [ ] **Step 5: Add the gated live recording test**

Append to `Tests/SXRecordTests/ScreenRecorderTests.swift`:

```swift
import CoreGraphics
// @preconcurrency: see SXCapture/DisplayCapture.swift for why.
@preconcurrency import ScreenCaptureKit
import AVFoundation

@MainActor @Suite struct ScreenRecorderLiveTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func recordsAShortClipToAnMP4File() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            Issue.record("no displays available to record"); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let dims = RecordingDimensions.display(pointWidth: 640, pointHeight: 360, scale: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")

        let recorder = ScreenRecorder()
        let outcome = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result<URL, RecordingError>, Error>) in
            Task { @MainActor in
                do {
                    try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                             codec: .h264, outputURL: url) { result in
                        cont.resume(returning: result)
                    }
                    try await Task.sleep(for: .seconds(1))
                    await recorder.stop()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        switch outcome {
        case .success(let finishedURL):
            #expect(finishedURL == url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attrs[.size] as? Int ?? 0) > 0)
        case .failure(let error):
            Issue.record("recording failed: \(error)")
        }
        #expect(recorder.state == .idle)
        try? FileManager.default.removeItem(at: url)
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func startWhileRecordingThrowsAlreadyRecording() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            Issue.record("no displays available to record"); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let dims = RecordingDimensions.display(pointWidth: 640, pointHeight: 360, scale: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let recorder = ScreenRecorder()
        try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                 codec: .h264, outputURL: url) { _ in }
        await #expect(throws: RecordingError.alreadyRecording) {
            try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                     codec: .h264, outputURL: url) { _ in }
        }
        await recorder.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS on the Mac (Screen Recording granted) — both live tests exercise a real 1-second recording and the `alreadyRecording` guard. Self-skip (reported as skipped, not failed) if permission isn't granted or in CI.

- [ ] **Step 7: Commit**

```bash
git add Sources/SXRecord/ScreenRecorder.swift Tests/SXRecordTests/ScreenRecorderTests.swift
git commit -m "Add ScreenRecorder with a concurrency-hardened SCK delegate shim"
```

---
### Task 5: GifConverter (native)

**Files:**
- Create: `Sources/SXRecord/GifConverter.swift`
- Test: Create `Tests/SXRecordTests/GifConverterTests.swift`

**Interfaces:**
- Consumes: `RecordingError` (Task 2).
- Produces:
  - `public enum GifConverter` with `public struct Options: Sendable { fps: Int; maxWidth: Int? }`.
  - `public static func frameTimes(duration: Double, fps: Int) -> [Double]` — pure, evenly-spaced sample times, always ≥1 frame.
  - `public static func convert(videoURL: URL, to gifURL: URL, options: Options) async throws` — `AVAssetImageGenerator` frames → `CGImageDestination` animated GIF (loop forever), throwing `RecordingError.conversionFailed(_:)` on any failure.

- [ ] **Step 1: Write the failing frameTimes tests**

Create `Tests/SXRecordTests/GifConverterTests.swift`:

```swift
import Foundation
import Testing
@testable import SXRecord

@Suite struct GifConverterFrameTimesTests {
    @Test func evenlySpacedSamplesAtTheRequestedFPS() {
        let times = GifConverter.frameTimes(duration: 2.0, fps: 15)
        #expect(times.count == 30)
        #expect(times.first == 0.0)
        #expect(times == times.sorted())              // monotonic
        #expect(times.allSatisfy { $0 < 2.0 })         // never reaches/exceeds duration
    }

    @Test func zeroDurationYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: 0, fps: 15) == [0])
    }

    @Test func zeroFPSYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: 5, fps: 0) == [0])
    }

    @Test func negativeDurationYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: -1, fps: 15) == [0])
    }

    @Test func lowFPSStillProducesAtLeastOneFrame() {
        let times = GifConverter.frameTimes(duration: 0.1, fps: 1)
        #expect(times.count >= 1)
        #expect(times.first == 0.0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `GifConverter` does not exist yet, so `GifConverterTests.swift` fails to compile.

- [ ] **Step 3: Implement GifConverter**

Create `Sources/SXRecord/GifConverter.swift`:

```swift
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Native mp4/mov -> animated GIF conversion. No external dependency; the
/// optional higher-quality ffmpeg path (Task 15) is never required — this is
/// always the fallback and the only path CI exercises.
public enum GifConverter {
    public struct Options: Sendable {
        public let fps: Int
        public let maxWidth: Int?   // px; nil = source width
        public init(fps: Int, maxWidth: Int?) { self.fps = fps; self.maxWidth = maxWidth }
    }

    /// Pure, testable: evenly-spaced sample times (seconds) for `duration` at `fps` (>=1 frame).
    public static func frameTimes(duration: Double, fps: Int) -> [Double] {
        guard duration > 0, fps > 0 else { return [0] }
        let count = max(1, Int((duration * Double(fps)).rounded(.down)))
        let step = duration / Double(count)
        return (0..<count).map { Double($0) * step }
    }

    /// Convert an mp4/mov to an animated GIF (loop forever) via AVAssetImageGenerator -> CGImageDestination.
    public static func convert(videoURL: URL, to gifURL: URL, options: Options) async throws {
        let asset = AVURLAsset(url: videoURL)
        let seconds = try await asset.load(.duration).seconds
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxWidth = options.maxWidth {
            generator.maximumSize = CGSize(width: maxWidth, height: 0)   // 0 = keep aspect
        }

        let times = frameTimes(duration: duration, fps: options.fps)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw RecordingError.conversionFailed("Could not create GIF destination at \(gifURL.path)") }

        let gifProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        let frameDelay = 1.0 / Double(options.fps > 0 ? options.fps : 15)
        let frameProperties = [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: frameDelay]] as CFDictionary

        for time in times {
            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                throw RecordingError.conversionFailed(
                    "Frame generation failed at \(time.seconds)s: \(error.localizedDescription)")
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw RecordingError.conversionFailed("Could not finalize GIF at \(gifURL.path)")
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `GifConverterFrameTimesTests`.

- [ ] **Step 5: Add a live conversion test (no TCC gate needed — synthesizes its own mp4 via AVAssetWriter)**

Append to `Tests/SXRecordTests/GifConverterTests.swift`:

```swift
import ImageIO
import CoreVideo

@Suite struct GifConverterLiveTests {
    /// Writes a 1-second, 4x4, alternating-color H.264 mp4 via AVAssetWriter —
    /// enough signal for AVAssetImageGenerator to sample frames from, without
    /// needing ScreenCaptureKit or the Screen Recording TCC grant. This test
    /// therefore runs unconditionally (no `.enabled(if:)` gate) — it is not an
    /// SCK live test, just plain AVFoundation, so CI gets real GIF-pixel coverage.
    private func makeTinyMP4() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 4,
            AVVideoHeightKey: 4,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<8 {
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { break }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame % 2 == 0 ? 0 : 255, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 8))
        }
        input.markAsFinished()
        await writer.finishWriting()   // VERIFY on Mac: async finishWriting() overload requires macOS 15+ (matches our floor).
        return url
    }

    @Test func convertsAShortClipToANonEmptyAnimatedGIF() async throws {
        let mp4 = try await makeTinyMP4()
        defer { try? FileManager.default.removeItem(at: mp4) }
        let gifURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        try await GifConverter.convert(videoURL: mp4, to: gifURL,
                                       options: .init(fps: 4, maxWidth: nil))

        #expect(FileManager.default.fileExists(atPath: gifURL.path))
        let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil)
        #expect(source != nil)
        if let source { #expect(CGImageSourceGetCount(source) > 1) }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — `convertsAShortClipToANonEmptyAnimatedGIF` runs unconditionally (both locally and in CI, since it needs no TCC grant) and asserts a real multi-frame GIF was produced.

- [ ] **Step 7: Commit**

```bash
git add Sources/SXRecord/GifConverter.swift Tests/SXRecordTests/GifConverterTests.swift
git commit -m "Add native GifConverter (AVAssetImageGenerator -> animated GIF)"
```

---
### Task 6: MIMEType helper + UploadService generalization

**Files:**
- Create: `Sources/SXCore/MIMEType.swift`
- Modify: `Sources/SXApp/UploadService.swift`
- Test: Create `Tests/SXCoreTests/MIMETypeTests.swift`
- Test: Create `Tests/SXUploadTests/UploaderMimeTests.swift`

**Interfaces:**
- Consumes: `FilePart`, `Uploader`, `UploadResult`, `UploadDestination`, `CustomUploaderConfig`, `RequestBodyEncoder` (existing, M2).
- Produces:
  - `public enum MIMEType { public static func forExtension(_ ext: String) -> String }` — `png`→`image/png`, `gif`→`image/gif`, `mp4`→`video/mp4`, unknown→`application/octet-stream`. (`isVideo(path:)` is added to this same enum in Task 13.)
  - `UploadService.upload(data: Data, filename: String, mime: String, destination: UploadDestination) async throws -> UploadResult` — generalizes the still-image-only path so recordings (mp4) and derived GIFs can reuse the same upload plumbing. This is **purely additive**: the existing `static func filePart(pngData:filename:)` and the shipped PNG still-path (`CaptureCoordinator.recordAndMaybeUpload`, which keeps calling `filePart(pngData:)` + `uploader(for:).upload(_:)`) are left untouched — nothing is removed. The SXUpload `Uploader` protocol already takes a `FilePart` carrying an arbitrary `mimeType`, so no SXUpload source change is needed; the multipart encoder already writes `Content-Type: <FilePart.mimeType>`. `UploadService` (SXApp) stays thin glue exercised via the injected closure in Task 7's SXCore ordering test — it gets no SXApp test target of its own.

- [ ] **Step 1: Write the failing MIMEType + mime-passthrough tests**

Create `Tests/SXCoreTests/MIMETypeTests.swift`:

```swift
import Testing
@testable import SXCore

@Suite struct MIMETypeTests {
    @Test func mapsKnownExtensions() {
        #expect(MIMEType.forExtension("png") == "image/png")
        #expect(MIMEType.forExtension("PNG") == "image/png")
        #expect(MIMEType.forExtension("gif") == "image/gif")
        #expect(MIMEType.forExtension("mp4") == "video/mp4")
    }

    @Test func unknownExtensionFallsBackToOctetStream() {
        #expect(MIMEType.forExtension("xyz") == "application/octet-stream")
        #expect(MIMEType.forExtension("") == "application/octet-stream")
    }
}
```

Create `Tests/SXUploadTests/UploaderMimeTests.swift` — proves the SXUpload layer honors a non-PNG mime end-to-end (the multipart body carries `Content-Type: video/mp4`), so a recording upload isn't silently relabeled as an image:

```swift
import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

private struct CapturingHTTP: HTTPClient {
    let response: HTTPResponse
    let capture: @Sendable (PreparedRequest) -> Void
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        capture(request); return response
    }
}

@Suite struct UploaderMimeTests {
    @Test func customUploaderMultipartCarriesTheFilePartMime() async throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.fileFormName = "file"
        config.url = "{json:link}"
        var captured: PreparedRequest?
        let http = CapturingHTTP(
            response: HTTPResponse(status: 200, headers: [:], body: Data(#"{"link":"https://i/x"}"#.utf8)),
            capture: { captured = $0 })
        let client = CustomUploaderClient(config: config, http: http, boundaryProvider: { "BOUND" })

        let file = FilePart(fieldName: "file", filename: "clip.mp4",
                            mimeType: "video/mp4", data: Data([0, 1, 2, 3]))
        _ = try await client.upload(file)

        let body = try #require(captured?.body)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("Content-Type: video/mp4"))
        #expect(text.contains(#"filename="clip.mp4""#))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `MIMEType` does not exist yet, so `MIMETypeTests.swift` fails to compile. (`UploaderMimeTests` compiles against existing SXUpload/SXCore types but is grouped here so the whole mime story lands in one task.)

- [ ] **Step 3: Add MIMEType and generalize UploadService**

Create `Sources/SXCore/MIMEType.swift`:

```swift
import Foundation

/// Maps a filename extension to the MIME type used for uploads. Unknown
/// extensions fall back to "application/octet-stream" (never a silent guess
/// at a more specific type).
public enum MIMEType {
    public static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
```

In `Sources/SXApp/UploadService.swift`, add a generalized `filePart`/`upload` pair alongside the existing PNG-only `filePart(pngData:filename:)` (which Task 7 will remove once its one call site migrates):

```swift
import Foundation
import SXCore
import SXUpload

struct UploadService {
    private let http: HTTPClient
    private let credentials: CredentialStore

    init(http: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore) {
        self.http = http
        self.credentials = credentials
    }

    static func filePart(pngData: Data, filename: String) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: "image/png", data: pngData)
    }

    static func filePart(data: Data, filename: String, mime: String) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: mime, data: data)
    }

    func uploader(for destination: UploadDestination) throws -> Uploader {
        switch destination.kind {
        case .imgur:
            let clientID = destination.imgurClientID ?? ""
            guard !clientID.isEmpty else {
                throw UploadError.missingCredential("Imgur client ID not set")
            }
            return ImgurUploader(clientID: clientID, http: http)

        case .customUploader:
            guard let config = destination.customUploader else {
                throw UploadError.unsupported("Destination has no custom-uploader config")
            }
            // Re-hydrate every stripped secret (headers/arguments/parameters/data)
            // from the Keychain immediately before building the request.
            let injected = try SecretVault.inject(config, id: destination.id, from: credentials)
            return CustomUploaderClient(config: injected, http: http)

        case .s3:
            guard let config = destination.s3Config else {
                throw UploadError.unsupported("Destination has no S3 config")
            }
            let creds = try S3Credentials.load(id: destination.id, from: credentials)
            return S3Uploader(config: config, credentials: creds, http: http)
        }
    }

    /// Resolves the uploader for `destination` and uploads `data`. Generalizes
    /// the PNG-only `filePart(pngData:filename:)` path so recordings (mp4) and
    /// derived GIFs can reuse the same upload plumbing as stills.
    func upload(data: Data, filename: String, mime: String,
               destination: UploadDestination) async throws -> UploadResult {
        let uploader = try uploader(for: destination)
        let file = Self.filePart(data: data, filename: filename, mime: mime)
        return try await uploader.upload(file)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `MIMETypeTests` and `UploaderMimeTests`; `scripts/remote.sh build` still succeeds (the additive `UploadService` methods don't change any existing call site, so `CaptureCoordinator` keeps compiling unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/MIMEType.swift Sources/SXApp/UploadService.swift Tests/SXCoreTests/MIMETypeTests.swift Tests/SXUploadTests/UploaderMimeTests.swift
git commit -m "Add MIMEType helper and generalize UploadService for non-PNG uploads"
```

---
### Task 7: File-based delivery in CaptureCoordinator

**Files:**
- Create: `Sources/SXCore/RecordingDelivery.swift` (the testable delivery core — lives in SXCore, NOT SXApp)
- Modify: `Sources/SXApp/CaptureCoordinator.swift` (add `deliverRecording` glue only)
- Test: Create `Tests/SXCoreTests/RecordingDeliveryTests.swift`

**Interfaces:**
- Consumes: `MIMEType.forExtension(_:)` (Task 6), `UploadService.upload(data:filename:mime:destination:)` (Task 6, in the SXApp glue only); `HistoryEntry`, `HistoryStore`, `PipelineEffects`, `AppSettings`, `UploadError` (existing, M2/M3).
- Produces:
  - SXCore: `public struct DeliveredUpload: Sendable { let url: String; let deletionURL: String? }` — the upload result decoupled from SXUpload's `UploadResult`, so this SXCore-level core takes no SXUpload dependency.
  - SXCore: `@MainActor public static func RecordingDelivery.deliver(fileURL:capturedAt:destinationName:shouldUpload:showNotification:mime:history:effects:upload:) async` — inserts the history row FIRST (file already on disk = local-first satisfied), then, only when `shouldUpload`, reads the file and awaits the injected `upload` closure, finalizing the row with the result. On upload failure the row REMAINS with `uploadFailed = true` and the file is never touched. It is `async` (awaits the upload inline) so callers/tests await completion deterministically rather than racing a detached Task.
  - SXApp: `CaptureCoordinator.deliverRecording(fileURL: URL, appName: String?)` — thin glue: reloads settings, computes `mime` via `MIMEType`, resolves the active destination, adapts `UploadService.upload(...) -> UploadResult` into a `(Data, String, String) async throws -> DeliveredUpload` closure, logs `"Recording saved: …"` via `AppLog`, and wraps the SXCore `deliver` call in its own `Task { @MainActor in … }`. It does **not** route through `AfterCapturePipeline` (no re-encode, no PNG) and does **not** change `CaptureCoordinator`'s existing `effects: AppPipelineEffects` stored property or the shipped PNG still-path (`recordAndMaybeUpload`), which is left exactly as M3b shipped.

Design note — **why the delivery core lives in SXCore, not SXApp:** `CaptureCoordinator` lives in the `SXApp` `.executableTarget`, which contains top-level code (`Sources/SXApp/main.swift`). A test target **cannot** `@testable import` an executable with a `main`, so there is no way to unit-test `CaptureCoordinator` directly, and splitting SXApp into a thin `main` + library would rename the binary and break `scripts/bundle.sh` / `Info.plist` / `scripts/remote.sh`'s `pkill` patterns (out of scope for M4). The load-bearing ordering + local-first + fail-loud guarantee this task must prove is therefore hoisted into a pure SXCore function, `RecordingDelivery.deliver`, unit-tested in `SXCoreTests` with the existing `MockEffects` (from `Tests/SXCoreTests/AfterCapturePipelineTests.swift`), a real temp-file `HistoryStore` (SXCore, opens a throwaway SQLite DB), and an **injected `upload` closure** (a success variant and a throwing variant) — no live network, no `UNUserNotificationCenter`, no bundle context. `CaptureCoordinator.deliverRecording` stays thin glue exercised only by the Mac Smoke Checklist.

Design note — **why `deliver` is `async` (deterministic ordering, not a flaky detached Task):** because `deliver` awaits the injected `upload` inline, the SXCore test can `await RecordingDelivery.deliver(...)` and assert the full sequence with zero polling/sleeps: the history row is inserted **before** the upload closure is invoked (the closure reads the store and finds the row already present), and on the closure's success/throw the row is updated / left `uploadFailed = true`. The mock's `callOrder` never contains `"write"` for a recording delivery — the test asserts that explicitly as proof no re-encode happened (`SCRecordingOutput` already wrote the file; delivery only reads it). SXCore has no `AppLog` (that is SXApp-only, per the contract), so a history-store insert/update failure inside `deliver` is best-effort `try?` — the durable artifact is the on-disk file, never the row; the file and the fail-loud `effects.notify(...)` are what carry the invariant.

- [ ] **Step 1: Write the failing SXCore delivery tests**

Create `Tests/SXCoreTests/RecordingDeliveryTests.swift` (reuses the existing `MockEffects` from `Tests/SXCoreTests/AfterCapturePipelineTests.swift` — same test module, `MockEffects` is internal — with a real temp-file `HistoryStore` and an injected `upload` closure):

```swift
import Foundation
import Testing
@testable import SXCore

private func tempHistoryStore() throws -> HistoryStore {
    try HistoryStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite"))
}

private func tempFile(bytes: [UInt8] = [0, 1, 2, 3]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    try Data(bytes).write(to: url)   // stand-in bytes; delivery treats the file as opaque
    return url
}

private struct Boom: Error {}

@MainActor @Suite struct RecordingDeliveryTests {
    @Test func insertsHistoryRowBeforeInvokingTheUploadClosure() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        var rowPresentWhenUploadRan = false
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in
                // The upload runs AFTER the row is inserted (local-first ordering).
                rowPresentWhenUploadRan = ((try? history.recent(limit: 1))?.isEmpty == false)
                return DeliveredUpload(url: "https://i/x.mp4", deletionURL: "https://i/del")
            })
        #expect(rowPresentWhenUploadRan)
    }

    @Test func successUpdatesRowCopiesUrlAndNotifiesWithoutReencoding() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in DeliveredUpload(url: "https://i/x.mp4", deletionURL: "https://i/del") })
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.url == "https://i/x.mp4")
        #expect(rows.first?.deletionURL == "https://i/del")
        #expect(rows.first?.uploadFailed == false)
        #expect(effects.textCopies == ["https://i/x.mp4"])
        #expect(effects.callOrder.contains("copyText"))
        #expect(effects.callOrder.contains("notifyURL"))
        #expect(!effects.callOrder.contains("write"))   // no re-encode; SCRecordingOutput already wrote the file
    }

    @Test func failureKeepsRowWithUploadFailedAndNeverTouchesTheFile() async throws {
        let fileURL = try tempFile()
        let before = try Data(contentsOf: fileURL)
        let history = try tempHistoryStore()
        let effects = MockEffects()
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in throw Boom() })
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.filePath == fileURL.path)     // row remains
        #expect(rows.first?.uploadFailed == true)
        #expect(rows.first?.url == nil)
        #expect(effects.notifications.contains { $0.0.contains("Local file kept") })   // fail-loud
        #expect(FileManager.default.fileExists(atPath: fileURL.path))   // local-first: file untouched
        #expect(try Data(contentsOf: fileURL) == before)
    }

    @Test func noUploadNotifiesRecordingSavedAndSkipsTheUploadClosure() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        var uploadRan = false
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: nil,
            shouldUpload: false, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in uploadRan = true; return DeliveredUpload(url: "x", deletionURL: nil) })
        #expect(!uploadRan)
        #expect(effects.callOrder == ["notify"])
        #expect(effects.notifications.first?.0 == fileURL.lastPathComponent)
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.filePath == fileURL.path)
        #expect(rows.first?.url == nil)
        #expect(rows.first?.uploadFailed == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `RecordingDelivery` / `DeliveredUpload` do not exist yet, so `RecordingDeliveryTests.swift` fails to compile.

- [ ] **Step 3: Add the SXCore delivery core and the SXApp glue**

Create `Sources/SXCore/RecordingDelivery.swift`:

```swift
import Foundation

/// The URL(s) a successful upload produced, decoupled from SXUpload's
/// `UploadResult` so this SXCore-level delivery core takes no SXUpload dependency.
public struct DeliveredUpload: Sendable {
    public let url: String
    public let deletionURL: String?
    public init(url: String, deletionURL: String?) {
        self.url = url
        self.deletionURL = deletionURL
    }
}

/// Library-level delivery core for an already-on-disk artifact (a recording's
/// mp4, or a derived gif). Lives in SXCore — NOT SXApp — because SXApp is an
/// executable target with top-level code (`main.swift`) that a test target
/// cannot `@testable import`; hoisting the ordering here makes it unit-testable
/// in SXCoreTests with a `PipelineEffects` mock, a temp-file `HistoryStore`,
/// and an injected `upload` closure.
public enum RecordingDelivery {
    /// Records the history row FIRST (the file is already on disk = local-first
    /// satisfied), then — only when `shouldUpload` — reads the file and awaits
    /// `upload`, finalizing the row with the result. On upload failure the row
    /// REMAINS with `uploadFailed = true` and the file is never touched.
    /// `async` (awaits the upload inline) so callers/tests can await completion
    /// deterministically instead of racing a detached Task.
    @MainActor
    public static func deliver(
        fileURL: URL,
        capturedAt: Date,
        destinationName: String?,
        shouldUpload: Bool,
        showNotification: Bool,
        mime: String,
        history: HistoryStore?,
        effects: any PipelineEffects,
        upload: @escaping (Data, String, String) async throws -> DeliveredUpload
    ) async {
        let entryID = UUID().uuidString
        // History row first: the artifact is already on disk, so recording the
        // row before any upload preserves local-first. Best-effort — SXCore has
        // no AppLog and the durable artifact is the file, not the row, so a
        // store failure never blocks or discards the on-disk recording.
        if let history {
            let entry = HistoryEntry(id: entryID, capturedAt: capturedAt,
                                     filePath: fileURL.path, url: nil, deletionURL: nil,
                                     destinationName: shouldUpload ? destinationName : nil,
                                     uploadFailed: false)
            try? history.insert(entry)
        }

        guard shouldUpload else {
            if showNotification {
                effects.notify(title: "Recording saved", body: fileURL.lastPathComponent, fileURL: fileURL)
            }
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let result = try await upload(data, fileURL.lastPathComponent, mime)
            effects.copyTextToClipboard(result.url)
            effects.notifyURL(title: "Uploaded", body: result.url, url: result.url)
            try? history?.setURL(id: entryID, url: result.url, deletionURL: result.deletionURL, failed: false)
        } catch {
            // Fail-loud: surface the failure; the row + file remain (local-first).
            effects.notify(title: "Upload failed", body: "\(error). Local file kept.", fileURL: fileURL)
            try? history?.setURL(id: entryID, url: nil, deletionURL: nil, failed: true)
        }
    }
}
```

In `Sources/SXApp/CaptureCoordinator.swift`, add `deliverRecording` (leave the stored `effects: AppPipelineEffects` property, the initializer, and the shipped PNG-still path `recordAndMaybeUpload`/`finishPersist` exactly as M3b shipped — do NOT widen `effects`):

```swift
    /// Delivers an already-on-disk recording (mp4): the testable ordering /
    /// local-first / fail-loud logic lives in `RecordingDelivery.deliver`
    /// (SXCore, unit-tested there); this is thin glue that reloads settings,
    /// resolves the mime + active destination, adapts `UploadService.upload`
    /// into a `DeliveredUpload` closure, and awaits delivery on a MainActor
    /// Task. `SCRecordingOutput` already wrote the file, so local-first holds
    /// without a re-encode (this never routes through `AfterCapturePipeline`).
    /// `appName` is accepted for parity with the still-image path (future
    /// history metadata); `HistoryEntry` has no app-name column today.
    func deliverRecording(fileURL: URL, appName: String?) {
        let settings = settingsStore.loadOrDefault().0
        AppLog.log("Recording saved: \(fileURL.path)")
        let destination = settings.upload.activeDestination
        let shouldUpload = settings.upload.uploadAfterCapture && destination != nil
        let mime = MIMEType.forExtension(fileURL.pathExtension)
        let service = uploadService
        Task { @MainActor in
            await RecordingDelivery.deliver(
                fileURL: fileURL,
                capturedAt: Date(),
                destinationName: destination?.name,
                shouldUpload: shouldUpload,
                showNotification: settings.showNotification,
                mime: mime,
                history: historyStore,
                effects: effects,
                upload: { data, filename, mime in
                    guard let destination else { throw UploadError.unsupported("No active destination") }
                    let result = try await service.upload(data: data, filename: filename,
                                                          mime: mime, destination: destination)
                    return DeliveredUpload(url: result.url, deletionURL: result.deletionURL)
                })
        }
    }
```

(`effects` here is the shipped concrete `AppPipelineEffects`, which already conforms to `PipelineEffects` — so it passes into `deliver`'s `effects: any PipelineEffects` parameter with no property/initializer change. `UploadError` and `DeliveredUpload` are SXCore types already visible via `import SXCore`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all four `RecordingDeliveryTests`, and every pre-existing suite (the PNG-still path and `AfterCapturePipeline` are untouched; `CaptureCoordinator` only gains `deliverRecording`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/RecordingDelivery.swift Sources/SXApp/CaptureCoordinator.swift Tests/SXCoreTests/RecordingDeliveryTests.swift
git commit -m "Add recording delivery core in SXCore with ordering and local-first tests"
```

---
### Task 8: RecordingRegionSession (rect-returning overlay)

**Files:**
- Modify: `Sources/SXApp/RegionOverlay.swift` (drop `private` from `KeyableWindow` and `RegionSelectionView` so `RecordingRegionSession` can reuse them — DRY: no duplicated overlay-window/crosshair/loupe code)
- Create: `Sources/SXApp/RecordingRegionSession.swift`
- Test: build only (no existing overlay session — `RegionOverlaySession`, `WindowPickerSession` — has automated coverage either; this follows the established convention of a Mac smoke checklist for interactive borderless-window UX). See the Mac Smoke Checklist at the end of this plan.

**Interfaces:**
- Consumes: `FrozenDisplay` (`SXCapture`, M1), `RegionSelectionView`/`KeyableWindow` (`SXApp`, M1 — access widened by this task), `CaptureGeometry.normalizedRect` (used internally by `RegionSelectionView`, unchanged).
- Produces: `@MainActor final class RecordingRegionSession { init(displays: [FrozenDisplay], onComplete: @escaping @MainActor ((display: FrozenDisplay, rect: CGRect)?) -> Void); func begin() }` — parallel to `RegionOverlaySession`, but returns the selected display + the raw selection rect (view points, top-left origin) instead of a cropped image, since Task 9 needs the *live* display to build an `SCContentFilter`, not a frozen pixel crop.

- [ ] **Step 1: Widen access on the two AppKit helpers RecordingRegionSession reuses**

In `Sources/SXApp/RegionOverlay.swift`, change:

```swift
private final class KeyableWindow: NSWindow {
```

to:

```swift
final class KeyableWindow: NSWindow {
```

and change:

```swift
private final class RegionSelectionView: NSView {
```

to:

```swift
final class RegionSelectionView: NSView {
```

(Both remain `internal` — visible within `SXApp`, not `public` — so this is a same-module reuse, not a new public API surface.)

- [ ] **Step 2: Add RecordingRegionSession**

Create `Sources/SXApp/RecordingRegionSession.swift`:

```swift
import AppKit
import SXCapture

/// Parallel to `RegionOverlaySession`, but for recording: returns the selected
/// display + the raw selection rect (view points, top-left origin) instead of
/// a cropped image, since the caller needs the live display to build an
/// `SCContentFilter` for an in-progress `SCStream`, not a frozen pixel crop.
/// Reuses `RegionSelectionView`/`KeyableWindow` (widened to internal above).
@MainActor
final class RecordingRegionSession {
    private var windows: [NSWindow] = []
    private let displays: [FrozenDisplay]
    private let onComplete: @MainActor ((display: FrozenDisplay, rect: CGRect)?) -> Void
    private var finished = false

    init(displays: [FrozenDisplay],
        onComplete: @escaping @MainActor ((display: FrozenDisplay, rect: CGRect)?) -> Void) {
        self.displays = displays
        self.onComplete = onComplete
    }

    func begin() {
        // Activate first so the borderless overlay reliably takes keyboard focus
        // (background LSUIElement app; without this the first invocation can show
        // an unfocused overlay that ignores Escape). Same as RegionOverlaySession.
        NSApp.activate(ignoringOtherApps: true)
        for display in displays {
            let window = KeyableWindow(contentRect: display.screenFrame,
                                       styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = RegionSelectionView(display: display) { [weak self] selection in
                self?.finish(display: display, selection: selection)
            }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSCursor.crosshair.set()
    }

    /// selection is in view points (top-left origin); nil = cancelled.
    private func finish(display: FrozenDisplay, selection: CGRect?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        guard let selection else { onComplete(nil); return }
        onComplete((display: display, rect: selection))
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `scripts/remote.sh build`
Expected: `Build complete!` (no new errors or warnings).

- [ ] **Step 4: Commit**

```bash
git add Sources/SXApp/RegionOverlay.swift Sources/SXApp/RecordingRegionSession.swift
git commit -m "Add RecordingRegionSession, a rect-returning region overlay for recording"
```

---
### Task 9: RecordingCoordinator (orchestration)

**Files:**
- Modify: `Sources/SXCapture/WindowCapture.swift` (`backingScale(forCGGlobalFrame:)` made `public` — reused for window-recording dimension scale instead of duplicating the algorithm)
- Modify: `Sources/SXCore/RecordingDelivery.swift` (add the pure `outputURL` path helper — SXApp can't host a testable static, so the filename resolution lives in SXCore beside the delivery core)
- Create: `Sources/SXApp/RecordingCoordinator.swift`
- Test: Create `Tests/SXCoreTests/RecordingOutputURLTests.swift` (the pure filename-resolution slice, testing `RecordingDelivery.outputURL`); the mode-resolution/SCK-orchestration methods in `RecordingCoordinator` are build-only + Mac smoke checklist, matching this codebase's established convention for AppKit/SCK-live orchestration (`CaptureCoordinator`'s own capture methods have never had automated coverage either — and, being in the executable target, cannot).

**Interfaces:**
- Consumes: `ScreenRecorder`, `RecordingDimensions`, `RecordingError` (`SXRecord`, Tasks 2/4); `DisplayCapture.{captureAllDisplays,shareableContent,scDisplay}`, `WindowCapture.{candidates,scWindow,backingScale(forCGGlobalFrame:)}`, `CaptureGeometry`, `FrozenDisplay`, `WindowCandidate` (`SXCapture`, Task 3 + M1); `RecordingRegionSession` (Task 8), `WindowPickerSession` (M1), `PermissionOnboardingController.ensurePermission()` (M1); `SettingsStore`, `AppSettings`, `NameParser`, `NameContext`, `PipelineEffects` (`SXCore`).
- Produces:
  - `@MainActor final class RecordingCoordinator { enum Mode { case region, window, display } }`
  - `init(recorder: ScreenRecorder, settingsStore: SettingsStore, effects: any PipelineEffects, deliver: @escaping @MainActor (URL, String?) -> Void, onStateChange: @escaping @MainActor (Bool) -> Void)` — the architecture contract's own prose ("prefer the closure to avoid a hard coupling") settles an inconsistency in its own init sketch (which listed `uploadService`/`historyStore` params unused by any described behavior): `RecordingCoordinator` never touches upload/history directly, it hands a finished file to `deliver`, so `uploadService`/`historyStore` are dropped from its init and `deliver` is added, matching every behavior actually described. `AppDelegate` (Task 14) wires `deliver` to `captureCoordinator.deliverRecording(fileURL:appName:)`.
  - `var isRecording: Bool { get }`, `func toggle(mode: Mode)`, `func start(mode: Mode)`, `func stop()`.
  - SXCore: `static func RecordingDelivery.outputURL(settings: AppSettings, capturedAt: Date, appName: String?, fileExists: (URL) -> Bool = ...) -> URL` — pure, unit-testable in SXCoreTests: capture-save directory + the same `NameParser` template used for stills, `.mp4` extension, numeric-suffix collision handling. `RecordingCoordinator.beginRecording` (SXApp) calls it; it is NOT a `RecordingCoordinator` static (that would be untestable in the executable target).

- [ ] **Step 1: Widen backingScale so RecordingCoordinator can reuse it**

In `Sources/SXCapture/WindowCapture.swift`, change:

```swift
/// Backing scale of the screen most overlapping the given CG-global rect
/// (top-left origin), converting to AppKit coords for the comparison.
@MainActor
private func backingScale(forCGGlobalFrame frame: CGRect) -> CGFloat {
```

to:

```swift
/// Backing scale of the screen most overlapping the given CG-global rect
/// (top-left origin), converting to AppKit coords for the comparison. Public
/// so window recording (SXApp) can compute the same dimension scale as
/// window stills without duplicating this algorithm.
@MainActor
public func backingScale(forCGGlobalFrame frame: CGRect) -> CGFloat {
```

- [ ] **Step 2: Write the failing pure outputURL tests**

Create `Tests/SXCoreTests/RecordingOutputURLTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct RecordingOutputURLTests {
    private func settings(template: String = "Recording_%y-%mo-%d_%h-%mi-%s") -> AppSettings {
        var s = AppSettings.default
        s.captureSavePath = "/tmp/sxrectest"
        s.filenameTemplate = template
        return s
    }

    private func date() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return DateComponents(calendar: cal, year: 2026, month: 7, day: 12,
                              hour: 10, minute: 30, second: 0).date!
    }

    @Test func rendersTheTemplateWithAnMp4Extension() {
        let url = RecordingDelivery.outputURL(settings: settings(), capturedAt: date(),
                                              appName: "Safari", fileExists: { _ in false })
        #expect(url.path == "/tmp/sxrectest/Recording_2026-07-12_10-30-00.mp4")
    }

    @Test func appendsANumericSuffixOnCollision() {
        let seen: Set<String> = ["/tmp/sxrectest/Recording_2026-07-12_10-30-00.mp4"]
        let url = RecordingDelivery.outputURL(settings: settings(), capturedAt: date(),
                                              appName: nil, fileExists: { seen.contains($0.path) })
        #expect(url.path == "/tmp/sxrectest/Recording_2026-07-12_10-30-00_1.mp4")
    }

    @Test func processNameTokenUsesTheAppNameArgument() {
        let url = RecordingDelivery.outputURL(settings: settings(template: "rec_%pn"),
                                              capturedAt: date(), appName: "Safari",
                                              fileExists: { _ in false })
        #expect(url.lastPathComponent == "rec_Safari.mp4")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `RecordingDelivery.outputURL` does not exist yet, so `RecordingOutputURLTests.swift` fails to compile.

- [ ] **Step 4: Add `RecordingDelivery.outputURL` (SXCore) and implement RecordingCoordinator (SXApp)**

Append the pure filename resolver to `Sources/SXCore/RecordingDelivery.swift` (a new `extension RecordingDelivery`, so it sits beside `deliver`):

```swift
extension RecordingDelivery {
    /// Resolves a recording's destination path: the capture-save directory +
    /// the same `NameParser` template used for stills, with a `.mp4` extension
    /// and numeric-suffix collision handling. Pure and static — unit-testable
    /// without SCK or real disk I/O (`fileExists` is injectable; production
    /// calls default to the real filesystem). Mirrors
    /// `AfterCapturePipeline.resolveCollisions`.
    public static func outputURL(
        settings: AppSettings, capturedAt: Date, appName: String?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
        let ctx = NameContext(date: capturedAt, width: nil, height: nil, processName: appName, increment: 0)
        let base = NameParser.sanitize(NameParser.render(settings.filenameTemplate, context: ctx))
        var url = dir.appendingPathComponent(base + ".mp4")
        var n = 1
        while fileExists(url) {
            url = dir.appendingPathComponent("\(base)_\(n).mp4")
            n += 1
        }
        return url
    }
}
```

Then create `Sources/SXApp/RecordingCoordinator.swift`:

Create `Sources/SXApp/RecordingCoordinator.swift`:

```swift
import AppKit
import AVFoundation
// @preconcurrency: see SXCapture/DisplayCapture.swift for why.
@preconcurrency import ScreenCaptureKit
import SXCapture
import SXCore
import SXRecord

@MainActor
final class RecordingCoordinator {
    enum Mode { case region, window, display }

    private let recorder: ScreenRecorder
    private let settingsStore: SettingsStore
    private let effects: any PipelineEffects
    private let deliver: @MainActor (URL, String?) -> Void
    private let onStateChange: @MainActor (Bool) -> Void
    private var isPresentingOverlay = false
    private var regionSession: RecordingRegionSession?
    private var windowSession: WindowPickerSession?

    init(recorder: ScreenRecorder, settingsStore: SettingsStore, effects: any PipelineEffects,
        deliver: @escaping @MainActor (URL, String?) -> Void,
        onStateChange: @escaping @MainActor (Bool) -> Void) {
        self.recorder = recorder
        self.settingsStore = settingsStore
        self.effects = effects
        self.deliver = deliver
        self.onStateChange = onStateChange
    }

    var isRecording: Bool { recorder.state == .recording }

    func toggle(mode: Mode) {
        if isRecording { stop() } else { start(mode: mode) }
    }

    func start(mode: Mode) {
        guard !isRecording, !isPresentingOverlay else { return }
        guard PermissionOnboardingController.ensurePermission() else {
            AppLog.log("Recording start aborted: Screen Recording not granted")
            return
        }
        switch mode {
        case .display: startDisplay()
        case .region: startRegion()
        case .window: startWindow()
        }
    }

    func stop() {
        guard isRecording else { return }
        Task { @MainActor in await recorder.stop() }
    }

    // MARK: - Display

    private func startDisplay() {
        isPresentingOverlay = true
        Task { @MainActor in
            defer { isPresentingOverlay = false }
            do {
                let content = try await DisplayCapture.shareableContent()
                guard let target = displayUnderMouse(in: content) ?? content.displays.first else {
                    AppLog.log("Recording: no displays available")
                    return
                }
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                        == target.displayID
                }
                let scale = screen?.backingScaleFactor ?? 2
                let pointSize = screen?.frame.size
                    ?? CGSize(width: CGFloat(target.width), height: CGFloat(target.height))
                let filter = SCContentFilter(display: target, excludingWindows: [])
                let dims = RecordingDimensions.display(pointWidth: pointSize.width,
                                                       pointHeight: pointSize.height, scale: scale)
                try await beginRecording(filter: filter, dimensions: dims, appName: nil)
            } catch {
                AppLog.log("Recording: display resolution failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    /// v1: the display containing the mouse cursor, so "Record Display" without
    /// a chooser does the least-surprising thing on a multi-monitor setup.
    private func displayUnderMouse(in content: SCShareableContent) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        guard let hovered = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let id = hovered.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return DisplayCapture.scDisplay(for: id, in: content)
    }

    // MARK: - Region

    private func startRegion() {
        isPresentingOverlay = true
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                let session = RecordingRegionSession(displays: displays) { [weak self] picked in
                    self?.regionSession = nil
                    self?.isPresentingOverlay = false
                    guard let self, let picked else {
                        AppLog.log("Region recording cancelled")
                        return
                    }
                    Task { @MainActor in await self.startRegionRecording(picked) }
                }
                self.regionSession = session
                session.begin()
            } catch {
                isPresentingOverlay = false
                AppLog.log("Recording: region overlay setup failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    private func startRegionRecording(_ picked: (display: FrozenDisplay, rect: CGRect)) async {
        do {
            let content = try await DisplayCapture.shareableContent()
            guard let scDisplay = DisplayCapture.scDisplay(for: picked.display.displayID, in: content) else {
                AppLog.log("Recording: display \(picked.display.displayID) no longer available")
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let dims = RecordingDimensions.region(rectInPoints: picked.rect, scale: picked.display.scale)
            try await beginRecording(filter: filter, dimensions: dims, appName: nil)
        } catch {
            AppLog.log("Recording: region start failed: \(error)")
            effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
        }
    }

    // MARK: - Window

    private func startWindow() {
        isPresentingOverlay = true
        Task { @MainActor in
            do {
                let candidates = try await WindowCapture.candidates(
                    excludingBundleID: Bundle.main.bundleIdentifier)
                guard !candidates.isEmpty else {
                    isPresentingOverlay = false
                    effects.notify(title: "No windows to record",
                                   body: "No capturable windows were found.", fileURL: nil)
                    return
                }
                let session = WindowPickerSession(candidates: candidates) { [weak self] pick in
                    self?.windowSession = nil
                    self?.isPresentingOverlay = false
                    guard let self, let pick else {
                        AppLog.log("Window recording cancelled")
                        return
                    }
                    Task { @MainActor in await self.startWindowRecording(pick) }
                }
                self.windowSession = session
                session.begin()
            } catch {
                isPresentingOverlay = false
                AppLog.log("Recording: window candidates failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    private func startWindowRecording(_ pick: WindowCandidate) async {
        do {
            let content = try await DisplayCapture.shareableContent()
            guard let scWindow = WindowCapture.scWindow(for: pick.windowID, in: content) else {
                AppLog.log("Recording: window \(pick.windowID) no longer available")
                return
            }
            let scale = backingScale(forCGGlobalFrame: pick.frame)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let dims = RecordingDimensions.window(pointWidth: pick.frame.width,
                                                  pointHeight: pick.frame.height, scale: scale)
            try await beginRecording(filter: filter, dimensions: dims, appName: pick.appName)
        } catch {
            AppLog.log("Recording: window start failed: \(error)")
            effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
        }
    }

    // MARK: - Shared start + output URL

    private func beginRecording(filter: SCContentFilter, dimensions: RecordingDimensions,
                                appName: String?) async throws {
        let settings = settingsStore.loadOrDefault().0
        let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = RecordingDelivery.outputURL(settings: settings, capturedAt: Date(), appName: appName)
        let codec: AVVideoCodecType = settings.recording.videoCodec == .hevc ? .hevc : .h264
        do {
            try await recorder.start(filter: filter, dimensions: dimensions,
                                     capturesAudio: settings.recording.systemAudio,
                                     codec: codec, outputURL: url) { [weak self] result in
                self?.onStateChange(false)
                switch result {
                case .success(let finishedURL):
                    AppLog.log("Recording saved: \(finishedURL.path)")
                    self?.deliver(finishedURL, appName)
                case .failure(let error):
                    AppLog.log("Recording failed: \(error)")
                    self?.effects.notify(title: "Recording failed",
                                         body: String(describing: error), fileURL: nil)
                }
            }
            onStateChange(true)
        } catch {
            AppLog.log("Recording start failed: \(error)")
            effects.notify(title: "Recording failed", body: "\(error)", fileURL: nil)
            throw error
        }
    }
}
```

(The recording's output path comes from `RecordingDelivery.outputURL` in SXCore, added above — `RecordingCoordinator` holds no untestable filename logic of its own.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `RecordingOutputURLTests`. `scripts/remote.sh build` succeeds (the SCK-orchestration methods are exercised only by the Mac smoke checklist, once Task 14 wires a live `RecordingCoordinator` into `AppDelegate`).

- [ ] **Step 6: Commit**

```bash
git add Sources/SXCapture/WindowCapture.swift Sources/SXCore/RecordingDelivery.swift Sources/SXApp/RecordingCoordinator.swift Tests/SXCoreTests/RecordingOutputURLTests.swift
git commit -m "Add RecordingCoordinator: region/window/display mode orchestration"
```

---
### Task 10: StatusItemController recording icon + elapsed title

**Files:**
- Modify: `Sources/SXApp/StatusItemController.swift`
- Test: build only (`StatusItemController` has never had automated coverage — it wraps a live `NSStatusItem` — plus a Mac smoke checklist entry, exercised once Task 14 wires it up).

**Interfaces:**
- Consumes: nothing new.
- Produces: `func setRecording(_ recording: Bool)` — swaps the menu-bar button image between `"camera.viewfinder"` (idle) and a red `"stop.circle.fill"` (recording); clears the title on return to idle. `func setTitle(_ s: String?)` — sets/clears the short elapsed-time label next to the icon (e.g. `" 0:07"`); Task 11 drives this from a 1s `Timer`.

- [ ] **Step 1: Add setRecording and setTitle**

Replace the whole `Sources/SXApp/StatusItemController.swift` with:

```swift
import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "ShareX for Mac")
        }
        statusItem.menu = menu
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    /// Swaps the menu-bar icon between idle (camera) and recording (red
    /// stop-circle) state. Clears the elapsed-time title on return to idle.
    func setRecording(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "ShareX for Mac")
            button.title = ""
        }
    }

    /// Elapsed-time label shown next to the recording icon (e.g. "0:07").
    /// Pass nil to clear it. Kept short per the design note in the spec.
    func setTitle(_ s: String?) {
        statusItem.button?.title = s.map { " \($0)" } ?? ""
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: `Build complete!` (no new errors or warnings).

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/StatusItemController.swift
git commit -m "Add recording icon and elapsed-time title to StatusItemController"
```

---
### Task 11: AppDelegate Record menu + elapsed-time patching

**Files:**
- Modify: `Sources/SXApp/AppDelegate.swift`
- Test: build only. Functional smoke-testing (menu items actually starting/stopping a recording) is deferred to Task 14's checklist entries, once `recordingCoordinator` is actually instantiated — this task only wires the menu/UI *logic* against the (still-nil-until-Task-14) `recordingCoordinator` property, matching how M3b staged UI wiring ahead of full instantiation.

**Interfaces:**
- Consumes: `RecordingCoordinator.{Mode, isRecording, toggle, stop}` (Task 9), `StatusItemController.{setRecording, setTitle}` (Task 10), `SettingsStore`, `AppSettings.recording.systemAudio` (Task 1).
- Produces: `AppDelegate.recordingCoordinator: RecordingCoordinator?` (assigned in Task 14), `updateRecordingUI(_ recording: Bool)` — the single handler `RecordingCoordinator`'s `onStateChange` will be wired to in Task 14: rebuilds the menu once on the state transition, starts/stops a 1s elapsed `Timer`, and drives `StatusItemController`. `tickElapsed(since:)` mutates the retained elapsed menu item + status title directly every second — it never calls `rebuildMenu()`, so a live recording doesn't tear down/rebuild the whole `NSMenu` once a second.

- [ ] **Step 1: Add the Record section to buildMenu, the new selectors, and the elapsed-time ticker**

In `Sources/SXApp/AppDelegate.swift`, add two stored properties alongside the existing ones (after `private let effects = AppPipelineEffects()`):

```swift
    private var recordingCoordinator: RecordingCoordinator?
    private var elapsedMenuItem: NSMenuItem?
    private var elapsedTimer: Timer?
```

Replace `buildMenu()` (the whole method) with:

```swift
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Capture Region", #selector(menuCaptureRegion)))
        menu.addItem(menuItem("Capture Window", #selector(menuCaptureWindow)))
        menu.addItem(menuItem("Capture Full Screen", #selector(menuCaptureFullscreen)))
        menu.addItem(.separator())
        buildRecordingItems(into: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Import .sxcu…", #selector(importSxcu)))
        menu.addItem(menuItem("Manage Destinations…", #selector(manageDestinations)))
        let uploadToggle = menuItem("Upload After Capture", #selector(toggleUploadAfterCapture))
        uploadToggle.state = currentUploadAfterCapture() ? .on : .off
        menu.addItem(uploadToggle)
        let annotateToggle = menuItem("Annotate Before Sharing", #selector(toggleAnnotateBeforeShare))
        annotateToggle.state = currentAnnotateBeforeShare() ? .on : .off
        menu.addItem(annotateToggle)
        menu.addItem(.separator())
        menu.addItem(menuItem("History…", #selector(showHistory)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    /// Adds the Record section: a "Start Recording" submenu (Region/Window/
    /// Display) while idle, or a "Stop Recording" item + a disabled elapsed-time
    /// item while recording, plus a "System Audio" toggle either way. Retains
    /// the elapsed item in `elapsedMenuItem` so the 1s Timer (`tickElapsed`) can
    /// mutate its title in place instead of tearing down the whole menu.
    private func buildRecordingItems(into menu: NSMenu) {
        let (settings, _) = SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault()
        if recordingCoordinator?.isRecording == true {
            menu.addItem(menuItem("Stop Recording", #selector(menuStopRecording)))
            let elapsed = NSMenuItem(title: "● 0:00", action: nil, keyEquivalent: "")
            elapsed.isEnabled = false
            elapsedMenuItem = elapsed
            menu.addItem(elapsed)
        } else {
            let start = NSMenuItem(title: "Start Recording", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(menuItem("Region", #selector(menuRecordRegion)))
            submenu.addItem(menuItem("Window", #selector(menuRecordWindow)))
            submenu.addItem(menuItem("Display", #selector(menuRecordDisplay)))
            start.submenu = submenu
            menu.addItem(start)
            elapsedMenuItem = nil
        }
        let audioToggle = menuItem("System Audio", #selector(toggleSystemAudio))
        audioToggle.state = settings.recording.systemAudio ? .on : .off
        menu.addItem(audioToggle)
    }

    @objc private func menuRecordRegion() { recordingCoordinator?.toggle(mode: .region) }
    @objc private func menuRecordWindow() { recordingCoordinator?.toggle(mode: .window) }
    @objc private func menuRecordDisplay() { recordingCoordinator?.toggle(mode: .display) }
    @objc private func menuStopRecording() { recordingCoordinator?.stop() }

    @objc private func toggleSystemAudio() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        var (settings, _) = store.loadOrDefault()
        settings.recording.systemAudio.toggle()
        do {
            try store.save(settings)
            AppLog.log("System audio recording: \(settings.recording.systemAudio)")
        } catch {
            AppLog.log("Failed to save system-audio toggle: \(error)")
        }
        rebuildMenu()
    }

    /// The single `onStateChange` handler for `RecordingCoordinator` (wired in
    /// Task 14): rebuilds the menu once, on the idle<->recording transition
    /// (to swap Start/Stop), and starts/stops the 1s elapsed ticker.
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

    /// Mutates the retained elapsed-time views directly — never calls
    /// `rebuildMenu()` here, so a live recording doesn't tear down/rebuild the
    /// whole NSMenu once a second.
    private func tickElapsed(since start: Date) {
        let seconds = Int(Date().timeIntervalSince(start))
        let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
        elapsedMenuItem?.title = "● \(label)"
        statusItem?.setTitle(label)
    }
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: `Build complete!` (no new errors or warnings — `recordingCoordinator` is a valid, always-nil-until-Task-14 optional, so `buildRecordingItems` always takes the idle branch for now).

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/AppDelegate.swift
git commit -m "Add Record menu section and elapsed-time ticker to AppDelegate"
```

---
### Task 12: Record hotkey wiring

**Files:**
- Modify: `Sources/SXApp/AppDelegate.swift` (`registerHotkeys` only)
- Test: build only + Mac smoke checklist entry (deferred functional verification to Task 14, same reasoning as Task 11).

**Interfaces:**
- Consumes: `HotkeySettings.record` (Task 1), `HotkeyManager.register(_:handler:)` (M1, unchanged), `recordingCoordinator` (Task 11).
- Produces: pressing the configured combo (default ⌥⇧6) toggles recording in `.region` mode — idle starts a region recording, recording stops it — matching the spec's "stop via hotkey or menu click" (§3.4).

- [ ] **Step 1: Register the record hotkey**

In `Sources/SXApp/AppDelegate.swift`, replace `registerHotkeys(_:)` (the whole method) with:

```swift
    private func registerHotkeys(_ config: HotkeySettings) {
        let manager = HotkeyManager()
        hotkeys = manager
        if let combo = config.fullscreen {
            manager.register(combo) { [weak self] in
                AppLog.log("Fullscreen hotkey fired")
                self?.coordinator?.captureFullscreen()
            }
        }
        if let combo = config.region {
            manager.register(combo) { [weak self] in self?.coordinator?.captureRegion() }
        }
        if let combo = config.window {
            manager.register(combo) { [weak self] in self?.coordinator?.captureWindow() }
        }
        if let combo = config.record {
            manager.register(combo) { [weak self] in
                AppLog.log("Record hotkey fired")
                self?.recordingCoordinator?.toggle(mode: .region)
            }
        }
        AppLog.log("Hotkeys registered (fullscreen=\(config.fullscreen != nil), region=\(config.region != nil), window=\(config.window != nil), record=\(config.record != nil))")
    }
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: `Build complete!` (no new errors or warnings).

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/AppDelegate.swift
git commit -m "Register the record hotkey (default ⌥⇧6, toggles region recording)"
```

---
### Task 13: History video tolerance + "Export as GIF…" action

**Files:**
- Modify: `Sources/SXCore/MIMEType.swift` (add the pure `isVideo(path:)`)
- Modify: `Sources/SXCore/RecordingDelivery.swift` (add the pure `gifOutputURL(for:fileExists:)`)
- Modify: `Sources/SXApp/HistoryView.swift` (video-tolerance thumbnails via `MIMEType.isVideo`; GIF export button, sheet, and alert; export via `RecordingDelivery.gifOutputURL` + `GifConverter`)
- Modify: `Sources/SXApp/HistoryWindowController.swift` (threads `RecordingSettings` defaults into `HistoryModel`)
- Modify: `Sources/SXApp/AppDelegate.swift` (`showHistory` passes a `SettingsStore` to the widened `HistoryWindowController` init)
- Test: Create `Tests/SXCoreTests/RecordingGifPathTests.swift` (the two pure helpers: video-extension detection, sibling `.gif` filename resolution). The SwiftUI sheet and `HistoryModel` glue are build-only + Mac smoke checklist (SXApp is an executable target and cannot be `@testable import`ed — the pure logic therefore lives in SXCore).

**Interfaces:**
- Consumes: `GifConverter.{Options, convert}` (Task 5), `RecordingSettings.{gifFPS, gifMaxWidth}` (Task 1), `HistoryStore`, `HistoryEntry` (existing, M2).
- Produces:
  - SXCore: `MIMEType.isVideo(path: String) -> Bool` — true for `mp4`/`mov`; History uses it so video rows show a film icon instead of attempting (and silently failing at) an ImageIO video-frame decode.
  - SXCore: `RecordingDelivery.gifOutputURL(for sourceURL: URL, fileExists: (URL) -> Bool = ...) -> URL` — the source's sibling `.gif` path (`_1`, `_2`, … on collision), pure and injectable.
  - SXApp: `HistoryModel.beginGifExport(_:)`, `HistoryModel.exportGif(for:fps:maxWidth:) async` — thin glue that calls `RecordingDelivery.gifOutputURL` + `GifConverter.convert`, inserts a new history row for the `.gif`, and never touches the source mp4 row.
  - `HistoryWindowController.init(store:settingsStore:)` — widened to read `RecordingSettings` defaults for the export sheet's initial fps/width.

- [ ] **Step 1: Write the failing pure tests**

Create `Tests/SXCoreTests/RecordingGifPathTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct RecordingGifPathTests {
    @Test func isVideoRecognizesMp4AndMov() {
        #expect(MIMEType.isVideo(path: "/tmp/a.mp4"))
        #expect(MIMEType.isVideo(path: "/tmp/A.MOV"))
        #expect(!MIMEType.isVideo(path: "/tmp/a.png"))
        #expect(!MIMEType.isVideo(path: "/tmp/a.gif"))
    }

    @Test func gifOutputURLReplacesTheExtension() {
        let src = URL(fileURLWithPath: "/tmp/sx/Recording_1.mp4")
        let url = RecordingDelivery.gifOutputURL(for: src, fileExists: { _ in false })
        #expect(url.path == "/tmp/sx/Recording_1.gif")
    }

    @Test func gifOutputURLAppendsANumericSuffixOnCollision() {
        let src = URL(fileURLWithPath: "/tmp/sx/Recording_1.mp4")
        let seen: Set<String> = ["/tmp/sx/Recording_1.gif"]
        let url = RecordingDelivery.gifOutputURL(for: src, fileExists: { seen.contains($0.path) })
        #expect(url.path == "/tmp/sx/Recording_1_1.gif")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `MIMEType.isVideo` and `RecordingDelivery.gifOutputURL` do not exist yet, so `RecordingGifPathTests.swift` fails to compile.

- [ ] **Step 3: Add the SXCore helpers, then video tolerance and GIF export to HistoryView**

First add the two pure helpers. In `Sources/SXCore/MIMEType.swift`, add `isVideo(path:)` to the `MIMEType` enum:

```swift
    /// True for the recording file extensions History can show. ImageIO cannot
    /// downsample a video frame, so History uses this to fall back to a film
    /// icon rather than attempting (and silently failing at) a thumbnail decode.
    public static func isVideo(path: String) -> Bool {
        ["mp4", "mov"].contains((path as NSString).pathExtension.lowercased())
    }
```

In `Sources/SXCore/RecordingDelivery.swift`, add `gifOutputURL(for:fileExists:)` to the existing `extension RecordingDelivery` (beside `outputURL`):

```swift
    /// The source video's sibling `.gif` path (`<name>.gif` next to it; `_1`,
    /// `_2`, … on collision). Pure and injectable — `fileExists` defaults to the
    /// real filesystem.
    public static func gifOutputURL(
        for sourceURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let dir = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent(base + ".gif")
        var n = 1
        while fileExists(url) {
            url = dir.appendingPathComponent("\(base)_\(n).gif")
            n += 1
        }
        return url
    }
```

Then replace the whole `Sources/SXApp/HistoryView.swift` with:

```swift
import AppKit
import ImageIO
import SwiftUI
import SXCore
import SXRecord
import SXUpload

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var query: String = "" { didSet { reload() } }
    @Published var loadError: String?
    @Published var exportingEntry: HistoryEntry?
    @Published var exportError: String?
    private let store: HistoryStore
    private let http: HTTPClient
    private let recordingSettings: RecordingSettings

    init(store: HistoryStore, http: HTTPClient = URLSessionHTTPClient(),
        recordingSettings: RecordingSettings = .default) {
        self.store = store
        self.http = http
        self.recordingSettings = recordingSettings
        reload()
    }

    var defaultGifFPS: Int { recordingSettings.gifFPS }
    var defaultGifMaxWidth: Int? { recordingSettings.gifMaxWidth }

    func reload() {
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.all(limit: 500)
                : try store.search(matching: query, limit: 500)
            loadError = nil
        } catch {
            AppLog.log("History: load failed: \(error)")
            entries = []
            loadError = "Couldn’t load history."
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func delete(_ entry: HistoryEntry) {
        do { try store.delete(id: entry.id) }
        catch { AppLog.log("History: delete failed for \(entry.id): \(error)") }
        // Best-effort remote deletion; local removal already succeeded.
        if let del = entry.deletionURL, let url = URL(string: del) {
            let http = self.http
            Task {
                do { _ = try await http.send(PreparedRequest(method: .get, url: url.absoluteString)) }
                catch { AppLog.log("History: remote deletion failed for \(entry.id): \(error)") }
            }
        }
        reload()
    }

    func beginGifExport(_ entry: HistoryEntry) {
        guard entry.filePath != nil else { return }
        exportingEntry = entry
    }

    /// Converts `entry`'s video to a sibling `.gif` (same name, `.gif`
    /// extension; colliding names get a numeric suffix), inserts a new history
    /// row for it, and reloads. Local-first: the GIF is fully written before
    /// the row lands; the source mp4 row is never touched.
    func exportGif(for entry: HistoryEntry, fps: Int, maxWidth: Int?) async {
        guard let sourcePath = entry.filePath else { return }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let gifURL = RecordingDelivery.gifOutputURL(for: sourceURL)
        do {
            try await GifConverter.convert(videoURL: sourceURL, to: gifURL,
                                           options: .init(fps: fps, maxWidth: maxWidth))
            let row = HistoryEntry(id: UUID().uuidString, capturedAt: Date(),
                                   filePath: gifURL.path, url: nil, deletionURL: nil,
                                   destinationName: nil, uploadFailed: false)
            try store.insert(row)
            AppLog.log("GIF exported: \(gifURL.path)")
            exportError = nil
        } catch {
            AppLog.log("GIF export failed: \(error)")
            exportError = "GIF export failed: \(error.localizedDescription)"
        }
        exportingEntry = nil
        reload()
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search captures", text: $model.query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(8)
            Divider()
            if model.entries.isEmpty {
                Spacer()
                Text(model.loadError ?? "No captures yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    HistoryRow(entry: entry, model: model)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .sheet(item: $model.exportingEntry) { entry in
            GifExportSheet(entry: entry, model: model)
        }
        .alert("Export Failed", isPresented: .constant(model.exportError != nil), presenting: model.exportError) { _ in
            Button("OK") { model.exportError = nil }
        } message: { message in
            Text(message)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(path: entry.filePath)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url ?? entry.filePath.map { ($0 as NSString).lastPathComponent }
                     ?? "Capture")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    if let dest = entry.destinationName { Text("· \(dest)") }
                    if entry.uploadFailed { Text("· upload failed").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = entry.url {
                Button { model.copy(url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy URL")
                Button { model.open(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open URL")
            }
            if let path = entry.filePath {
                if MIMEType.isVideo(path: path) {
                    Button { model.beginGifExport(entry) } label: { Image(systemName: "film.stack") }
                        .buttonStyle(.borderless).help("Export as GIF…")
                }
                Button { model.reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            Button(role: .destructive) { model.delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 2)
    }
}

/// fps/scale options for "Export as GIF…", pre-filled from RecordingSettings.
private struct GifExportSheet: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel
    @State private var fps: Double
    @State private var maxWidthText: String
    @State private var isExporting = false

    init(entry: HistoryEntry, model: HistoryModel) {
        self.entry = entry
        self.model = model
        _fps = State(initialValue: Double(model.defaultGifFPS))
        _maxWidthText = State(initialValue: model.defaultGifMaxWidth.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export as GIF").font(.headline)
            HStack {
                Text("Frame rate")
                Slider(value: $fps, in: 1...30, step: 1)
                Text("\(Int(fps)) fps").monospacedDigit()
            }
            HStack {
                Text("Max width (px)")
                TextField("Source width", text: $maxWidthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.exportingEntry = nil }
                    .disabled(isExporting)
                Button("Export") {
                    isExporting = true
                    let width = Int(maxWidthText)
                    Task { await model.exportGif(for: entry, fps: Int(fps), maxWidth: width) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct Thumbnail: View {
    let path: String?
    var body: some View {
        if let path, let image = Thumbnail.downsampled(path: path, maxPixel: 96) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 36).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let path, MIMEType.isVideo(path: path) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    /// Decode a downsampled thumbnail directly via ImageIO, so a 4K+ screenshot
    /// is never fully decoded just to render at 48×36 (maxPixel 96 covers Retina).
    /// Videos return nil here (ImageIO can't decode a video frame) → the film
    /// fallback above; `MIMEType.isVideo` (SXCore) is the single source of truth.
    static func downsampled(path: String, maxPixel: Int) -> NSImage? {
        guard !MIMEType.isVideo(path: path) else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
```

- [ ] **Step 4: Thread RecordingSettings through HistoryWindowController and its AppDelegate call site**

Replace the whole `Sources/SXApp/HistoryWindowController.swift` with:

```swift
import AppKit
import SwiftUI
import SXCore

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private var model: HistoryModel?
    private let store: HistoryStore
    private let settingsStore: SettingsStore

    init(store: HistoryStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
    }

    func show() {
        if let window {
            model?.reload()   // pick up captures recorded since the window was last shown
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let recording = settingsStore.loadOrDefault().0.recording
        let model = HistoryModel(store: store, recordingSettings: recording)
        self.model = model
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "History"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 460))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
```

In `Sources/SXApp/AppDelegate.swift`, update `showHistory()`:

```swift
    @objc private func showHistory() {
        guard let store = historyStore else {
            effects.notify(title: "History unavailable",
                           body: "The history database could not be opened.", fileURL: nil)
            return
        }
        if historyWindow == nil {
            historyWindow = HistoryWindowController(
                store: store, settingsStore: SettingsStore(fileURL: SettingsStore.defaultFileURL))
        }
        historyWindow?.show()
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `RecordingGifPathTests`. `scripts/remote.sh build` succeeds for the SwiftUI sheet/model wiring (exercised via the Mac smoke checklist).

- [ ] **Step 6: Commit**

```bash
git add Sources/SXCore/MIMEType.swift Sources/SXCore/RecordingDelivery.swift Sources/SXApp/HistoryView.swift Sources/SXApp/HistoryWindowController.swift Sources/SXApp/AppDelegate.swift Tests/SXCoreTests/RecordingGifPathTests.swift
git commit -m "Add video thumbnails and on-demand GIF export to History"
```

---
### Task 14: AppDelegate end-to-end wiring + Info.plist doc types

**Files:**
- Modify: `Sources/SXApp/AppDelegate.swift` (`applicationDidFinishLaunching`: instantiate `ScreenRecorder`/`RecordingCoordinator`, wire `deliver`/`onStateChange`)
- Modify: `Resources/Info.plist` (optional `CFBundleDocumentTypes` entries for `.mp4`/`.gif`)
- Test: build only. This task's payoff is entirely interactive (SCK recording, TCC, menu-bar/hotkey behavior) — verify with the full **Mac Smoke Checklist** below.

**Interfaces:**
- Consumes: `ScreenRecorder()` (Task 4), `RecordingCoordinator.init(recorder:settingsStore:effects:deliver:onStateChange:)` (Task 9), `CaptureCoordinator.deliverRecording(fileURL:appName:)` (Task 7), `AppDelegate.updateRecordingUI(_:)` (Task 11).
- Produces: a fully wired `recordingCoordinator` — every Record menu item, the ⌥⇧6 hotkey, and the elapsed-time UI (Tasks 10–12) become live.

- [ ] **Step 1: Instantiate and wire RecordingCoordinator**

In `Sources/SXApp/AppDelegate.swift`, add the import:

```swift
import SXRecord
```

In `applicationDidFinishLaunching`, insert the following immediately after `self.coordinator = coordinator` (before `destinationsWindow = ...`):

```swift
        let recorder = ScreenRecorder()
        let recordingCoordinator = RecordingCoordinator(
            recorder: recorder, settingsStore: store, effects: effects,
            deliver: { [weak coordinator] url, appName in
                coordinator?.deliverRecording(fileURL: url, appName: appName)
            },
            onStateChange: { [weak self] on in self?.updateRecordingUI(on) })
        self.recordingCoordinator = recordingCoordinator
```

So the method now reads, in full:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicateInstance() else { return }
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, issue) = store.loadOrDefault()
        handleLoadIssue(issue)
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            do {
                try store.save(settings)   // materialize defaults for hand-editing
            } catch {
                AppLog.log("Failed to materialize default settings at \(store.fileURL.path): \(error)")
            }
        }

        effects.setUpNotifications()
        let historyStore = try? HistoryStore(
            fileURL: SettingsStore.defaultFileURL.deletingLastPathComponent()
                .appendingPathComponent("history.sqlite"))
        if historyStore == nil { AppLog.log("History store unavailable; captures won't be recorded") }
        self.historyStore = historyStore
        let uploadService = UploadService(credentials: KeychainCredentialStore())
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore,
                                             editorPresenter: editorWindow)
        self.coordinator = coordinator
        let recorder = ScreenRecorder()
        let recordingCoordinator = RecordingCoordinator(
            recorder: recorder, settingsStore: store, effects: effects,
            deliver: { [weak coordinator] url, appName in
                coordinator?.deliverRecording(fileURL: url, appName: appName)
            },
            onStateChange: { [weak self] on in self?.updateRecordingUI(on) })
        self.recordingCoordinator = recordingCoordinator
        destinationsWindow = DestinationsWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() })
        statusItem = StatusItemController(menu: buildMenu())
        registerHotkeys(settings.hotkeys)
        AppLog.log("Launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"), screenRecording=\(PermissionOnboardingController.isGranted()))")

        handleCLIArguments()
    }
```

- [ ] **Step 2: Register .mp4/.gif as alternate document types**

In `Resources/Info.plist`, add two entries to the `CFBundleDocumentTypes` array (after the existing `sxcu` entry, before `</array>`):

```xml
        <dict>
            <key>CFBundleTypeName</key><string>ShareX Recording</string>
            <key>CFBundleTypeExtensions</key><array><string>mp4</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>ShareX Animated GIF</string>
            <key>CFBundleTypeExtensions</key><array><string>gif</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
```

`LSHandlerRank: Alternate` (matching the existing `.sxcu` entry) means ShareX for Mac never becomes the *default* handler for video/GIF files — it just appears as an option. This is a nice-to-have, not required for save/upload/export to work; `scripts/bundle.sh`'s entitlements are unaffected (system-audio recording rides on the existing Screen Recording TCC grant — no new entitlement or `NSMicrophoneUsageDescription`, per spec §3.4).

- [ ] **Step 3: Verify it builds**

Run: `scripts/remote.sh build`
Expected: `Build complete!` (no new errors or warnings).

- [ ] **Step 4: Run the full test suite**

Run: `scripts/remote.sh test`
Expected: PASS — every suite added across Tasks 1–14 (in `SXCoreTests`, `SXCaptureTests`, `SXUploadTests`, `SXRecordTests`) plus every pre-existing M1–M3 suite, unchanged. (There is no `SXAppTests` target — SXApp is the executable and cannot be `@testable import`ed; all M4 unit tests live in library-target suites.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SXApp/AppDelegate.swift Resources/Info.plist
git commit -m "Wire RecordingCoordinator into AppDelegate; register mp4/gif document types"
```

- [ ] **Step 6: Run the Mac Smoke Checklist**

Deploy with `scripts/remote.sh run`, then work through the **Mac Smoke Checklist** section at the end of this plan before considering M4 done (Task 15 is optional and can be skipped without blocking that checklist).

---
### Task 15 (OPTIONAL — skippable): ffmpeg palettegen branch in GifConverter

> Per spec §3.4: "if ffmpeg is found on PATH, use palettegen for higher quality — optional, never required." Skip this task entirely if higher-quality GIF export isn't a priority; Task 5's native `GifConverter.convert` is already the complete, always-correct implementation every other task depends on.

**Files:**
- Modify: `Sources/SXRecord/GifConverter.swift`
- Test: Modify `Tests/SXRecordTests/GifConverterTests.swift`

**Interfaces:**
- Consumes: `GifConverter.{Options, convert}`, `RecordingError` (Task 5/2).
- Produces:
  - `static func ffmpegURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?` — pure PATH lookup, no dependency on ffmpeg actually being installed.
  - `static func convertWithFFmpeg(videoURL:to:options:ffmpeg:) async throws` — two-pass `palettegen`/`paletteuse` via `Process`.
  - `static func convertPreferringFFmpeg(videoURL:to:options:) async throws` — uses ffmpeg when available, silently falls back to the native `convert` on any ffmpeg failure (the *native* conversion's own failure, if any, is what actually propagates — this is a best-effort quality upgrade, not a second point of silent data loss).

- [ ] **Step 1: Write the failing PATH-detection tests**

Append to `Tests/SXRecordTests/GifConverterTests.swift`:

```swift
@Suite struct FFmpegDetectionTests {
    @Test func findsAnExecutableOnPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("ffmpeg")
        FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = GifConverter.ffmpegURL(environment: ["PATH": dir.path])
        #expect(found?.path == fake.path)
    }

    @Test func returnsNilWhenNotOnPath() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(GifConverter.ffmpegURL(environment: ["PATH": dir.path]) == nil)
    }

    @Test func returnsNilWithNoPathVariable() {
        #expect(GifConverter.ffmpegURL(environment: [:]) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `GifConverter.ffmpegURL` does not exist yet, so `FFmpegDetectionTests` fails to compile.

- [ ] **Step 3: Add the ffmpeg detection + palettegen branch**

Append to `Sources/SXRecord/GifConverter.swift`:

```swift
extension GifConverter {
    /// True if `ffmpeg` is discoverable on PATH. Used to opt into the
    /// higher-quality palettegen conversion; `convert` (native) is always the
    /// fallback and the only path CI can exercise.
    static func ffmpegURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Higher-quality two-pass palettegen/paletteuse conversion via a local
    /// `ffmpeg` binary. Never required — `convert` is always the fallback.
    static func convertWithFFmpeg(videoURL: URL, to gifURL: URL, options: Options,
                                  ffmpeg: URL) async throws {
        let paletteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: paletteURL) }
        let scaleFilter = options.maxWidth.map { "scale=\($0):-1:flags=lanczos," } ?? ""

        try await run(ffmpeg, [
            "-y", "-i", videoURL.path,
            "-vf", "\(scaleFilter)fps=\(options.fps),palettegen",
            paletteURL.path,
        ])
        try await run(ffmpeg, [
            "-y", "-i", videoURL.path, "-i", paletteURL.path,
            "-lavfi", "\(scaleFilter)fps=\(options.fps)[x];[x][1:v]paletteuse",
            "-loop", "0", gifURL.path,
        ])
    }

    /// Uses ffmpeg when available (higher-quality palettegen), otherwise falls
    /// back to the native `convert`. A best-effort ffmpeg failure here
    /// deliberately falls through to the always-correct native path rather
    /// than propagating — fail-loud still holds: the *native* conversion's own
    /// failure (if any) is what actually surfaces to the caller. Silence only
    /// covers "ffmpeg didn't work", never "no GIF was produced".
    public static func convertPreferringFFmpeg(videoURL: URL, to gifURL: URL, options: Options) async throws {
        if let ffmpeg = ffmpegURL(),
           (try? await convertWithFFmpeg(videoURL: videoURL, to: gifURL, options: options, ffmpeg: ffmpeg)) != nil {
            return
        }
        try await convert(videoURL: videoURL, to: gifURL, options: options)
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: RecordingError.conversionFailed(
                        "ffmpeg exited \(p.terminationStatus): \(arguments.joined(separator: " "))"))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS — all `FFmpegDetectionTests` (pure, no dependency on ffmpeg actually being installed). `convertWithFFmpeg`/`convertPreferringFFmpeg` are exercised only manually (Step 5).

- [ ] **Step 5 (manual, optional): verify the ffmpeg branch on the Mac**

If `ffmpeg` is installed on the build Mac (`which ffmpeg`), record a short clip, then from a scratch script or REPL call `GifConverter.convertPreferringFFmpeg` on it and confirm the output plays and looks smoother/smaller than the native path's output on the same source. Skip entirely if ffmpeg isn't installed — nothing else in this plan depends on it.

- [ ] **Step 6: Commit**

```bash
git add Sources/SXRecord/GifConverter.swift Tests/SXRecordTests/GifConverterTests.swift
git commit -m "Add optional ffmpeg palettegen branch to GifConverter"
```

---
## Mac Smoke Checklist (run after Task 14, before finishing the branch)

Deploy with `scripts/remote.sh run`, then:

1. **Region recording:** Menu bar → Start Recording ▸ Region (or ⌥⇧6). The region overlay appears identically to a region *capture*; drag a selection. Confirm the menu-bar icon switches to the red stop-circle and an elapsed-time label starts counting up next to it.
2. **Stop via menu:** Click the menu-bar icon → **Stop Recording**. Confirm the icon returns to the camera glyph, the elapsed label clears, and (if **Save to disk** is on) an `.mp4` lands in `~/Pictures/ShareX` with a filename matching the configured template.
3. **Stop via hotkey:** Start a region recording (⌥⇧6), then press ⌥⇧6 again to stop. Confirm it stops (not a second recording starting).
4. **Window recording:** Start Recording ▸ Window; the picker overlay behaves like window *capture* (hover-highlight, click to pick). Record a few seconds of a window with visible motion (e.g. scroll some text); confirm the output mp4 is cropped to that window's content only.
5. **Display recording:** Start Recording ▸ Display with the mouse over a specific monitor (multi-display setups only, otherwise this is equivalent to the single display); confirm the display *under the mouse* is the one recorded.
6. **System Audio toggle:** Menu bar → System Audio (checkbox toggles); confirm the checkmark persists across a menu reopen and across app relaunch (`settings.json`'s `recording.systemAudio`). Record with it on while audio is playing; confirm the mp4 has an audio track. Confirm no microphone permission prompt ever appears (system audio rides the existing Screen Recording TCC grant).
7. **Codec setting:** Hand-edit `~/Library/Application Support/ShareX-Mac/settings.json`'s `recording.videoCodec` to `"hevc"`, relaunch, record a clip; confirm the output plays (HEVC) and `ffprobe`/QuickTime report the expected codec. Set back to `"h264"` (the default) afterward.
8. **Local-first / upload:** With an active upload destination and **Upload After Capture** on, record a clip; confirm the mp4 is written to disk **before** the URL lands on the clipboard (the file exists even if you kill network mid-upload), and the History row shows the destination + URL once the upload completes.
9. **Upload failure:** Temporarily point the active destination at an unreachable URL (or disconnect network), record a clip; confirm the mp4 + its History row remain (`uploadFailed` shown in the row), and a "Upload failed… Local file kept" notification appears.
10. **History video row:** Open History (⌘, or menu → History…). Confirm mp4 rows show a film-icon placeholder (not a broken image), while PNG rows still show real thumbnails.
11. **Export as GIF…:** On an mp4 row, click the film-stack button. The fps/max-width sheet appears pre-filled from `recording.gifFPS`/`gifMaxWidth` (defaults 15fps / 640px). Click Export; confirm a new `.gif` row appears in History next to the source mp4 row (the mp4 row is untouched), and the `.gif` file plays as an animated loop in Finder/Preview.
12. **GIF export failure:** Point "Export as GIF…" at a corrupt/zero-byte "mp4" (e.g. rename an empty file to `.mp4` in the captures folder, then re-open History so it appears as a row) and attempt export; confirm an alert surfaces the failure (fail-loud) rather than silently producing nothing.
13. **Multiple recordings / re-entrancy:** With a recording in progress, click Start Recording ▸ Region again from the menu; confirm it's a no-op (guarded by `isRecording`/`isPresentingOverlay`) rather than starting a second concurrent stream.
14. **Cancel mid-setup:** Start Recording ▸ Region, then press Escape on the overlay before dragging a selection; confirm no recording starts and the icon stays idle.
15. **Elapsed time accuracy:** Record for ~65 seconds; confirm the menu-bar label and the disabled elapsed menu item both show `1:05`-ish (not reset, not frozen) and that the menu didn't visibly flicker/rebuild every second (only the label text changes).

---

## Self-Review

*(Author checklist against spec §3.4 and the ratified architecture contract.)*

**1. Spec coverage** — each §3.4 clause → the task(s) that satisfy it:
- `SCRecordingOutput` (macOS 15 API) → .mp4, H.264/HEVC via VideoToolbox → Task 4 (`ScreenRecorder`, `codec: AVVideoCodecType` param), Task 9 (`settings.recording.videoCodec` selects `.h264`/`.hevc`). ✅
- Reuses the same region/window/display selector as stills → Task 3 (SCK object-resolution helpers reusing `SCShareableContent`), Task 8 (`RecordingRegionSession` reuses `RegionSelectionView`/`KeyableWindow`), Task 9 (reuses `WindowPickerSession` unchanged and `DisplayCapture.captureAllDisplays` for the region flow's frozen preview). ✅
- Menu-bar icon switches to recording state with elapsed time; stop via hotkey or menu click → Task 10 (`StatusItemController.setRecording`/`setTitle`), Task 11 (Record menu section, elapsed ticker, Stop item), Task 12 (record hotkey toggles), Task 14 (wiring that makes all of it live). ✅
- Optional system audio (native to SCK); microphone capture deferred → Task 1 (`RecordingSettings.systemAudio`), Task 9 (`capturesAudio: settings.recording.systemAudio` passed to `ScreenRecorder.start`), Task 11 (System Audio menu toggle). No microphone code anywhere in this plan — confirmed absent by design (v1 non-goal, spec §7). ✅
- GIF: post-convert the recorded mp4 natively with fps/scale options → Task 5 (`GifConverter.convert`, `Options.fps`/`maxWidth`), Task 13 (fps/scale export sheet, defaults from `RecordingSettings`). Optional ffmpeg palettegen when on PATH, never required → Task 15 (explicitly marked OPTIONAL/skippable; Task 5's native path is already complete on its own). ✅
- Recordings run the same after-capture pipeline (save → upload → URL) → Task 6 (`UploadService.upload(data:filename:mime:destination:)` generalizes the still-only path; `MIMEType` + an SXUpload mime-passthrough test), Task 7 (`RecordingDelivery.deliver` in SXCore — history row FIRST, then optional upload — with `CaptureCoordinator.deliverRecording` as thin glue), Task 9 (`RecordingCoordinator`'s `deliver` closure hands the finished file to it). ✅
- Cross-cutting from §2/§5/§6 (local-first, fail-loud, swift-testing, gated SCK live tests) — covered by every task; the load-bearing ordering / local-first / fail-loud guarantees are explicitly test-asserted in **`SXCoreTests`** in Task 7 (`RecordingDeliveryTests`: history-insert-before-upload ordering, success updates the row + copies URL + notifies, upload-failure keeps the row + file with `uploadFailed = true` and never touches the file, no re-encode) — hoisted into SXCore precisely because `SXApp` is an executable target that cannot be `@testable import`ed — and in Task 4 (fire-once delivery, `alreadyRecording` guard). ✅

**2. Placeholder scan** — grep for `TBD`/`TODO`/`similar to Task`/`add error handling`/trailing `…` as a stand-in for real code: clean. Every code step is complete and either verbatim from the architecture contract (`RecordingSettings`, `RecordingDimensions`, `RecordingError`, the `ScreenRecorder`/`RecordingDelegateShim` concurrency shim) or a full, real implementation written to satisfy the contract's pseudocode where it left one (`GifConverter.convert`'s body, `RecordingDelivery.deliver`/`CaptureCoordinator.deliverRecording`, `RecordingCoordinator`'s mode orchestration). The one deliberately-unused parameter (`deliverRecording(fileURL:appName:)`'s `appName`) carries a real, specific doc-comment explaining why (parity with the still-image path; `HistoryEntry` has no `appName` column today) rather than a vague placeholder note.

**3. Type consistency** — cross-task shared names verified identical across every task that produces/consumes them:
- `RecordingSettings.{systemAudio, videoCodec, gifFPS, gifMaxWidth}` (Task 1) → consumed unchanged by Task 9 (`videoCodec`/`systemAudio`) and Task 13 (`gifFPS`/`gifMaxWidth` via `defaultGifFPS`/`defaultGifMaxWidth`).
- `RecordingDimensions.{display, region, window}` (Task 2) → consumed unchanged by Task 4 (`start(dimensions:)`) and Task 9 (all three factories called with matching label sets).
- `RecordingError` cases (Task 2) → `ScreenRecorder` (Task 4) and `GifConverter`/ffmpeg branch (Tasks 5, 15) both throw/deliver `RecordingError`, never a second ad hoc error type.
- `ScreenRecorder.{start, stop, state, handle, _beginForTesting}` (Task 4) → `RecordingCoordinator` (Task 9) calls `start`/`stop` with the exact labeled-parameter signature from Task 4; no other task touches `ScreenRecorder` directly.
- `DisplayCapture.{shareableContent, scDisplay}` / `WindowCapture.{scWindow, backingScale(forCGGlobalFrame:)}` (Task 3 + Task 9's own `backingScale` widening) → consumed only by `RecordingCoordinator` (Task 9), with matching signatures.
- `MIMEType.forExtension(_:)` (Task 6) / `MIMEType.isVideo(path:)` (Task 13) → `RecordingDelivery`/`CaptureCoordinator` compute upload mime via `forExtension`; `HistoryView` calls `isVideo`. `UploadService.upload(data:filename:mime:destination:)` (Task 6) is **additive** — the shipped PNG still-path keeps its own `filePart(pngData:filename:)` untouched; nothing is removed.
- `RecordingDelivery.{DeliveredUpload, deliver(fileURL:capturedAt:destinationName:shouldUpload:showNotification:mime:history:effects:upload:), outputURL(settings:capturedAt:appName:fileExists:), gifOutputURL(for:fileExists:)}` (SXCore; introduced in Task 7, extended in Tasks 9 and 13) → `CaptureCoordinator.deliverRecording` (Task 7) and `RecordingCoordinator.beginRecording` (Task 9) call `deliver`/`outputURL`; `HistoryModel.exportGif` (Task 13) calls `gifOutputURL`. The `upload` closure type `(Data, String, String) async throws -> DeliveredUpload` matches how `CaptureCoordinator.deliverRecording` adapts `UploadService.upload(...) -> UploadResult`.
- `CaptureCoordinator.deliverRecording(fileURL:appName:)` (Task 7) → the exact signature `RecordingCoordinator`'s `deliver` closure type (Task 9) and `AppDelegate`'s wiring (Task 14) both target. `CaptureCoordinator`'s stored `effects: AppPipelineEffects` property is unchanged from M3b (`AppPipelineEffects` conforms to `PipelineEffects`, so it passes into `RecordingDelivery.deliver`'s `effects: any PipelineEffects` parameter as-is).
- `RecordingRegionSession.init(displays:onComplete:)` returning `(display: FrozenDisplay, rect: CGRect)?` (Task 8) → consumed with the same tuple-labeled type by `RecordingCoordinator.startRegion`/`startRegionRecording` (Task 9).
- `RecordingCoordinator.{Mode, init(recorder:settingsStore:effects:deliver:onStateChange:), isRecording, toggle, start, stop}` (Task 9) → `AppDelegate` (Tasks 11, 12, 14) calls `toggle(mode:)`/`stop()` from menu selectors and the hotkey handler, and `init` with the exact five labeled parameters, in Task 14. (Output-path resolution is `RecordingDelivery.outputURL` in SXCore, not a `RecordingCoordinator` static — so it can be unit-tested outside the executable target.)
- `StatusItemController.{setRecording, setTitle}` (Task 10) → both called only from `AppDelegate.updateRecordingUI`/`tickElapsed` (Task 11), matching signatures.
- `AppDelegate.{recordingCoordinator, elapsedMenuItem, elapsedTimer, updateRecordingUI, tickElapsed, buildRecordingItems, menuRecordRegion/Window/Display, menuStopRecording, toggleSystemAudio}` (Task 11) → `recordingCoordinator` is read (not reassigned) by Task 12's hotkey handler and assigned exactly once in Task 14; `updateRecordingUI` is the literal closure body `RecordingCoordinator`'s `onStateChange` receives in Task 14.
- `GifConverter.{Options, frameTimes, convert}` (Task 5) → `HistoryModel.exportGif` (Task 13) calls `convert(videoURL:to:options:)` with the exact labels; Task 15's `convertPreferringFFmpeg` has the identical signature to `convert` so it's a drop-in if ever wired into Task 13 later (not done in this plan — Task 13 deliberately calls the always-required native `convert` directly, keeping Task 15 fully optional and non-blocking).
- Task 13's pure logic lives in SXCore (`MIMEType.isVideo`, `RecordingDelivery.gifOutputURL`) and is tested in `Tests/SXCoreTests/RecordingGifPathTests.swift`; `HistoryView`/`HistoryModel` (SXApp executable) are thin glue over those helpers and are exercised only by the Mac Smoke Checklist. `Thumbnail` stays `private` to `HistoryView.swift` (no test needs to reach it).

**Deliberate scope calls and contract deviations surfaced to the human (not bugs — do not "fix" without re-confirming intent):**
- **No `SXAppTests` target.** `SXApp` is an `.executableTarget` with top-level code (`main.swift`), which a test target cannot `@testable import`; splitting the executable would break `scripts/bundle.sh` / `Info.plist` / `scripts/remote.sh` (out of scope for M4). Every unit-testable piece of M4 logic therefore lives in a **library** target — the delivery ordering + path helpers in `SXCore` (`RecordingDelivery`, `MIMEType`), the recorder/dimensions/GIF in `SXRecord`, mime-passthrough in `SXUpload` — and `CaptureCoordinator`/`RecordingCoordinator`/`HistoryModel` stay thin glue verified by the Mac Smoke Checklist. `CaptureCoordinator`'s stored `effects: AppPipelineEffects` is left exactly as M3b shipped (only `RecordingDelivery.deliver`'s parameter is `any PipelineEffects`, which `AppPipelineEffects` satisfies).
- **`RecordingCoordinator.init` drops `uploadService`/`historyStore` and adds a `deliver` closure**, reconciling an internal inconsistency in the contract (its init sketch listed those two params, but every behavior it goes on to describe routes persistence through `captureCoordinator.deliverRecording` via "prefer the closure to avoid a hard coupling"). No task before Task 14 depends on the dropped params, and Task 14's wiring matches the closure form exactly.
- **`GifConverter.convert`'s body is original code**, not verbatim contract text — the contract gave commented pseudocode for this one function ("AVURLAsset; duration = …", "generate frames…") rather than a finished implementation. Task 5 turns that into a complete, real `AVAssetImageGenerator` → `CGImageDestination` implementation and backs it with a live conversion test that synthesizes its own tiny mp4 via `AVAssetWriter` — which also means that test needs no Screen Recording TCC grant and runs unconditionally in CI, an upgrade over the contract's suggested TCC-gated approach.
- **Display-recording mode picks "the display under the mouse"** (spec's own v1 call, quoted in the contract) with no chooser UI; a multi-display picker is out of scope for M4.