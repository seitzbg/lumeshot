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
