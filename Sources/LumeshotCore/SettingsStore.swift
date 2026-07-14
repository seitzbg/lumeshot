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
            .appendingPathComponent("ShareX-Mac/settings.json")
    }

    public func loadOrDefault() -> (AppSettings, SettingsLoadIssue?) {
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

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
