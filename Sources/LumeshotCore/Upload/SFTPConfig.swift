import Foundation

/// Non-secret SFTP destination config. Credentials live in the Keychain
/// (see `SFTPCredentials`), keyed by the owning destination's id — never here.
public struct SFTPConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var remoteDirectory: String   // write dir, e.g. "/home/user/uploads"
    public var publicURLBase: String     // REQUIRED (no derivable default), e.g. "https://cdn.example.com/uploads"

    public init(host: String, port: Int = 22, username: String, remoteDirectory: String,
               publicURLBase: String) {
        self.host = host
        self.port = port
        self.username = username
        self.remoteDirectory = remoteDirectory
        self.publicURLBase = publicURLBase
    }
}
