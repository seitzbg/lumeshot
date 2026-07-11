import Foundation
import Testing
@testable import SXCore

@Suite struct UploadSettingsManagementTests {
    private func dest(_ id: String, _ name: String) -> UploadDestination {
        UploadDestination(id: id, name: name, kind: .imgur, imgurClientID: "cid")
    }

    @Test func addingAppendsNewAndReplacesExisting() {
        var s = UploadSettings.disabled
        s = s.addingOrUpdating(dest("a", "A"))
        s = s.addingOrUpdating(dest("b", "B"))
        #expect(s.destinations.map(\.id) == ["a", "b"])
        s = s.addingOrUpdating(dest("a", "A2"))            // replace, not append
        #expect(s.destinations.count == 2)
        #expect(s.destinations.first { $0.id == "a" }?.name == "A2")
    }

    @Test func removingDropsAndClearsActiveWhenItMatches() {
        var s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "A"), dest("b", "B")])
        s = s.removing(id: "a")
        #expect(s.destinations.map(\.id) == ["b"])
        #expect(s.activeDestinationID == nil)              // active pointed at the removed one
    }

    @Test func removingKeepsActiveWhenDifferent() {
        var s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "b",
                               destinations: [dest("a", "A"), dest("b", "B")])
        s = s.removing(id: "a")
        #expect(s.activeDestinationID == "b")
    }

    @Test func settingActiveUpdatesThePointer() {
        let s = UploadSettings.disabled.settingActive(id: "x")
        #expect(s.activeDestinationID == "x")
        #expect(s.settingActive(id: nil).activeDestinationID == nil)
    }
}
