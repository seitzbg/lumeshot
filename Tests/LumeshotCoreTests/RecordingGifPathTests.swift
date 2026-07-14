import Foundation
import Testing
@testable import LumeshotCore

@Suite struct RecordingGifPathTests {
    @Test func isVideoRecognizesMp4AndMov() {
        #expect(MIMEType.isVideo(path: "/tmp/a.mp4"))
        #expect(MIMEType.isVideo(path: "/tmp/A.MOV"))
        #expect(!MIMEType.isVideo(path: "/tmp/a.png"))
        #expect(!MIMEType.isVideo(path: "/tmp/a.gif"))
    }

    @Test func gifOutputURLReplacesTheExtension() {
        let src = URL(fileURLWithPath: "/tmp/sx/Recording_1.mp4")
        let url = RecordingDelivery.gifOutputURL(for: src, fileExists: { _ in false })
        #expect(url.path == "/tmp/sx/Recording_1.gif")
    }

    @Test func gifOutputURLAppendsANumericSuffixOnCollision() {
        let src = URL(fileURLWithPath: "/tmp/sx/Recording_1.mp4")
        let seen: Set<String> = ["/tmp/sx/Recording_1.gif"]
        let url = RecordingDelivery.gifOutputURL(for: src, fileExists: { seen.contains($0.path) })
        #expect(url.path == "/tmp/sx/Recording_1_1.gif")
    }
}
