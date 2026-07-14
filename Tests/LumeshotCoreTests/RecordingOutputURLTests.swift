import Foundation
import Testing
@testable import LumeshotCore

@Suite struct RecordingOutputURLTests {
    private func settings(template: String = "Recording_%y-%mo-%d_%h-%mi-%s") -> AppSettings {
        var s = AppSettings.default
        s.captureSavePath = "/tmp/sxrectest"
        s.filenameTemplate = template
        return s
    }

    private func date() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return DateComponents(calendar: cal, year: 2026, month: 7, day: 12,
                              hour: 10, minute: 30, second: 0).date!
    }

    /// `RecordingDelivery.outputURL` renders `capturedAt` through `NameContext`'s
    /// default `.current` calendar (local wall-clock time), matching
    /// `AfterCapturePipeline.resolveCollisions` for stills. Computing the expected
    /// stamp the same way keeps the test deterministic on any machine/timezone
    /// instead of hardcoding a UTC-only literal.
    private func expectedStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    @Test func rendersTheTemplateWithAnMp4Extension() {
        let url = RecordingDelivery.outputURL(settings: settings(), capturedAt: date(),
                                              appName: "Safari", fileExists: { _ in false })
        #expect(url.path == "/tmp/sxrectest/Recording_\(expectedStamp(date())).mp4")
    }

    @Test func appendsANumericSuffixOnCollision() {
        let stamp = expectedStamp(date())
        let seen: Set<String> = ["/tmp/sxrectest/Recording_\(stamp).mp4"]
        let url = RecordingDelivery.outputURL(settings: settings(), capturedAt: date(),
                                              appName: nil, fileExists: { seen.contains($0.path) })
        #expect(url.path == "/tmp/sxrectest/Recording_\(stamp)_1.mp4")
    }

    @Test func processNameTokenUsesTheAppNameArgument() {
        let url = RecordingDelivery.outputURL(settings: settings(template: "rec_%pn"),
                                              capturedAt: date(), appName: "Safari",
                                              fileExists: { _ in false })
        #expect(url.lastPathComponent == "rec_Safari.mp4")
    }
}
