import CoreGraphics
import Testing
@testable import LumeshotCapture

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
}
