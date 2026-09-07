import Foundation
import Testing
import SQLite3
@testable import LumeshotCore

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
    @Test func legacyDatabaseMigratesWithoutLosingHistory() throws {
        let url = tempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE history (id TEXT PRIMARY KEY, captured_at REAL NOT NULL,
                file_path TEXT, url TEXT, deletion_url TEXT, destination TEXT,
                upload_failed INTEGER NOT NULL DEFAULT 0);
            INSERT INTO history VALUES ('old', 100, '/tmp/old.png', 'https://example.com/old',
                'https://example.com/delete', 'Original', 0);
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = try HistoryStore(fileURL: url)
            let original = try #require(store.all(limit: 10).first)
            #expect(original.id == "old")
            #expect(original.deletionURL == "https://example.com/delete")
            #expect(original.destinationID == nil)
            var updated = original
            updated.destinationID = "stable-destination-id"
            try store.insert(updated)
        }
        let reopened = try HistoryStore(fileURL: url)
        #expect(try reopened.all(limit: 10).first?.destinationID == "stable-destination-id")
    }

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

    @Test func searchMatchesUrlAndDestinationAndEmptyReturnsAll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sx-history-\(UUID().uuidString).sqlite")
        let store = try HistoryStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try store.insert(HistoryEntry(id: "1", capturedAt: Date(timeIntervalSince1970: 100),
                                      filePath: "/tmp/alpha.png", url: "https://cdn/alpha.png",
                                      deletionURL: nil, destinationName: "S3", uploadFailed: false))
        try store.insert(HistoryEntry(id: "2", capturedAt: Date(timeIntervalSince1970: 200),
                                      filePath: "/tmp/beta.png", url: "https://i.imgur.com/beta",
                                      deletionURL: nil, destinationName: "Imgur", uploadFailed: false))

        #expect(try store.search(matching: "imgur", limit: 50).map(\.id) == ["2"])
        #expect(try store.search(matching: "S3", limit: 50).map(\.id) == ["1"])
        #expect(try store.search(matching: "alpha", limit: 50).map(\.id) == ["1"])
        // Empty query falls back to recent() (newest first).
        #expect(try store.search(matching: "   ", limit: 50).map(\.id) == ["2", "1"])
        #expect(try store.all(limit: 50).map(\.id) == ["2", "1"])
    }
}
