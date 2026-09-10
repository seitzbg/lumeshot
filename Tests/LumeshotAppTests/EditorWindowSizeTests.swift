import AppKit
import Testing
@testable import LumeshotApp

@MainActor
@Suite struct EditorWindowSizeTests {
    // Chrome added around the canvas (kept in step with EditorWindowController).
    private let rail: CGFloat = 191
    private let topBar: CGFloat = 45
    private let bigScreen = CGSize(width: 3840, height: 2160)

    /// A capture that comfortably fits opens at ~1:1: image points (pixels ÷ backing
    /// scale) plus the surrounding chrome, unclamped. This is the "window matches what
    /// you grabbed" contract.
    @Test func fittingCaptureOpensAtOneToOne() {
        let size = EditorWindowController.editorContentSize(
            imagePixelSize: CGSize(width: 2000, height: 1200), // 1000×600 pt at 2×
            backingScale: 2, visibleFrame: bigScreen)
        #expect(size.width == 1000 + rail)
        #expect(size.height == 600 + topBar)
    }

    /// A capture larger than the display is capped to 90% of the visible frame (so it
    /// fits and the canvas scales it down), never spilling off-screen.
    @Test func oversizedCaptureIsCappedToScreen() {
        let visible = CGSize(width: 2560, height: 1440)
        let size = EditorWindowController.editorContentSize(
            imagePixelSize: CGSize(width: 8000, height: 6000), // 4000×3000 pt at 2×
            backingScale: 2, visibleFrame: visible)
        #expect(size.width == visible.width * 0.9)
        #expect(size.height == visible.height * 0.9)
    }

    /// A tiny capture never produces a window below the usable minimum — the "opened very
    /// small" regression guard.
    @Test func tinyCaptureFloorsAtMinimum() {
        let size = EditorWindowController.editorContentSize(
            imagePixelSize: CGSize(width: 120, height: 120), // 60×60 pt at 2×
            backingScale: 2, visibleFrame: bigScreen)
        #expect(size.width == 760)
        #expect(size.height == 480)
    }
}
