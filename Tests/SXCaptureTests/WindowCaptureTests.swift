import CoreGraphics
import Testing
// @preconcurrency: see DisplayCapture.swift — keeps the non-Sendable
// SCShareableContent building under Swift 6 strict concurrency on this SDK.
@preconcurrency import ScreenCaptureKit
@testable import SXCapture

@MainActor @Suite struct WindowCaptureTests {
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
