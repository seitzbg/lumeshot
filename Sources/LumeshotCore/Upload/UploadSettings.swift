import Foundation

public enum UploadDestinationKind: String, Codable, Sendable {
    case customUploader
    case imgur
    case picsur
    case s3
    case sftp
    case ftp
}

public struct UploadDestination: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: UploadDestinationKind
    public var customUploader: CustomUploaderConfig?   // non-secret config; secrets → Keychain
    public var imgurClientID: String?                  // non-secret; anonymous client id
    public var picsurConfig: PicsurConfig?             // non-secret Picsur config; API key → Keychain
    public var s3Config: S3Config?                     // non-secret S3 config; secrets → Keychain
    public var sftpConfig: SFTPConfig?                 // non-secret SFTP config; secrets → Keychain
    public var ftpConfig: FTPConfig?                   // non-secret FTP config; secrets → Keychain

    public init(id: String, name: String, kind: UploadDestinationKind,
                customUploader: CustomUploaderConfig? = nil,
                imgurClientID: String? = nil,
                picsurConfig: PicsurConfig? = nil,
                s3Config: S3Config? = nil,
                sftpConfig: SFTPConfig? = nil,
                ftpConfig: FTPConfig? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.customUploader = customUploader
        self.imgurClientID = imgurClientID
        self.picsurConfig = picsurConfig
        self.s3Config = s3Config
        self.sftpConfig = sftpConfig
        self.ftpConfig = ftpConfig
    }
}

/// What the clipboard holds once an upload succeeds.
///
/// The image is copied at capture time (when that preference is on); the URL
/// used to overwrite it unconditionally on upload, so "copy to clipboard" and
/// "upload after capture" together always left you with the link and never the
/// picture. This makes that a choice.
public enum AfterUploadClipboard: String, Codable, Sendable, CaseIterable {
    /// Replace the clipboard with the upload URL (the previous behavior).
    case url
    /// Keep the image on the clipboard; the URL still goes to history and the
    /// notification. For recordings there is no image, so the clipboard is
    /// simply left alone.
    case image
}

public struct UploadSettings: Codable, Equatable, Sendable {
    public var uploadAfterCapture: Bool
    public var activeDestinationID: String?
    public var destinations: [UploadDestination]
    public var afterUploadClipboard: AfterUploadClipboard

    public init(uploadAfterCapture: Bool, activeDestinationID: String?,
                destinations: [UploadDestination],
                afterUploadClipboard: AfterUploadClipboard = .url) {
        self.uploadAfterCapture = uploadAfterCapture
        self.activeDestinationID = activeDestinationID
        self.destinations = destinations
        self.afterUploadClipboard = afterUploadClipboard
    }

    // Hand-written so a settings.json written before this key existed still
    // decodes. Synthesized Codable would throw on the missing key, and the
    // store answers a decode failure by backing the file up and resetting to
    // defaults -- which would silently drop every configured destination.
    private enum CodingKeys: String, CodingKey {
        case uploadAfterCapture, activeDestinationID, destinations, afterUploadClipboard
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploadAfterCapture = try c.decode(Bool.self, forKey: .uploadAfterCapture)
        activeDestinationID = try c.decodeIfPresent(String.self, forKey: .activeDestinationID)
        destinations = try c.decode([UploadDestination].self, forKey: .destinations)
        afterUploadClipboard = try c.decodeIfPresent(AfterUploadClipboard.self,
                                                     forKey: .afterUploadClipboard) ?? .url
    }

    public static let disabled = UploadSettings(uploadAfterCapture: false,
                                                activeDestinationID: nil, destinations: [])

    public var activeDestination: UploadDestination? {
        guard let id = activeDestinationID else { return nil }
        return destinations.first { $0.id == id }
    }
}
