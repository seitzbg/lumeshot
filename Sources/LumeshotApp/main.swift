import AppKit

// `--version` runs before any AppKit state is created and exits immediately.
// Besides being useful on its own, it gives packaging a launch smoke test that
// exercises dynamic-library resolution — the assembled bundle must find
// Sparkle.framework via @rpath — without starting the menu-bar app. Starting a
// second instance would be actively harmful: requesting a protected resource
// from an ad-hoc build re-points the Screen Recording TCC grant away from the
// installed release. This path touches no capture API, so it cannot.
if CommandLine.arguments.contains("--version") {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "development"
    let channel = info?["LumeshotReleaseChannel"] as? String ?? "development"
    print("Lumeshot \(version) (\(channel))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
