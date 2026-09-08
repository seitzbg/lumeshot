import Foundation

public enum SettingsLoadIssue: Equatable, Sendable {
    case corruptBackedUp(URL)
    case corruptBackupFailed(String)   // corrupt file left in place
    case readFailed(String)            // file exists but could not be read
}

public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumeshot/settings.json")
    }

    public func loadOrDefault() -> (AppSettings, SettingsLoadIssue?) {
        Self.transaction.lock()
        defer { Self.transaction.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (.default, nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return (.default, .readFailed(error.localizedDescription))
        }
        do {
            var loaded = try JSONDecoder().decode(AppSettings.self, from: data)
            if loaded.schemaVersion < 2 {
                loaded.schemaVersion = 2   // `upload` already defaulted by the decoder
            }
            return (loaded, nil)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            do {
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: fileURL, to: backup)
                return (.default, .corruptBackedUp(backup))
            } catch {
                return (.default, .corruptBackupFailed(error.localizedDescription))
            }
        }
    }

    /// Serializes complete load/modify/save transactions across the process.
    ///
    /// Writing the file atomically stops a reader ever seeing half a document; it
    /// does nothing for two writers. The SSH host-key callback persists a new pin
    /// from a NIO event-loop thread while Preferences and the menu save on the
    /// main actor, so the sequences interleave: the callback loads A, the user
    /// saves B, the callback writes A plus the fingerprint, and B is gone. The
    /// reverse order loses the pin, and two first connections lose each other's.
    ///
    /// Recursive because a body that reaches back into settings is a mistake but
    /// should not be a deadlock. It is a process-wide lock rather than a per-file
    /// one: `SettingsStore` is a value type created wherever it is needed, so
    /// there is no per-file owner to hang a lock on, and settings writes are far
    /// too rare for the contention to matter.
    private static let transaction = NSRecursiveLock()

    /// A body that changes nothing writes nothing, so an action that inspects
    /// the current settings and then declines to proceed can do both inside the
    /// transaction without rewriting the file to bail out.
    @discardableResult
    public func mutate(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings {
        Self.transaction.lock()
        defer { Self.transaction.unlock() }
        let original = loadOrDefault().0
        var settings = original
        try body(&settings)
        if settings != original { try save(settings) }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        Self.transaction.lock()
        defer { Self.transaction.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
