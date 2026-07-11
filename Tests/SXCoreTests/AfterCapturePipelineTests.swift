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
    var textCopies: [String] = []
    var urlNotifications: [(String, String)] = []   // (body, url)

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
    func copyTextToClipboard(_ text: String) {
        callOrder.append("copyText"); textCopies.append(text)
    }
    func notifyURL(title: String, body: String, url: String) {
        callOrder.append("notifyURL"); urlNotifications.append((body, url))
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
