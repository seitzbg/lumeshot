# M1 — Capture Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar macOS app that captures fullscreen/region/window screenshots via global hotkeys, saves to disk + clipboard, and notifies — daily-drivable in place of ⌘⇧4.

**Architecture:** SwiftPM package with one executable (`SXApp`) and two libraries: `SXCore` (pure logic: settings, naming, after-capture pipeline — fully unit-tested) and `SXCapture` (ScreenCaptureKit stills, permission gate, geometry). AppKit shell; all UI on `@MainActor`. Spec: `docs/superpowers/specs/2026-07-10-sharex-mac-design.md`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (tools 6.0), AppKit, ScreenCaptureKit (`SCScreenshotManager`), Carbon `RegisterEventHotKey`, UserNotifications, Swift Testing (`import Testing`).

## Global Constraints

- macOS 15+ (`platforms: [.macOS(.v15)]`), Apple Silicon only — never add Intel/older-OS fallbacks.
- Bundle ID `org.sharexmac.app` (immutable); app display name **ShareX for Mac**; `LSUIElement` = true.
- SwiftPM-first: no Xcode project files ever committed. `.app` assembly only via `scripts/bundle.sh`.
- License GPL-3.0. No AI-attribution boilerplate anywhere (commits, docs, code).
- **The dev machine is Linux; Swift never runs locally.** Every build/test/run goes through `scripts/remote.sh` which rsyncs to and executes on `seitz@macmini1.fiber.house:~/git/sharex-mac` (the Mac dir is an rsync mirror; git lives on the Linux side at `/home/bseitz/git/sharex-mac`).
- Reference implementation for behavior questions: ShareX repo at `/home/bseitz/git/sharex` (read-only) + `sharex-audit-digest.txt` there.
- Local-first invariant: disk write happens before clipboard/notification effects.
- Fail loud: no silent `catch {}` — errors surface via `NSLog` at minimum, notification where user-visible.

---

### Task 1: Repo scaffold + remote dev loop

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/SXCore/SXCore.swift`
- Create: `Sources/SXCapture/SXCapture.swift`
- Create: `Sources/SXApp/main.swift`
- Create: `Tests/SXCoreTests/SmokeTests.swift`
- Create: `scripts/remote.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `scripts/remote.sh {build|test|bundle|run|ssh <cmd>}` — the only way any later task builds or tests. SwiftPM targets `SXCore`, `SXCapture`, `SXApp` that later tasks add files to.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.build/
dist/
.DS_Store
.swiftpm/
*.xcodeproj
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharex-mac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SXApp", dependencies: ["SXCore", "SXCapture"]),
        .target(name: "SXCore"),
        .target(name: "SXCapture", dependencies: ["SXCore"]),
        .testTarget(name: "SXCoreTests", dependencies: ["SXCore"]),
        .testTarget(name: "SXCaptureTests", dependencies: ["SXCapture"]),
    ]
)
```

- [ ] **Step 3: Write placeholder sources so all targets compile**

`Sources/SXCore/SXCore.swift`:
```swift
// SXCore: settings, naming templates, after-capture pipeline. Pure Foundation; no AppKit.
```

`Sources/SXCapture/SXCapture.swift`:
```swift
// SXCapture: ScreenCaptureKit stills, permission gate, capture geometry.
```

`Sources/SXApp/main.swift`:
```swift
print("sharex-mac scaffold")
```

`Tests/SXCoreTests/SmokeTests.swift`:
```swift
import Testing

@Test func scaffoldCompiles() {
    #expect(true)
}
```

- [ ] **Step 4: Write `scripts/remote.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MAC_HOST="${SHAREX_MAC_HOST:-seitz@macmini1.fiber.house}"
MAC_DIR="${SHAREX_MAC_DIR:-git/sharex-mac}"   # relative to remote $HOME

cmd="${1:-build}"
shift || true

ssh "$MAC_HOST" "mkdir -p $MAC_DIR"
rsync -az --delete --exclude '.git' --exclude '.build' --exclude 'dist' ./ "$MAC_HOST:$MAC_DIR/"

case "$cmd" in
  build)  ssh "$MAC_HOST" "cd $MAC_DIR && swift build 2>&1" ;;
  test)   ssh "$MAC_HOST" "cd $MAC_DIR && swift test 2>&1" ;;
  bundle) ssh "$MAC_HOST" "cd $MAC_DIR && swift build -c release 2>&1 && scripts/bundle.sh" ;;
  run)    ssh "$MAC_HOST" "cd $MAC_DIR && swift build -c release 2>&1 && scripts/bundle.sh && open -n \"dist/ShareX for Mac.app\" --args $*" ;;
  ssh)    ssh "$MAC_HOST" "cd $MAC_DIR && $*" ;;
  *) echo "usage: remote.sh {build|test|bundle|run|ssh <cmd>}" >&2; exit 2 ;;
esac
```

Then: `chmod +x scripts/remote.sh`

- [ ] **Step 5: Verify build and test pass on the Mac**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

Run: `scripts/remote.sh test`
Expected: `Test run with 1 test passed`

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Scaffold SwiftPM package and remote build loop"
```

---

### Task 2: App bundle + menu-bar skeleton

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/bundle.sh`
- Modify: `Sources/SXApp/main.swift` (replace entirely)
- Create: `Sources/SXApp/AppDelegate.swift`
- Create: `Sources/SXApp/StatusItemController.swift`

**Interfaces:**
- Consumes: `scripts/remote.sh` (Task 1).
- Produces: launchable `dist/ShareX for Mac.app`; `AppDelegate` with stored properties later tasks extend; `StatusItemController(menu: NSMenu)`; `AppDelegate.buildMenu()` returning the status menu (Task 10 rewires its items to the coordinator).

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>SXApp</string>
    <key>CFBundleIdentifier</key><string>org.sharexmac.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>ShareX for Mac</string>
    <key>CFBundleDisplayName</key><string>ShareX for Mac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>@VERSION@</string>
    <key>CFBundleVersion</key><string>@VERSION@</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `scripts/bundle.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ShareX for Mac.app"
VERSION="${VERSION:-0.1.0}"
CODESIGN_ID="${CODESIGN_ID:--}"   # '-' = ad-hoc; set a stable dev cert to keep TCC grants across rebuilds

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SXApp "$APP/Contents/MacOS/SXApp"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "$CODESIGN_ID" --identifier org.sharexmac.app "$APP"
echo "Built $APP (version $VERSION, sign: $CODESIGN_ID)"
```

Then: `chmod +x scripts/bundle.sh`

- [ ] **Step 3: Replace `Sources/SXApp/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Write `Sources/SXApp/AppDelegate.swift`**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(menu: buildMenu())
        NSLog("ShareX for Mac launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture Region", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Window", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Full Screen", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }
}
```

- [ ] **Step 5: Write `Sources/SXApp/StatusItemController.swift`**

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
}
```

- [ ] **Step 6: Build, bundle, launch, verify process, quit**

Run: `scripts/remote.sh bundle`
Expected: `Built dist/ShareX for Mac.app (version 0.1.0, sign: -)`

Run: `scripts/remote.sh ssh 'open -n "dist/ShareX for Mac.app" && sleep 3 && pgrep -x SXApp'`
Expected: a PID number (app is running; menu-bar icon visible on the Mac).

Run: `scripts/remote.sh ssh 'pkill -x SXApp && echo quit-ok'`
Expected: `quit-ok`

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Add app bundle pipeline and menu-bar skeleton"
```

---

### Task 3: SettingsStore (TDD)

**Files:**
- Create: `Sources/SXCore/AppSettings.swift`
- Create: `Sources/SXCore/SettingsStore.swift`
- Create: `Tests/SXCoreTests/SettingsStoreTests.swift`
- Delete: `Tests/SXCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings` (fields below), `HotkeyCombo(keyCode: UInt32, modifiers: UInt32)`, `SettingsStore(fileURL: URL)` with `loadOrDefault() -> (AppSettings, SettingsLoadIssue?)` and `save(_:) throws`, `SettingsStore.defaultFileURL`. Tasks 5, 9, 10 consume these exact names.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/SettingsStoreTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("settings.json")
}

@Suite struct SettingsStoreTests {
    @Test func missingFileYieldsDefaultsWithoutIssue() {
        let store = SettingsStore(fileURL: tempFile())
        let (settings, issue) = store.loadOrDefault()
        #expect(settings == AppSettings.default)
        #expect(issue == nil)
    }

    @Test func roundTripPreservesValues() throws {
        let url = tempFile()
        let store = SettingsStore(fileURL: url)
        var s = AppSettings.default
        s.filenameTemplate = "shot_%y"
        s.copyToClipboard = false
        s.hotkeys.region = HotkeyCombo(keyCode: 99, modifiers: 2560)
        try store.save(s)
        let (loaded, issue) = store.loadOrDefault()
        #expect(loaded == s)
        #expect(issue == nil)
    }

    @Test func corruptFileBacksUpAndReturnsDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        let (settings, issue) = store.loadOrDefault()
        #expect(settings == AppSettings.default)
        guard case .corruptBackedUp(let backupURL)? = issue else {
            Issue.record("expected corruptBackedUp issue"); return
        }
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func defaultsHaveExpectedHotkeys() {
        let d = AppSettings.default
        #expect(d.hotkeys.fullscreen == HotkeyCombo(keyCode: 20, modifiers: 2560)) // ⌥⇧3
        #expect(d.hotkeys.region == HotkeyCombo(keyCode: 21, modifiers: 2560))     // ⌥⇧4
        #expect(d.hotkeys.window == HotkeyCombo(keyCode: 23, modifiers: 2560))     // ⌥⇧5
        #expect(d.schemaVersion == 1)
    }
}
```

Also delete `Tests/SXCoreTests/SmokeTests.swift`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/AppSettings.swift`**

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
    public init(fullscreen: HotkeyCombo?, region: HotkeyCombo?, window: HotkeyCombo?) {
        self.fullscreen = fullscreen
        self.region = region
        self.window = window
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureSavePath: String     // supports leading ~
    public var filenameTemplate: String    // NameParser template, no extension
    public var saveToDisk: Bool
    public var copyToClipboard: Bool
    public var showNotification: Bool
    public var hotkeys: HotkeySettings

    // Carbon: optionKey(2048) | shiftKey(512) = 2560; kVK_ANSI_3=20, _4=21, _5=23
    public static let `default` = AppSettings(
        schemaVersion: 1,
        captureSavePath: "~/Pictures/ShareX",
        filenameTemplate: "Screenshot_%y-%mo-%d_%h-%mi-%s",
        saveToDisk: true,
        copyToClipboard: true,
        showNotification: true,
        hotkeys: HotkeySettings(
            fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560),
            region: HotkeyCombo(keyCode: 21, modifiers: 2560),
            window: HotkeyCombo(keyCode: 23, modifiers: 2560)
        )
    )
}
```

- [ ] **Step 4: Write `Sources/SXCore/SettingsStore.swift`**

```swift
import Foundation

public enum SettingsLoadIssue: Equatable, Sendable {
    case corruptBackedUp(URL)
}

public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShareX-Mac/settings.json")
    }

    public func loadOrDefault() -> (AppSettings, SettingsLoadIssue?) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return (.default, nil)
        }
        do {
            return (try JSONDecoder().decode(AppSettings.self, from: data), nil)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return (.default, .corruptBackedUp(backup))
        }
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add versioned JSON settings store"
```

---

### Task 4: NameParser (TDD)

**Files:**
- Create: `Sources/SXCore/NameParser.swift`
- Create: `Tests/SXCoreTests/NameParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `NameContext(date:width:height:processName:increment:calendar:)` and `NameParser.render(_ template: String, context: NameContext, rng: inout some RandomNumberGenerator) -> String` plus a convenience `render(_:context:)`. Task 5 consumes these exact signatures.
- Tokens (ShareX-compatible subset per spec §3.5): `%y %mo %d %h %mi %s %ms %rn %ra %width %height %pn %i`. The spec also lists `%n`; it is intentionally omitted in M1 — its ShareX semantics get verified against `ShareX.HelpersLib` `NameParser.cs` when M2 extends this type (recorded in `docs/porting-map.md`, Task 13).

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/NameParserTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

// Deterministic RNG for tests.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func fixedContext(increment: Int = 0) -> NameContext {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    // 2026-07-10 09:05:03.042 UTC
    let comps = DateComponents(calendar: cal, timeZone: cal.timeZone,
                               year: 2026, month: 7, day: 10,
                               hour: 9, minute: 5, second: 3, nanosecond: 42_000_000)
    return NameContext(date: comps.date!, width: 2560, height: 1440,
                       processName: "Safari", increment: increment, calendar: cal)
}

@Suite struct NameParserTests {
    @Test func dateTokensZeroPad() {
        let out = NameParser.render("%y-%mo-%d_%h-%mi-%s.%ms", context: fixedContext())
        #expect(out == "2026-07-10_09-05-03.042")
    }

    @Test func dimensionAndProcessTokens() {
        let out = NameParser.render("%pn_%widthx%height", context: fixedContext())
        #expect(out == "Safari_2560x1440")
    }

    @Test func missingContextValuesRenderEmpty() {
        let ctx = NameContext(date: fixedContext().date, width: nil, height: nil,
                              processName: nil, increment: 0,
                              calendar: fixedContext().calendar)
        #expect(NameParser.render("%pn|%width|%height", context: ctx) == "||")
    }

    @Test func incrementToken() {
        #expect(NameParser.render("shot_%i", context: fixedContext(increment: 7)) == "shot_7")
    }

    @Test func randomTokensAreDeterministicWithSeededRNG() {
        var rng1 = LCG(state: 42)
        var rng2 = LCG(state: 42)
        let a = NameParser.render("%rn%rn%ra%ra", context: fixedContext(), rng: &rng1)
        let b = NameParser.render("%rn%rn%ra%ra", context: fixedContext(), rng: &rng2)
        #expect(a == b)
        #expect(a.count == 4)
        #expect(a.prefix(2).allSatisfy(\.isNumber))
    }

    @Test func unknownTokensPassThrough() {
        #expect(NameParser.render("a%zzb", context: fixedContext()) == "a%zzb")
    }

    @Test func processNameIsSanitized() {
        var ctx = fixedContext()
        ctx.processName = "My/App: Beta"
        #expect(NameParser.render("%pn", context: ctx) == "My-App- Beta")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'NameParser' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/NameParser.swift`**

```swift
import Foundation

public struct NameContext: Sendable {
    public var date: Date
    public var width: Int?
    public var height: Int?
    public var processName: String?
    public var increment: Int
    public var calendar: Calendar

    public init(date: Date, width: Int?, height: Int?, processName: String?,
                increment: Int, calendar: Calendar = .current) {
        self.date = date
        self.width = width
        self.height = height
        self.processName = processName
        self.increment = increment
        self.calendar = calendar
    }
}

public enum NameParser {
    // Longest tokens first so %mo/%mi/%ms win over shorter prefixes.
    private static let tokenOrder = ["%width", "%height", "%mo", "%mi", "%ms",
                                     "%pn", "%rn", "%ra", "%y", "%d", "%h", "%s", "%i"]

    public static func render(_ template: String, context: NameContext) -> String {
        var rng = SystemRandomNumberGenerator()
        return render(template, context: context, rng: &rng)
    }

    public static func render(_ template: String, context: NameContext,
                              rng: inout some RandomNumberGenerator) -> String {
        let c = context.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: context.date)
        func pad(_ v: Int, _ w: Int) -> String {
            String(format: "%0\(w)d", v)
        }

        var out = ""
        var i = template.startIndex
        outer: while i < template.endIndex {
            if template[i] == "%" {
                for token in tokenOrder where template[i...].hasPrefix(token) {
                    out += value(for: token, comps: c, context: context, pad: pad, rng: &rng)
                    i = template.index(i, offsetBy: token.count)
                    continue outer
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }

    private static func value(for token: String, comps c: DateComponents, context: NameContext,
                              pad: (Int, Int) -> String,
                              rng: inout some RandomNumberGenerator) -> String {
        switch token {
        case "%y": return pad(c.year ?? 0, 4)
        case "%mo": return pad(c.month ?? 0, 2)
        case "%d": return pad(c.day ?? 0, 2)
        case "%h": return pad(c.hour ?? 0, 2)
        case "%mi": return pad(c.minute ?? 0, 2)
        case "%s": return pad(c.second ?? 0, 2)
        case "%ms": return pad((c.nanosecond ?? 0) / 1_000_000, 3)
        case "%width": return context.width.map(String.init) ?? ""
        case "%height": return context.height.map(String.init) ?? ""
        case "%pn": return sanitize(context.processName ?? "")
        case "%i": return String(context.increment)
        case "%rn": return String("0123456789".randomElement(using: &rng)!)
        case "%ra":
            let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            return String(alphabet.randomElement(using: &rng)!)
        default: return token
        }
    }

    static func sanitize(_ name: String) -> String {
        name.map { $0 == "/" || $0 == ":" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all NameParser + SettingsStore tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add ShareX-style filename template parser"
```

---

### Task 5: After-capture pipeline (TDD)

**Files:**
- Create: `Sources/SXCore/CaptureArtifact.swift`
- Create: `Sources/SXCore/AfterCapturePipeline.swift`
- Create: `Tests/SXCoreTests/AfterCapturePipelineTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (Task 3), `NameParser`/`NameContext` (Task 4).
- Produces:
  - `CaptureArtifact(pngData: Data, width: Int, height: Int, capturedAt: Date, appName: String?)`
  - `@MainActor protocol PipelineEffects` with `fileExists(at: URL) -> Bool`, `writeFile(_ data: Data, to: URL) throws`, `copyImageToClipboard(_ pngData: Data)`, `notify(title: String, body: String, fileURL: URL?)`
  - `@MainActor struct AfterCapturePipeline { init(settings: AppSettings, effects: any PipelineEffects); func process(_ artifact: CaptureArtifact) throws -> PipelineResult }`
  - `PipelineResult(savedURL: URL?, copiedToClipboard: Bool)`

  Tasks 7 and 10 consume these exact names.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/AfterCapturePipelineTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

@MainActor
final class MockEffects: PipelineEffects {
    var existing: Set<String> = []
    var written: [(URL, Int)] = []      // (url, byte count)
    var clipboardCopies = 0
    var notifications: [(String, URL?)] = []
    var callOrder: [String] = []

    func fileExists(at url: URL) -> Bool { existing.contains(url.lastPathComponent) }
    func writeFile(_ data: Data, to url: URL) throws {
        callOrder.append("write"); written.append((url, data.count))
    }
    func copyImageToClipboard(_ pngData: Data) {
        callOrder.append("clipboard"); clipboardCopies += 1
    }
    func notify(title: String, body: String, fileURL: URL?) {
        callOrder.append("notify"); notifications.append((body, fileURL))
    }
}

private func artifact() -> CaptureArtifact {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = DateComponents(calendar: cal, year: 2026, month: 7, day: 10,
                              hour: 9, minute: 5, second: 3).date!
    return CaptureArtifact(pngData: Data([1, 2, 3]), width: 100, height: 50,
                           capturedAt: date, appName: "Safari")
}

private func settings() -> AppSettings {
    var s = AppSettings.default
    s.captureSavePath = "/tmp/sxtest"
    s.filenameTemplate = "shot_%y%mo%d"
    return s
}

@MainActor @Suite struct AfterCapturePipelineTests {
    @Test func savesCopiesNotifiesInOrder() throws {
        let fx = MockEffects()
        let result = try AfterCapturePipeline(settings: settings(), effects: fx).process(artifact())
        #expect(fx.callOrder == ["write", "clipboard", "notify"]) // local-first invariant
        #expect(result.savedURL?.path == "/tmp/sxtest/shot_20260710.png")
        #expect(result.copiedToClipboard)
        #expect(fx.written.first?.1 == 3)
        #expect(fx.notifications.first?.1 == result.savedURL)
    }

    @Test func collisionAppendsSuffix() throws {
        let fx = MockEffects()
        fx.existing = ["shot_20260710.png", "shot_20260710_1.png"]
        let result = try AfterCapturePipeline(settings: settings(), effects: fx).process(artifact())
        #expect(result.savedURL?.lastPathComponent == "shot_20260710_2.png")
    }

    @Test func incrementTemplateReRendersOnCollision() throws {
        var s = settings()
        s.filenameTemplate = "shot_%i"
        let fx = MockEffects()
        fx.existing = ["shot_0.png"]
        let result = try AfterCapturePipeline(settings: s, effects: fx).process(artifact())
        #expect(result.savedURL?.lastPathComponent == "shot_1.png")
    }

    @Test func disabledStepsAreSkipped() throws {
        var s = settings()
        s.saveToDisk = false
        s.copyToClipboard = false
        s.showNotification = false
        let fx = MockEffects()
        let result = try AfterCapturePipeline(settings: s, effects: fx).process(artifact())
        #expect(fx.callOrder.isEmpty)
        #expect(result.savedURL == nil)
        #expect(!result.copiedToClipboard)
    }

    @Test func tildePathExpands() throws {
        var s = settings()
        s.captureSavePath = "~/Pictures/ShareX"
        let fx = MockEffects()
        let result = try AfterCapturePipeline(settings: s, effects: fx).process(artifact())
        #expect(result.savedURL!.path.hasPrefix(NSHomeDirectory()))
        #expect(!result.savedURL!.path.contains("~"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find type 'PipelineEffects' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/CaptureArtifact.swift`**

```swift
import Foundation

public struct CaptureArtifact: Sendable {
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let capturedAt: Date
    public let appName: String?

    public init(pngData: Data, width: Int, height: Int, capturedAt: Date, appName: String?) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.appName = appName
    }
}
```

- [ ] **Step 4: Write `Sources/SXCore/AfterCapturePipeline.swift`**

```swift
import Foundation

@MainActor
public protocol PipelineEffects {
    func fileExists(at url: URL) -> Bool
    func writeFile(_ data: Data, to url: URL) throws
    func copyImageToClipboard(_ pngData: Data)
    func notify(title: String, body: String, fileURL: URL?)
}

public struct PipelineResult: Equatable, Sendable {
    public let savedURL: URL?
    public let copiedToClipboard: Bool
}

@MainActor
public struct AfterCapturePipeline {
    private let settings: AppSettings
    private let effects: any PipelineEffects

    public init(settings: AppSettings, effects: any PipelineEffects) {
        self.settings = settings
        self.effects = effects
    }

    public func process(_ artifact: CaptureArtifact) throws -> PipelineResult {
        var savedURL: URL?

        if settings.saveToDisk {
            let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
            let url = resolveCollisions(in: dir, artifact: artifact)
            try effects.writeFile(artifact.pngData, to: url)   // disk first: local-first invariant
            savedURL = url
        }
        if settings.copyToClipboard {
            effects.copyImageToClipboard(artifact.pngData)
        }
        if settings.showNotification {
            let what = savedURL?.lastPathComponent ?? "\(artifact.width)×\(artifact.height) capture"
            effects.notify(title: "Capture complete", body: what, fileURL: savedURL)
        }
        return PipelineResult(savedURL: savedURL, copiedToClipboard: settings.copyToClipboard)
    }

    private func resolveCollisions(in dir: URL, artifact: CaptureArtifact) -> URL {
        func render(increment: Int) -> String {
            let ctx = NameContext(date: artifact.capturedAt, width: artifact.width,
                                  height: artifact.height, processName: artifact.appName,
                                  increment: increment)
            return NameParser.sanitize(NameParser.render(settings.filenameTemplate, context: ctx))
        }
        let usesIncrement = settings.filenameTemplate.contains("%i")
        let base = render(increment: 0)
        var url = dir.appendingPathComponent(base + ".png")
        var n = 1
        while effects.fileExists(at: url) {
            let name = usesIncrement ? render(increment: n) : "\(base)_\(n)"
            url = dir.appendingPathComponent(name + ".png")
            n += 1
        }
        return url
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all tests pass (SettingsStore 4, NameParser 7, Pipeline 5).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add after-capture pipeline with local-first ordering"
```

---

### Task 6: Capture permission gate + display capture + PNG encoder

**Files:**
- Delete: `Sources/SXCapture/SXCapture.swift`
- Create: `Sources/SXCapture/CapturePermission.swift`
- Create: `Sources/SXCapture/ImageEncoder.swift`
- Create: `Sources/SXCapture/DisplayCapture.swift`
- Create: `Tests/SXCaptureTests/ImageEncoderTests.swift`
- Create: `Tests/SXCaptureTests/DisplayCaptureTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `CapturePermission.preflight() -> Bool`, `CapturePermission.request() -> Bool`, `CapturePermission.openSystemSettings()` (all `@MainActor`)
  - `ImageEncoder.png(from: CGImage) -> Data?`
  - `FrozenDisplay` (`displayID: CGDirectDisplayID`, `screenFrame: CGRect` /* AppKit coords */, `image: CGImage`, `scale: CGFloat`)
  - `@MainActor DisplayCapture.captureAllDisplays(showCursor: Bool) async throws -> [FrozenDisplay]`

  Tasks 10 and 11 consume these exact names.

- [ ] **Step 1: Write the tests**

`Tests/SXCaptureTests/ImageEncoderTests.swift`:
```swift
import CoreGraphics
import Foundation
import Testing
@testable import SXCapture

func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite struct ImageEncoderTests {
    @Test func encodesPNGWithMagicBytes() {
        let data = ImageEncoder.png(from: makeTestImage())
        #expect(data != nil)
        #expect(Array(data!.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }
}
```

`Tests/SXCaptureTests/DisplayCaptureTests.swift` (auto-skips where Screen Recording isn't granted, e.g. CI):
```swift
import CoreGraphics
import Testing
@testable import SXCapture

@MainActor @Suite struct DisplayCaptureTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func capturesEveryDisplayAtRetinaScale() async throws {
        let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
        #expect(!displays.isEmpty)
        for d in displays {
            #expect(d.image.width == Int(d.screenFrame.width * d.scale))
            #expect(d.image.height == Int(d.screenFrame.height * d.scale))
            #expect(d.scale >= 1)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'ImageEncoder' in scope`.

- [ ] **Step 3: Write the implementation**

Delete `Sources/SXCapture/SXCapture.swift`.

`Sources/SXCapture/CapturePermission.swift`:
```swift
import AppKit
import CoreGraphics

@MainActor
public enum CapturePermission {
    /// True if Screen Recording is already granted.
    public static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the one-time system prompt; returns current grant state.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
```

`Sources/SXCapture/ImageEncoder.swift`:
```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoder {
    public static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
```

`Sources/SXCapture/DisplayCapture.swift`:
```swift
import AppKit
import ScreenCaptureKit

/// A display frozen at capture time. `screenFrame` is in AppKit screen coordinates (points).
public struct FrozenDisplay: @unchecked Sendable {   // CGImage is immutable; safe to pass
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let image: CGImage
    public let scale: CGFloat
}

public enum CaptureError: Error, LocalizedError {
    case noDisplays
    case noMatchingWindow
    public var errorDescription: String? {
        switch self {
        case .noDisplays: return "No shareable displays found."
        case .noMatchingWindow: return "The selected window is no longer available."
        }
    }
}

@MainActor
public enum DisplayCapture {
    public static func captureAllDisplays(showCursor: Bool) async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var result: [FrozenDisplay] = []
        for display in content.displays {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == display.displayID
            }
            let scale = screen?.backingScaleFactor ?? 2
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = showCursor
            config.colorSpaceName = CGColorSpace.sRGB   // spec §3.1: export in sRGB
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            result.append(FrozenDisplay(
                displayID: display.displayID,
                screenFrame: screen?.frame
                    ?? CGRect(x: 0, y: 0, width: display.width, height: display.height),
                image: image,
                scale: scale))
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: `ImageEncoderTests` passes. `DisplayCaptureTests` passes if the ssh test runner already has Screen Recording permission, otherwise reports as **skipped** — both outcomes are acceptable here; the e2e run in Task 10 proves capture works from the bundled app.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add ScreenCaptureKit display capture and PNG encoding"
```

---

### Task 7: Real pipeline effects (disk, pasteboard, notifications)

**Files:**
- Create: `Sources/SXApp/AppPipelineEffects.swift`

**Interfaces:**
- Consumes: `PipelineEffects` protocol (Task 5).
- Produces: `@MainActor final class AppPipelineEffects: NSObject, PipelineEffects, UNUserNotificationCenterDelegate` with `init()` and `func setUpNotifications()`. Task 10 constructs it and calls `setUpNotifications()` once at launch.

- [ ] **Step 1: Write `Sources/SXApp/AppPipelineEffects.swift`**

```swift
import AppKit
import SXCore
import UserNotifications

@MainActor
final class AppPipelineEffects: NSObject, PipelineEffects, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter requires a real bundle; bare `swift run` has none.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func setUpNotifications() {
        guard notificationsAvailable else {
            NSLog("Notifications unavailable (not running from a bundle)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notification auth error: \(error)") }
            else { NSLog("Notification auth granted: \(granted)") }
        }
    }

    // MARK: PipelineEffects

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func copyImageToClipboard(_ pngData: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
    }

    func notify(title: String, body: String, fileURL: URL?) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL { content.userInfo = ["path": fileURL.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Notification error: \(error)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let path = userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])   // show banners while app is frontmost too
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "Add AppKit pipeline effects for disk, pasteboard, and notifications"
```

---

### Task 8: TCC onboarding window

**Files:**
- Create: `Sources/SXApp/PermissionOnboardingController.swift`

**Interfaces:**
- Consumes: `CapturePermission` (Task 6).
- Produces: `@MainActor final class PermissionOnboardingController` with `static func ensurePermission() -> Bool` — returns `true` if granted; otherwise triggers the system prompt (first time), shows the onboarding window, and returns `false` (caller aborts the capture). Task 10 calls this before every capture.

- [ ] **Step 1: Write `Sources/SXApp/PermissionOnboardingController.swift`**

```swift
import AppKit
import SXCapture

@MainActor
final class PermissionOnboardingController: NSObject {
    private static var shared: PermissionOnboardingController?
    private var window: NSWindow?

    /// True if Screen Recording is granted. Otherwise prompts (first run) and
    /// shows the onboarding window; the caller must abort the capture attempt.
    static func ensurePermission() -> Bool {
        if CapturePermission.preflight() { return true }
        CapturePermission.request()   // triggers the one-time system dialog
        let controller = shared ?? PermissionOnboardingController()
        shared = controller
        controller.show()
        return false
    }

    private func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let text = NSTextField(wrappingLabelWithString: """
        ShareX for Mac needs the Screen Recording permission to capture your screen.

        1. Click “Open System Settings” below.
        2. Enable “ShareX for Mac” under Screen & System Audio Recording.
        3. Click “Relaunch” — macOS applies this permission at app launch.
        """)
        text.frame = NSRect(x: 20, y: 70, width: 380, height: 130)

        let openButton = NSButton(title: "Open System Settings",
                                  target: self, action: #selector(openSettings))
        openButton.frame = NSRect(x: 20, y: 20, width: 180, height: 32)
        let relaunchButton = NSButton(title: "Relaunch",
                                      target: self, action: #selector(relaunch))
        relaunchButton.frame = NSRect(x: 210, y: 20, width: 100, height: 32)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Screen Recording Permission"
        w.contentView?.addSubview(text)
        w.contentView?.addSubview(openButton)
        w.contentView?.addSubview(relaunchButton)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func openSettings() {
        CapturePermission.openSystemSettings()
    }

    @objc private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "Add screen-recording permission onboarding"
```

---

### Task 9: Carbon hotkey manager

**Files:**
- Create: `Sources/SXApp/HotkeyManager.swift`

**Interfaces:**
- Consumes: `HotkeyCombo` (Task 3).
- Produces: `@MainActor final class HotkeyManager` with `init()`, `func register(_ combo: HotkeyCombo, handler: @escaping @MainActor () -> Void)`, `func unregisterAll()`. Task 10 registers the three settings-driven hotkeys.

- [ ] **Step 1: Write `Sources/SXApp/HotkeyManager.swift`**

```swift
import AppKit
import Carbon.HIToolbox
import SXCore

@MainActor
final class HotkeyManager {
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: @MainActor () -> Void)] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x5358_484B   // 'SXHK'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hotkey events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hkID.id
            MainActor.assumeIsolated { manager.fire(id: id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ combo: HotkeyCombo, handler: @escaping @MainActor () -> Void) {
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Hotkey registration failed (keyCode \(combo.keyCode), status \(status))")
            return
        }
        hotKeys[id] = (ref, handler)
    }

    func unregisterAll() {
        for (_, entry) in hotKeys {
            UnregisterEventHotKey(entry.ref)
        }
        hotKeys.removeAll()
    }

    private func fire(id: UInt32) {
        hotKeys[id]?.handler()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "Add Carbon global hotkey manager"
```

---

### Task 10: Capture coordinator, menu/hotkey wiring, fullscreen e2e

**Files:**
- Create: `Sources/SXApp/CaptureCoordinator.swift`
- Modify: `Sources/SXApp/AppDelegate.swift` (replace entirely)

**Interfaces:**
- Consumes: `SettingsStore`/`AppSettings` (Task 3), `AfterCapturePipeline`/`CaptureArtifact` (Task 5), `DisplayCapture`/`FrozenDisplay`/`ImageEncoder` (Task 6), `AppPipelineEffects` (Task 7), `PermissionOnboardingController.ensurePermission()` (Task 8), `HotkeyManager` (Task 9).
- Produces: `@MainActor final class CaptureCoordinator` with `init(settings: AppSettings, effects: AppPipelineEffects)`, `func captureFullscreen()`, `func captureRegion()`, `func captureWindow()`, and internal `func deliver(image: CGImage, appName: String?)` (Tasks 11 and 12 call `deliver` from their sessions and replace the `captureRegion`/`captureWindow` stubs). CLI contract: `--capture fullscreen` performs a capture and terminates (used for e2e verification).

- [ ] **Step 1: Write `Sources/SXApp/CaptureCoordinator.swift`**

```swift
import AppKit
import SXCapture
import SXCore

@MainActor
final class CaptureCoordinator {
    private let settings: AppSettings
    private let effects: AppPipelineEffects

    init(settings: AppSettings, effects: AppPipelineEffects) {
        self.settings = settings
        self.effects = effects
    }

    func captureFullscreen() {
        captureFullscreen(completion: nil)
    }

    /// Captures every display, one artifact per display. Clipboard/notification
    /// effects run per artifact; the last one wins the clipboard (single-display
    /// systems are unaffected). Completion reports how many files were produced.
    func captureFullscreen(completion: (@MainActor (Int) -> Void)?) {
        guard PermissionOnboardingController.ensurePermission() else {
            completion?(0)
            return
        }
        let appName = frontmostAppName()
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                var count = 0
                for display in displays {
                    self.deliver(image: display.image, appName: appName)
                    count += 1
                }
                completion?(count)
            } catch {
                self.reportFailure(error)
                completion?(0)
            }
        }
    }

    func captureRegion() {
        // Replaced with the region overlay session in Task 11.
        NSLog("Region capture not implemented yet")
    }

    func captureWindow() {
        // Replaced with the window picker session in Task 12.
        NSLog("Window capture not implemented yet")
    }

    func deliver(image: CGImage, appName: String?) {
        guard let png = ImageEncoder.png(from: image) else {
            NSLog("PNG encoding failed")
            return
        }
        let artifact = CaptureArtifact(pngData: png, width: image.width, height: image.height,
                                       capturedAt: Date(), appName: appName)
        do {
            let result = try AfterCapturePipeline(settings: settings, effects: effects)
                .process(artifact)
            NSLog("Capture delivered: \(result.savedURL?.path ?? "clipboard only")")
        } catch {
            reportFailure(error)
        }
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func reportFailure(_ error: Error) {
        NSLog("Capture failed: \(error)")
        effects.notify(title: "Capture failed", body: error.localizedDescription, fileURL: nil)
    }
}
```

- [ ] **Step 2: Replace `Sources/SXApp/AppDelegate.swift`**

```swift
import AppKit
import SXCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyManager?
    private var coordinator: CaptureCoordinator?
    private let effects = AppPipelineEffects()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, issue) = store.loadOrDefault()
        if case .corruptBackedUp(let backup)? = issue {
            NSLog("Settings were corrupt; backed up to \(backup.path) and reset to defaults")
            effects.notify(title: "Settings reset",
                           body: "Corrupt settings backed up to \(backup.lastPathComponent)",
                           fileURL: nil)
        }
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            try? store.save(settings)   // materialize defaults for hand-editing
        }

        effects.setUpNotifications()
        let coordinator = CaptureCoordinator(settings: settings, effects: effects)
        self.coordinator = coordinator
        statusItem = StatusItemController(menu: buildMenu())
        registerHotkeys(settings.hotkeys)
        NSLog("ShareX for Mac launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")

        handleCLIArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
    }

    private func registerHotkeys(_ config: HotkeySettings) {
        let manager = HotkeyManager()
        hotkeys = manager
        if let combo = config.fullscreen {
            manager.register(combo) { [weak self] in self?.coordinator?.captureFullscreen() }
        }
        if let combo = config.region {
            manager.register(combo) { [weak self] in self?.coordinator?.captureRegion() }
        }
        if let combo = config.window {
            manager.register(combo) { [weak self] in self?.coordinator?.captureWindow() }
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Capture Region", #selector(menuCaptureRegion)))
        menu.addItem(menuItem("Capture Window", #selector(menuCaptureWindow)))
        menu.addItem(menuItem("Capture Full Screen", #selector(menuCaptureFullscreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuCaptureRegion() { coordinator?.captureRegion() }
    @objc private func menuCaptureWindow() { coordinator?.captureWindow() }
    @objc private func menuCaptureFullscreen() { coordinator?.captureFullscreen() }

    @objc private func openCapturesFolder() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, _) = store.loadOrDefault()
        let path = (settings.captureSavePath as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Debug/e2e hook: `open -n "ShareX for Mac.app" --args --capture fullscreen`
    /// captures and exits, so the flow is verifiable over ssh.
    private func handleCLIArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture"), args.count > i + 1 else { return }
        switch args[i + 1] {
        case "fullscreen":
            coordinator?.captureFullscreen { count in
                NSLog("CLI capture finished (\(count) file(s)); terminating")
                // Give the notification a beat to post before exiting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            }
        case "region":
            coordinator?.captureRegion()
        case "window":
            coordinator?.captureWindow()
        default:
            NSLog("Unknown --capture mode: \(args[i + 1])")
        }
    }
}
```

- [ ] **Step 3: Build and run the full test suite**

Run: `scripts/remote.sh test`
Expected: build succeeds; all unit tests still pass.

- [ ] **Step 4: One-time manual TCC grant (needs the user at the Mac)**

Run: `scripts/remote.sh run`
Then ask the user to, on the Mac: click the menu-bar camera icon → **Capture Full Screen** → the permission window appears → grant Screen Recording in System Settings → click **Relaunch** in the onboarding window.

**Blocker note for executors:** this step needs a human at the Mac. Pause and ask; do not skip. Rebuilds with ad-hoc signing may occasionally re-trigger the TCC prompt (signature changes) — if later e2e steps fail with 0 files, re-run this grant flow before debugging code.

- [ ] **Step 5: Verify fullscreen e2e over ssh**

Run: `scripts/remote.sh ssh 'rm -rf ~/Pictures/ShareX && open -n "dist/ShareX for Mac.app" --args --capture fullscreen && sleep 6 && ls ~/Pictures/ShareX/'`
Expected: at least one `Screenshot_2026-*.png` listed.

Run: `scripts/remote.sh ssh 'file ~/Pictures/ShareX/*.png'`
Expected: `PNG image data` with the Mac's pixel dimensions (e.g. `5120 x 2880`).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Wire capture coordinator, hotkeys, and fullscreen flow"
```

---

### Task 11: Region overlay capture

**Files:**
- Create: `Sources/SXCapture/CaptureGeometry.swift`
- Create: `Tests/SXCaptureTests/CaptureGeometryTests.swift`
- Create: `Sources/SXApp/RegionOverlay.swift`
- Modify: `Sources/SXApp/CaptureCoordinator.swift` (replace `captureRegion()` body; add `regionSession` property)

**Interfaces:**
- Consumes: `FrozenDisplay`, `DisplayCapture` (Task 6), `CaptureCoordinator.deliver(image:appName:)` (Task 10).
- Produces: `CaptureGeometry.normalizedRect(from:to:)`, `CaptureGeometry.pixelCropRect(selection:scale:imageWidth:imageHeight:)`; `@MainActor final class RegionOverlaySession { init(displays: [FrozenDisplay], onComplete: @escaping @MainActor (CGImage?) -> Void); func begin() }`. Selection is constrained to the display where the drag starts (single-display selection; cross-display spans are out of M1 scope).

- [ ] **Step 1: Write failing geometry tests `Tests/SXCaptureTests/CaptureGeometryTests.swift`**

```swift
import CoreGraphics
import Testing
@testable import SXCapture

@Suite struct CaptureGeometryTests {
    @Test func normalizesDragInAnyDirection() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 100, y: 80),
                                               to: CGPoint(x: 20, y: 200))
        #expect(r == CGRect(x: 20, y: 80, width: 80, height: 120))
    }

    @Test func scalesSelectionToPixelsAndClamps() {
        // 2x display, image 200x100 px; selection 10,10 50x30 pt -> 20,20 100x60 px
        let r = CaptureGeometry.pixelCropRect(selection: CGRect(x: 10, y: 10, width: 50, height: 30),
                                              scale: 2, imageWidth: 200, imageHeight: 100)
        #expect(r == CGRect(x: 20, y: 20, width: 100, height: 60))
        // Selection hanging off the edge clamps to image bounds.
        let clamped = CaptureGeometry.pixelCropRect(selection: CGRect(x: 90, y: 40, width: 50, height: 30),
                                                    scale: 2, imageWidth: 200, imageHeight: 100)
        #expect(clamped == CGRect(x: 180, y: 80, width: 20, height: 20))
    }

    @Test func zeroSizeSelectionYieldsZeroRect() {
        let r = CaptureGeometry.pixelCropRect(selection: .zero, scale: 2,
                                              imageWidth: 200, imageHeight: 100)
        #expect(r.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'CaptureGeometry' in scope`.

- [ ] **Step 3: Write `Sources/SXCapture/CaptureGeometry.swift`**

```swift
import CoreGraphics

public enum CaptureGeometry {
    /// Rect from two drag points, any drag direction.
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// View-point selection (top-left origin, same space as the frozen image)
    /// -> pixel crop rect, clamped to image bounds.
    public static func pixelCropRect(selection: CGRect, scale: CGFloat,
                                     imageWidth: Int, imageHeight: Int) -> CGRect {
        let scaled = CGRect(x: selection.origin.x * scale, y: selection.origin.y * scale,
                            width: selection.width * scale, height: selection.height * scale)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        return scaled.intersection(bounds).integral
    }
}
```

- [ ] **Step 4: Run geometry tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all tests pass.

- [ ] **Step 5: Write `Sources/SXApp/RegionOverlay.swift`**

```swift
import AppKit
import SXCapture

// Borderless windows refuse key status by default; we need it for Esc.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionOverlaySession {
    private var windows: [NSWindow] = []
    private let displays: [FrozenDisplay]
    private let onComplete: @MainActor (CGImage?) -> Void
    private var finished = false

    init(displays: [FrozenDisplay], onComplete: @escaping @MainActor (CGImage?) -> Void) {
        self.displays = displays
        self.onComplete = onComplete
    }

    func begin() {
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
        NSApp.activate()
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
        let crop = CaptureGeometry.pixelCropRect(selection: selection, scale: display.scale,
                                                 imageWidth: display.image.width,
                                                 imageHeight: display.image.height)
        guard !crop.isEmpty, let cropped = display.image.cropping(to: crop) else {
            onComplete(nil); return
        }
        onComplete(cropped)
    }
}

@MainActor
private final class RegionSelectionView: NSView {
    private let display: FrozenDisplay
    private let onDone: (CGRect?) -> Void
    private var frozenImage: NSImage
    private var dragStart: CGPoint?
    private var current: CGPoint = .zero
    private var hasMouse = false

    // Flipped: view coords are top-left origin, matching the frozen image.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(display: FrozenDisplay, onDone: @escaping (CGRect?) -> Void) {
        self.display = display
        self.onDone = onDone
        self.frozenImage = NSImage(cgImage: display.image,
                                   size: display.screenFrame.size)
        super.init(frame: CGRect(origin: .zero, size: display.screenFrame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Frozen desktop, dimmed.
        frozenImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        let selection = dragStart.map { CaptureGeometry.normalizedRect(from: $0, to: current) }

        // Selected area shown undimmed.
        if let selection {
            NSGraphicsContext.current?.saveGraphicsState()
            selection.clip()
            frozenImage.draw(in: bounds)
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1
            outline.stroke()
            drawLabel("\(Int(selection.width * display.scale)) × \(Int(selection.height * display.scale))",
                      at: CGPoint(x: selection.minX, y: selection.maxY + 6))
        }

        if hasMouse {
            drawCrosshair()
            drawLoupe()
        }
    }

    private func drawCrosshair() {
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let h = NSBezierPath()
        h.move(to: CGPoint(x: 0, y: current.y))
        h.line(to: CGPoint(x: bounds.maxX, y: current.y))
        let v = NSBezierPath()
        v.move(to: CGPoint(x: current.x, y: 0))
        v.line(to: CGPoint(x: current.x, y: bounds.maxY))
        h.lineWidth = 1; v.lineWidth = 1
        h.stroke(); v.stroke()
    }

    /// 8x loupe of the frozen image around the cursor, offset to stay visible.
    private func drawLoupe() {
        let loupeSize: CGFloat = 120
        let zoom: CGFloat = 8
        let srcSide = loupeSize / zoom * display.scale
        let src = CGRect(x: current.x * display.scale - srcSide / 2,
                         y: current.y * display.scale - srcSide / 2,
                         width: srcSide, height: srcSide)
        guard let sub = display.image.cropping(to: src) else { return }

        var origin = CGPoint(x: current.x + 24, y: current.y + 24)
        if origin.x + loupeSize > bounds.maxX { origin.x = current.x - 24 - loupeSize }
        if origin.y + loupeSize > bounds.maxY { origin.y = current.y - 24 - loupeSize }
        let dest = CGRect(origin: origin, size: CGSize(width: loupeSize, height: loupeSize))

        NSGraphicsContext.current?.imageInterpolation = .none   // crisp pixels
        NSImage(cgImage: sub, size: dest.size).draw(in: dest)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: dest)
        border.lineWidth = 2
        border.stroke()
        drawLabel(String(format: "%.0f, %.0f", current.x * display.scale, current.y * display.scale),
                  at: CGPoint(x: dest.minX, y: dest.maxY + 4))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        NSAttributedString(string: " \(text) ", attributes: attrs).draw(at: point)
    }

    override func mouseEntered(with event: NSEvent) { hasMouse = true }
    override func mouseExited(with event: NSEvent) { hasMouse = false; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved,
                                                 .mouseEnteredAndExited],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hasMouse = true
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        current = dragStart!
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        current = convert(event.locationInWindow, from: nil)
        let selection = CaptureGeometry.normalizedRect(from: start, to: current)
        // A sub-4pt drag is a slip, not a selection.
        onDone(selection.width >= 4 && selection.height >= 4 ? selection : nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onDone(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
```

- [ ] **Step 6: Wire into `CaptureCoordinator`**

In `Sources/SXApp/CaptureCoordinator.swift`, add a stored property after `private let effects: AppPipelineEffects`:

```swift
    private var regionSession: RegionOverlaySession?
```

Replace the `captureRegion()` stub with:

```swift
    func captureRegion() {
        guard PermissionOnboardingController.ensurePermission() else { return }
        guard regionSession == nil else { return }   // one overlay at a time
        let appName = frontmostAppName()
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                let session = RegionOverlaySession(displays: displays) { [weak self] image in
                    self?.regionSession = nil
                    if let image {
                        self?.deliver(image: image, appName: appName)
                    }
                }
                self.regionSession = session
                session.begin()
            } catch {
                self.reportFailure(error)
            }
        }
    }
```

- [ ] **Step 7: Build + tests**

Run: `scripts/remote.sh test`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Manual smoke (needs the user at the Mac)**

Run: `scripts/remote.sh run`
Ask the user to press **⌥⇧4** on the Mac and verify: frozen dimmed screen; crosshair + loupe + coordinate label follow the mouse; drag shows undimmed selection with pixel dimensions; release saves + copies + notifies; **Esc** cancels cleanly; multi-display shows the overlay on every screen. Then confirm the file: `scripts/remote.sh ssh 'ls -t ~/Pictures/ShareX | head -3'`.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "Add region capture with freeze-frame overlay, crosshair, and loupe"
```

---

### Task 12: Window picker capture

**Files:**
- Create: `Sources/SXCapture/WindowCapture.swift`
- Create: `Tests/SXCaptureTests/WindowFilterTests.swift`
- Create: `Sources/SXApp/WindowPickerSession.swift`
- Modify: `Sources/SXApp/CaptureCoordinator.swift` (replace `captureWindow()` body; add `windowSession` property)

**Interfaces:**
- Consumes: `PermissionOnboardingController`, `CaptureCoordinator.deliver(image:appName:)`, `FrozenDisplay` pattern (Task 6/10/11).
- Produces:
  - `WindowCandidate(windowID: UInt32, title: String?, appName: String?, appBundleID: String?, frame: CGRect /* CG global, top-left origin */, layer: Int, isOnScreen: Bool)`
  - `WindowFilter.selectable(from: [WindowCandidate], excludingBundleID: String?) -> [WindowCandidate]`
  - `@MainActor WindowCapture.candidates(excludingBundleID: String?) async throws -> [WindowCandidate]` and `WindowCapture.capture(windowID: UInt32) async throws -> CGImage`
  - `@MainActor final class WindowPickerSession { init(candidates: [WindowCandidate], onPick: @escaping @MainActor (WindowCandidate?) -> Void); func begin() }`

- [ ] **Step 1: Write failing filter tests `Tests/SXCaptureTests/WindowFilterTests.swift`**

```swift
import CoreGraphics
import Testing
@testable import SXCapture

private func candidate(id: UInt32 = 1, title: String? = "Doc", app: String? = "Safari",
                       bundle: String? = "com.apple.Safari",
                       frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                       layer: Int = 0, onScreen: Bool = true) -> WindowCandidate {
    WindowCandidate(windowID: id, title: title, appName: app, appBundleID: bundle,
                    frame: frame, layer: layer, isOnScreen: onScreen)
}

@Suite struct WindowFilterTests {
    @Test func keepsNormalWindows() {
        let result = WindowFilter.selectable(from: [candidate()], excludingBundleID: nil)
        #expect(result.count == 1)
    }

    @Test func dropsOwnAppMenuBarLayersOffscreenAndTiny() {
        let windows = [
            candidate(id: 1, bundle: "org.sharexmac.app"),                     // own app
            candidate(id: 2, layer: 25),                                       // status bar layer
            candidate(id: 3, onScreen: false),                                 // hidden
            candidate(id: 4, frame: CGRect(x: 0, y: 0, width: 30, height: 20)),// tiny
            candidate(id: 5, title: nil, app: nil, bundle: nil),               // anonymous
            candidate(id: 6),                                                  // keeper
        ]
        let result = WindowFilter.selectable(from: windows,
                                             excludingBundleID: "org.sharexmac.app")
        #expect(result.map(\.windowID) == [6])
    }

    @Test func sortsByAreaDescendingSoClickHitsSmallestLast() {
        let windows = [
            candidate(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
        ]
        let result = WindowFilter.selectable(from: windows, excludingBundleID: nil)
        #expect(result.map(\.windowID) == [2, 1])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'WindowCandidate' in scope`.

- [ ] **Step 3: Write `Sources/SXCapture/WindowCapture.swift`**

```swift
import AppKit
import ScreenCaptureKit

/// `frame` is in CoreGraphics global coordinates (origin top-left of primary display).
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let title: String?
    public let appName: String?
    public let appBundleID: String?
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    public init(windowID: UInt32, title: String?, appName: String?, appBundleID: String?,
                frame: CGRect, layer: Int, isOnScreen: Bool) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.appBundleID = appBundleID
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

public enum WindowFilter {
    /// Pickable windows: normal layer, on screen, big enough to be intentional,
    /// owned by an identifiable app, not ourselves. Sorted by area descending so
    /// hit-testing (last match wins) picks the smallest window under the cursor.
    public static func selectable(from windows: [WindowCandidate],
                                  excludingBundleID: String?) -> [WindowCandidate] {
        windows.filter { w in
            w.layer == 0
                && w.isOnScreen
                && w.frame.width >= 50 && w.frame.height >= 50
                && (w.appName != nil || w.title != nil)
                && (excludingBundleID == nil || w.appBundleID != excludingBundleID)
        }
        .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }
}

@MainActor
public enum WindowCapture {
    public static func candidates(excludingBundleID: String?) async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let mapped = content.windows.map { w in
            WindowCandidate(windowID: w.windowID,
                            title: w.title,
                            appName: w.owningApplication?.applicationName,
                            appBundleID: w.owningApplication?.bundleIdentifier,
                            frame: w.frame,
                            layer: w.windowLayer,
                            isOnScreen: w.isOnScreen)
        }
        return WindowFilter.selectable(from: mapped, excludingBundleID: excludingBundleID)
    }

    public static func capture(windowID: UInt32) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noMatchingWindow
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB   // spec §3.1: export in sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all tests pass.

- [ ] **Step 5: Write `Sources/SXApp/WindowPickerSession.swift`**

```swift
import AppKit
import SXCapture

// Full-screen transparent overlays; hovering highlights the window under the
// cursor, click picks it, Esc cancels.
@MainActor
final class WindowPickerSession {
    private var windows: [NSWindow] = []
    private let candidates: [WindowCandidate]
    private let onPick: @MainActor (WindowCandidate?) -> Void
    private var finished = false

    init(candidates: [WindowCandidate], onPick: @escaping @MainActor (WindowCandidate?) -> Void) {
        self.candidates = candidates
        self.onPick = onPick
    }

    func begin() {
        guard !candidates.isEmpty else { onPick(nil); return }
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = WindowPickerView(candidates: candidates, screen: screen) { [weak self] pick in
                self?.finish(pick)
            }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate()
    }

    private func finish(_ pick: WindowCandidate?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onPick(pick)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class WindowPickerView: NSView {
    private let candidates: [WindowCandidate]
    private let screen: NSScreen
    private let onDone: (WindowCandidate?) -> Void
    private var hovered: WindowCandidate?

    init(candidates: [WindowCandidate], screen: NSScreen,
         onDone: @escaping (WindowCandidate?) -> Void) {
        self.candidates = candidates
        self.screen = screen
        self.onDone = onDone
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }

    /// CG global (top-left origin) -> this view's coordinates (bottom-left origin).
    private func viewRect(fromCGGlobal rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        let appKit = CGRect(x: rect.origin.x,
                            y: primaryHeight - rect.origin.y - rect.height,
                            width: rect.width, height: rect.height)
        return CGRect(x: appKit.origin.x - screen.frame.origin.x,
                      y: appKit.origin.y - screen.frame.origin.y,
                      width: appKit.width, height: appKit.height)
    }

    private func candidateAt(viewPoint p: CGPoint) -> WindowCandidate? {
        // candidates are sorted area-descending; last hit = smallest window.
        candidates.last { viewRect(fromCGGlobal: $0.frame).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let hovered else { return }
        let rect = viewRect(fromCGGlobal: hovered.frame)
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        path.stroke()

        let label = "\(hovered.appName ?? "?") — \(hovered.title ?? "Untitled")"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        NSAttributedString(string: " \(label) ", attributes: attrs)
            .draw(at: CGPoint(x: rect.minX + 8, y: rect.maxY - 28))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = candidateAt(viewPoint: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onDone(candidateAt(viewPoint: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onDone(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
```

- [ ] **Step 6: Wire into `CaptureCoordinator`**

In `Sources/SXApp/CaptureCoordinator.swift`, add after `private var regionSession: RegionOverlaySession?`:

```swift
    private var windowSession: WindowPickerSession?
```

Replace the `captureWindow()` stub with:

```swift
    func captureWindow() {
        guard PermissionOnboardingController.ensurePermission() else { return }
        guard windowSession == nil else { return }
        Task { @MainActor in
            do {
                let candidates = try await WindowCapture.candidates(
                    excludingBundleID: Bundle.main.bundleIdentifier)
                let session = WindowPickerSession(candidates: candidates) { [weak self] pick in
                    self?.windowSession = nil
                    guard let self, let pick else { return }
                    Task { @MainActor in
                        do {
                            let image = try await WindowCapture.capture(windowID: pick.windowID)
                            self.deliver(image: image, appName: pick.appName)
                        } catch {
                            self.reportFailure(error)
                        }
                    }
                }
                self.windowSession = session
                session.begin()
            } catch {
                self.reportFailure(error)
            }
        }
    }
```

- [ ] **Step 7: Build + tests**

Run: `scripts/remote.sh test`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Manual smoke (needs the user at the Mac)**

Run: `scripts/remote.sh run`
Ask the user to press **⌥⇧5**: dim overlay appears; hovering highlights individual windows with app — title label; clicking captures just that window (check the saved PNG shows only the window); Esc cancels.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "Add window capture with hover-highlight picker"
```

---

### Task 13: CI, porting map, smoke checklist, publish gate

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `docs/porting-map.md`
- Create: `docs/smoke-m1.md`
- Modify: `README.md` (replace the status line)

**Interfaces:**
- Consumes: everything (this is the wrap-up task).
- Produces: CI pipeline; documentation contributors and later milestones rely on.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Swift version
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

(Capture tests self-skip on the runner via `.enabled(if: CGPreflightScreenCaptureAccess())` — headless runners have no Screen Recording grant.)

- [ ] **Step 2: Write `docs/porting-map.md`**

```markdown
# Porting map — Swift type → ShareX reference

The ShareX repo (`~/git/sharex`, read-only) is the behavioral spec. When
behavior is unclear, read the reference class before inventing semantics.
The repowise MCP index and `sharex-audit-digest.txt` in that repo locate
things fast.

| Swift (this repo) | ShareX reference | Notes |
|---|---|---|
| `SXCore/AppSettings` | `ShareX/ApplicationConfig.cs`, `TaskSettings.cs` | Tiny M1 subset; grows per milestone |
| `SXCore/SettingsStore` | `ShareX.HelpersLib` `SettingsBase.cs` | Corrupt-file backup replaces ShareX's silent error swallowing |
| `SXCore/NameParser` | `ShareX.HelpersLib` `NameParser.cs` | M1 tokens: %y %mo %d %h %mi %s %ms %rn %ra %width %height %pn %i. `%n` intentionally omitted — verify ShareX semantics before adding in M2 |
| `SXCore/AfterCapturePipeline` | `ShareX` `WorkerTask.cs`, `AfterCaptureTasks` enum | M1 chain: save → clipboard → notify; upload chain lands in M2 |
| `SXCapture/DisplayCapture` | `ShareX.ScreenCaptureLib` `Screenshot.cs` | GDI BitBlt → SCScreenshotManager |
| `SXCapture/WindowCapture`/`WindowFilter` | `ShareX.ScreenCaptureLib` `WindowsList.cs`, `Screenshot_Window.cs` | EnumWindows → SCShareableContent |
| `SXCapture/CaptureGeometry` | `ShareX.ScreenCaptureLib` `CaptureHelpers.cs` | |
| `SXApp/RegionOverlay` | `ShareX.ScreenCaptureLib` `RegionCaptureForm.cs` | Freeze-frame model; single-display selection in M1 |
| `SXApp/HotkeyManager` | `ShareX.HelpersLib` `HotkeyManager.cs` | RegisterHotKey → Carbon RegisterEventHotKey |
| `SXApp/PermissionOnboardingController` | (none — macOS TCC concept) | |
| `SXApp/AppPipelineEffects` | `ShareX` `ClipboardHelpers.cs`, toast notifications | |
```

- [ ] **Step 3: Write `docs/smoke-m1.md`**

```markdown
# M1 manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. All boxes must pass to call M1 done.

- [ ] Menu-bar camera icon appears; menu lists Region / Window / Full Screen / Open Captures Folder / Quit
- [ ] First capture attempt without permission shows onboarding; System Settings deep-link works; Relaunch works
- [ ] ⌥⇧3 captures all displays → one PNG per display in ~/Pictures/ShareX, image on clipboard (⌘V into Preview), notification appears
- [ ] Notification click reveals the file in Finder
- [ ] ⌥⇧4 shows frozen dimmed overlay: crosshair, loupe with pixel coordinates, drag shows live px dimensions, release saves+copies+notifies
- [ ] ⌥⇧4 then Esc cancels; no file written, overlays gone
- [ ] ⌥⇧5 hover-highlights windows with app — title label; click captures only that window; Esc cancels
- [ ] Multi-display (if attached): overlays on all screens; capture from a secondary display is correct and Retina-sharp
- [ ] Filenames match Screenshot_YYYY-MM-DD_HH-MM-SS.png; second capture in the same second gets _1 suffix
- [ ] Quit from menu; pgrep -x SXApp confirms exit
```

- [ ] **Step 4: Update `README.md` status line**

Replace:
```markdown
**Status:** design phase. See [`docs/superpowers/specs/2026-07-10-sharex-mac-design.md`](docs/superpowers/specs/2026-07-10-sharex-mac-design.md).
```
with:
```markdown
**Status:** M1 (capture core) — menu-bar app with fullscreen/region/window capture, global hotkeys, clipboard + disk + notifications. Design: [`docs/superpowers/specs/2026-07-10-sharex-mac-design.md`](docs/superpowers/specs/2026-07-10-sharex-mac-design.md) · Build: `scripts/remote.sh build` (see spec §4 for the SSH dev loop).
```

- [ ] **Step 5: Full test run + commit**

Run: `scripts/remote.sh test`
Expected: all tests pass.

```bash
git add -A && git commit -m "Add CI workflow, porting map, and M1 smoke checklist"
```

- [ ] **Step 6: Publish gate (requires user confirmation)**

Ask the user: "Ready to publish sharex-mac publicly on GitHub?" If yes:

```bash
gh repo create sharex-mac --public --source /home/bseitz/git/sharex-mac --push
```

Expected: repo URL printed; CI goes green on the first push. If the user declines or `gh` is unauthenticated, skip — publishing is not an M1 exit criterion.

- [ ] **Step 7: Run the full M1 smoke checklist with the user**

Walk through `docs/smoke-m1.md` together. M1 is complete when every box is checked.
