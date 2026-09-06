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

    /// Rotate at 2 MB, keeping one previous file. A menu-bar app runs for
    /// weeks, and an unbounded append-only log eventually becomes both a disk
    /// problem and useless to read.
    private static let maxBytes = 2 * 1024 * 1024

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes else { return }
        let previous = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: fileURL, to: previous)
    }

    static func log(_ message: String) {
        NSLog("%@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
