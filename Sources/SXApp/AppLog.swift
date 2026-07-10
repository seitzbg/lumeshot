import Foundation

/// Tees diagnostics to both the unified log (NSLog) and a file, because a
/// menu-bar app launched from Finder has no visible stderr. The file is the
/// only place capture failures are observable post-hoc.
enum AppLog {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ShareX-Mac.log")
    }()

    static func log(_ message: String) {
        NSLog("%@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
