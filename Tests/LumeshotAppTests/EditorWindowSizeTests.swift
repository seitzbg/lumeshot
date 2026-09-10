import AppKit
import Testing
@testable import LumeshotApp

@MainActor
@Suite struct EditorWindowSizeTests {
    /// The editor must never open below the size that made markup feel cramped, and must
    /// stay within the preferred cap (which `defaultContentSize` also clamps to the
    /// visible screen). This guards the "the edit window opened very small" regression.
    @Test func defaultSizeIsComfortableAndClamped() {
        let size = EditorWindowController.defaultContentSize()
        #expect(size.width >= 760 && size.width <= 1200)
        #expect(size.height >= 480 && size.height <= 780)
    }
}
