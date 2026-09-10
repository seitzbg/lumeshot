import Foundation
import Testing
@testable import LumeshotCore

@Suite struct RecordingElapsedTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func formatsMinutesAndZeroPaddedSeconds() {
        #expect(RecordingElapsed.label(since: start, now: start) == "0:00")
        #expect(RecordingElapsed.label(since: start, now: start.addingTimeInterval(7)) == "0:07")
        #expect(RecordingElapsed.label(since: start, now: start.addingTimeInterval(65)) == "1:05")
        #expect(RecordingElapsed.label(since: start, now: start.addingTimeInterval(3_600)) == "60:00")
    }

    @Test func aBackwardsClockRendersZeroRatherThanANegativeTime() {
        #expect(RecordingElapsed.label(since: start, now: start.addingTimeInterval(-5)) == "0:00")
    }

    /// The P1 regression: the menu is rebuilt whenever an item in it changes,
    /// and a rebuild mid-recording must re-render the elapsed time from the
    /// start date — not restart the display at 0:00.
    @Test func rebuildingTheMenuMidRecordingKeepsTheElapsedTime() {
        let rebuiltAt = start.addingTimeInterval(65)
        #expect(RecordingElapsed.menuTitle(start: start, now: rebuiltAt) == "● 1:05")
    }

    @Test func withNoRecordingInProgressTheItemReadsZero() {
        #expect(RecordingElapsed.menuTitle(start: nil, now: start.addingTimeInterval(65)) == "● 0:00")
    }
}
