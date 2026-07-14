import Foundation
import SQLite3

public enum HistoryStoreError: Error, Equatable {
    case open(String)
    case exec(String)
}

/// Thin SQLite wrapper for capture/upload history. Not Sendable — use on one actor.
public final class HistoryStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            throw HistoryStoreError.open(lastError)
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY,
                captured_at REAL NOT NULL,
                file_path TEXT,
                url TEXT,
                deletion_url TEXT,
                destination TEXT,
                upload_failed INTEGER NOT NULL DEFAULT 0
            );
            """)
    }

    deinit { sqlite3_close(db) }

    public func insert(_ entry: HistoryEntry) throws {
        let sql = """
            INSERT OR REPLACE INTO history
            (id, captured_at, file_path, url, deletion_url, destination, upload_failed)
            VALUES (?,?,?,?,?,?,?);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.id)
        sqlite3_bind_double(stmt, 2, entry.capturedAt.timeIntervalSince1970)
        bindText(stmt, 3, entry.filePath)
        bindText(stmt, 4, entry.url)
        bindText(stmt, 5, entry.deletionURL)
        bindText(stmt, 6, entry.destinationName)
        sqlite3_bind_int(stmt, 7, entry.uploadFailed ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    public func recent(limit: Int) throws -> [HistoryEntry] {
        let sql = """
            SELECT id, captured_at, file_path, url, deletion_url, destination, upload_failed
            FROM history ORDER BY captured_at DESC LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(min(max(limit, 0), Int(Int32.max))))  // clamp: never trap
        return try readRows(stmt)
    }

    /// Newest-first, capped at `limit`. Alias of `recent` for browser call sites.
    public func all(limit: Int) throws -> [HistoryEntry] {
        try recent(limit: limit)
    }

    /// Case-insensitive substring match across file path, URL, and destination.
    /// An empty/whitespace query returns `recent(limit:)`.
    public func search(matching query: String, limit: Int) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(limit: limit) }
        let sql = """
            SELECT id, captured_at, file_path, url, deletion_url, destination, upload_failed
            FROM history
            WHERE file_path LIKE ? OR url LIKE ? OR destination LIKE ?
            ORDER BY captured_at DESC LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(trimmed)%"
        bindText(stmt, 1, pattern)
        bindText(stmt, 2, pattern)
        bindText(stmt, 3, pattern)
        sqlite3_bind_int(stmt, 4, Int32(min(max(limit, 0), Int(Int32.max))))
        return try readRows(stmt)
    }

    public func delete(id: String) throws {
        let stmt = try prepare("DELETE FROM history WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    public func setURL(id: String, url: String?, deletionURL: String?, failed: Bool) throws {
        let stmt = try prepare(
            "UPDATE history SET url = ?, deletion_url = ?, upload_failed = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, url)
        bindText(stmt, 2, deletionURL)
        sqlite3_bind_int(stmt, 3, failed ? 1 : 0)
        bindText(stmt, 4, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    // MARK: - Helpers

    /// Read every row the prepared statement yields, distinguishing a clean end
    /// (SQLITE_DONE) from a genuine mid-scan read error (fail loud).
    private func readRows(_ stmt: OpaquePointer?) throws -> [HistoryEntry] {
        var rows: [HistoryEntry] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: text(stmt, 0) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                filePath: text(stmt, 2),
                url: text(stmt, 3),
                deletionURL: text(stmt, 4),
                destinationName: text(stmt, 5),
                uploadFailed: sqlite3_column_int(stmt, 6) != 0))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
        return rows
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw HistoryStoreError.exec(lastError) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.exec(lastError)
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
