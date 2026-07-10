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

