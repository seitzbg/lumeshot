import Foundation
import Testing
@testable import SXCore

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
}

private func entry(id: String, at seconds: TimeInterval, url: String? = nil) -> HistoryEntry {
    HistoryEntry(id: id, capturedAt: Date(timeIntervalSince1970: seconds),
                 filePath: "/tmp/\(id).png", url: url, deletionURL: nil,
                 destinationName: "Test", uploadFailed: false)
}

@Suite struct HistoryStoreTests {
    @Test func insertAndReadBackNewestFirst() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 100))
        try store.insert(entry(id: "b", at: 200, url: "https://x/b"))
        let rows = try store.recent(limit: 10)
        #expect(rows.map(\.id) == ["b", "a"])          // newest first
        #expect(rows.first?.url == "https://x/b")
    }

    @Test func limitCapsResults() throws {
        let store = try HistoryStore(fileURL: tempDB())
        for i in 0..<5 { try store.insert(entry(id: "e\(i)", at: TimeInterval(i))) }
        #expect(try store.recent(limit: 2).count == 2)
    }

    @Test func deleteRemovesRow() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 1))
        try store.delete(id: "a")
        #expect(try store.recent(limit: 10).isEmpty)
    }

    @Test func setURLUpdatesUploadFields() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 1))
        try store.setURL(id: "a", url: "https://x/a", deletionURL: "https://d/a", failed: false)
        let row = try store.recent(limit: 1).first
        #expect(row?.url == "https://x/a")
        #expect(row?.deletionURL == "https://d/a")
        #expect(row?.uploadFailed == false)
    }

    @Test func persistsAcrossReopen() throws {
        let url = tempDB()
        do { try HistoryStore(fileURL: url).insert(entry(id: "a", at: 1)) }
        let reopened = try HistoryStore(fileURL: url)
        #expect(try reopened.recent(limit: 10).map(\.id) == ["a"])
    }
}
