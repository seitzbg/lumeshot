import Foundation

public enum UploadDestinationKind: String, Codable, Sendable {
    case customUploader
    case imgur
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
    public var s3Config: S3Config?                     // non-secret S3 config; secrets → Keychain
    public var sftpConfig: SFTPConfig?                 // non-secret SFTP config; secrets → Keychain
    public var ftpConfig: FTPConfig?                   // non-secret FTP config; secrets → Keychain

    public init(id: String, name: String, kind: UploadDestinationKind,
                customUploader: CustomUploaderConfig? = nil,
                imgurClientID: String? = nil,
                s3Config: S3Config? = nil,
                sftpConfig: SFTPConfig? = nil,
                ftpConfig: FTPConfig? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.customUploader = customUploader
        self.imgurClientID = imgurClientID
        self.s3Config = s3Config
        self.sftpConfig = sftpConfig
        self.ftpConfig = ftpConfig
    }
}

public struct UploadSettings: Codable, Equatable, Sendable {
    public var uploadAfterCapture: Bool
    public var activeDestinationID: String?
    public var destinations: [UploadDestination]

    public init(uploadAfterCapture: Bool, activeDestinationID: String?,
                destinations: [UploadDestination]) {
        self.uploadAfterCapture = uploadAfterCapture
        self.activeDestinationID = activeDestinationID
        self.destinations = destinations
    }

    public static let disabled = UploadSettings(uploadAfterCapture: false,
                                                activeDestinationID: nil, destinations: [])

    public var activeDestination: UploadDestination? {
        guard let id = activeDestinationID else { return nil }
        return destinations.first { $0.id == id }
    }
}
