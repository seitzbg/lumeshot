import Foundation

/// Which URL a Picsur upload copies to the clipboard.
public enum PicsurLinkStyle: String, Codable, Sendable, CaseIterable {
    /// `<host>/i/<id>.<format>` — a direct image URL that embeds inline in
    /// Slack/Discord/GitHub. This is what Picsur's own ShareX generator emits.
    case directImage
    /// `<host>/view/<id>` — the Picsur web viewer page.
    case viewerPage
}

/// Non-secret Picsur destination config. The API key lives in the Keychain
/// (see `PicsurCredentials`), keyed by the owning destination's id — never here.
public struct PicsurConfig: Codable, Equatable, Sendable {
    /// Instance base URL, normalized to scheme + host with no trailing slash.
    public var host: String
    /// Extension Picsur converts to when serving `/i/<id>.<ext>` (no leading dot).
    public var imageFormat: String
    public var linkStyle: PicsurLinkStyle

    public init(host: String, imageFormat: String = "png",
                linkStyle: PicsurLinkStyle = .directImage) {
        self.host = Self.normalizeHost(host)
        self.imageFormat = Self.normalizeFormat(imageFormat)
        self.linkStyle = linkStyle
    }

    /// Accepts what a human types — `pic.example.net`, a trailing slash, stray
    /// whitespace — and yields a base URL safe to concatenate paths onto.
    /// A bare host is assumed https (Picsur ships behind TLS by default).
    public static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty else { return "" }
        if !host.lowercased().hasPrefix("http://"), !host.lowercased().hasPrefix("https://") {
            host = "https://" + host
        }
        return host
    }

    /// Strips a leading dot and lowercases, so ".PNG" and "png" agree.
    public static func normalizeFormat(_ raw: String) -> String {
        var ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        return ext.isEmpty ? "png" : ext
    }

    // MARK: - URL construction
    //
    // These mirror Picsur's own ShareX generator (frontend/.../sharex-builder.ts),
    // so a native Picsur destination and an imported Picsur .sxcu agree.

    public var uploadURL: String { "\(host)/api/image/upload" }

    public func url(id: String) -> String {
        switch linkStyle {
        case .directImage: return "\(host)/i/\(id).\(imageFormat)"
        case .viewerPage:  return "\(host)/view/\(id)"
        }
    }

    public func thumbnailURL(id: String) -> String {
        "\(host)/i/\(id).jpg?width=128&shrinkonly=yes"
    }

    public func deletionURL(id: String, deleteKey: String) -> String {
        "\(host)/api/image/delete/\(id)/\(deleteKey)"
    }
}
