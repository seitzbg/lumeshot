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
