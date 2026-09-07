import Foundation

public enum UploadDestinationKind: String, Codable, Sendable {
    case customUploader
    case imgur
    case picsur
    case s3
    case sftp
    case ftp
}

public extension UploadDestinationKind {
    /// Whether this kind of host accepts video.
    ///
    /// Picsur and Imgur are image hosts and reject an `.mp4` outright — sending one
    /// produces a server error that reads like a broken uploader rather than a
    /// mismatched destination. The rest are general-purpose file transports.
    ///
    /// A custom `.sxcu` uploader is treated as capable: it could be either, and
    /// guessing "no" would block a working configuration. Being wrong in that
    /// direction only costs the failure the user would have had anyway.
    var acceptsRecordings: Bool {
        switch self {
        case .picsur, .imgur:                       false
        case .customUploader, .s3, .sftp, .ftp:     true
        }
    }
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

/// What is being uploaded, as opposed to `UploadDestinationKind`, which is where it
/// goes. Screenshots and recordings can target different destinations because plenty
/// of image hosts — Picsur among them — accept no video at all.
public enum UploadArtifactKind: String, Codable, Sendable, CaseIterable {
    case image
    case recording
}

public struct UploadSettings: Codable, Equatable, Sendable {
    public var uploadAfterCapture: Bool
    /// Where screenshots go.
    public var activeDestinationID: String?
    /// Where recordings go. `nil` means "wherever screenshots go", which is both the
    /// behaviour before this field existed and what every settings file written before
    /// it decodes to — so no migration, and no change for anyone who does not set it.
    public var activeRecordingDestinationID: String?
    public var destinations: [UploadDestination]

    public init(uploadAfterCapture: Bool, activeDestinationID: String?,
                activeRecordingDestinationID: String? = nil,
                destinations: [UploadDestination]) {
        self.uploadAfterCapture = uploadAfterCapture
        self.activeDestinationID = activeDestinationID
        self.activeRecordingDestinationID = activeRecordingDestinationID
        self.destinations = destinations
    }

    public static let disabled = UploadSettings(uploadAfterCapture: false,
                                                activeDestinationID: nil, destinations: [])

    public var activeDestination: UploadDestination? { destination(id: activeDestinationID) }

    /// The destination an artifact of `kind` uploads to.
    public func activeDestination(for kind: UploadArtifactKind) -> UploadDestination? {
        switch kind {
        case .image:
            return activeDestination
        case .recording:
            // nil means "follow images". An id that no longer resolves means the chosen
            // destination was deleted — which is not the same thing, and must not
            // silently redirect recordings to the image host.
            guard let id = activeRecordingDestinationID else { return activeDestination }
            return destination(id: id)
        }
    }

    /// True when recordings are pointed somewhere other than the image destination.
    public var usesSeparateRecordingDestination: Bool { activeRecordingDestinationID != nil }

    /// The destination recordings would use, when it cannot accept video.
    ///
    /// Non-nil is the state that produced a confusing bug report: recordings following
    /// an image-only screenshot destination, failing with a generic upload error that
    /// looked like the *other* uploader was broken.
    public var recordingDestinationRejectingVideo: UploadDestination? {
        guard let destination = activeDestination(for: .recording),
              !destination.kind.acceptsRecordings else { return nil }
        return destination
    }

    private func destination(id: String?) -> UploadDestination? {
        guard let id else { return nil }
        return destinations.first { $0.id == id }
    }
}
