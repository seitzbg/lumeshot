import Testing
import Foundation
@testable import LumeshotCore

@Suite struct DestinationTestStateTests {
    private func dest(_ id: String, _ name: String, _ kind: UploadDestinationKind = .sftp,
                      tested: Date? = nil) -> UploadDestination {
        UploadDestination(id: id, name: name, kind: kind, lastTestedAt: tested)
    }

    @Test func aNewDestinationHasNotBeenTested() {
        #expect(!dest("a", "A").hasPassedATest)
    }

    @Test func markingTestedRecordsThePass() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "A")])
            .markingTested(id: "a", at: Date(timeIntervalSince1970: 1_000))
        #expect(s.destinations[0].hasPassedATest)
        #expect(s.destinations[0].lastTestedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func markingAnUnknownIDChangesNothing() {
        let original = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                                      destinations: [dest("a", "A")])
        #expect(original.markingTested(id: "nope") == original)
    }

    /// An edit must drop the pass: the caller rebuilds the destination with
    /// `lastTestedAt` nil, so a changed host cannot inherit the old one's clean bill.
    @Test func editingADestinationClearsItsTestedState() {
        let tested = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                                    destinations: [dest("a", "A", tested: Date())])
        #expect(tested.destinations[0].hasPassedATest)
        let edited = tested.addingOrUpdating(dest("a", "A renamed"))
        #expect(!edited.destinations[0].hasPassedATest)
    }

    @Test func onlyActiveDestinationsAreFlagged() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "Active"), dest("b", "Unused")])
        #expect(s.untestedActiveDestinations.map(\.name) == ["Active"])
    }

    @Test func aTestedActiveDestinationIsNotFlagged() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "Active", tested: Date())])
        #expect(s.untestedActiveDestinations.isEmpty)
    }

    /// Both roles are checked, and a destination serving both is named once.
    @Test func bothActiveRolesAreCheckedWithoutDuplication() {
        let separate = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                                      activeRecordingDestinationID: "b",
                                      destinations: [dest("a", "Images"), dest("b", "Video")])
        #expect(separate.untestedActiveDestinations.map(\.name) == ["Images", "Video"])

        let shared = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                                    destinations: [dest("a", "Both")])
        #expect(shared.untestedActiveDestinations.map(\.name) == ["Both"])
    }

    /// Existing settings files predate the field and must decode as "never tested"
    /// rather than failing to load.
    @Test func settingsWrittenBeforeThisFieldDecodeAsUntested() throws {
        let legacy = Data("""
        {"uploadAfterCapture":true,"activeDestinationID":"a",
         "destinations":[{"id":"a","name":"A","kind":"sftp"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: legacy)
        #expect(!decoded.destinations[0].hasPassedATest)
        #expect(decoded.untestedActiveDestinations.map(\.name) == ["A"])
    }

    @Test func theTestedDateSurvivesAJSONRoundTrip() throws {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "A")])
            .markingTested(id: "a", at: Date(timeIntervalSince1970: 5_000))
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.destinations[0].lastTestedAt == Date(timeIntervalSince1970: 5_000))
    }
}
