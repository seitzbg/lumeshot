import Foundation

public enum SettingsLoadIssue: Equatable, Sendable {
    case corruptBackedUp(URL)
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
        guard let data = try? Data(contentsOf: fileURL) else {
            return (.default, nil)
        }
        do {
            return (try JSONDecoder().decode(AppSettings.self, from: data), nil)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return (.default, .corruptBackedUp(backup))
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
