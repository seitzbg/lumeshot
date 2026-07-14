import Foundation

/// Non-secret FTP destination config. Credentials live in the Keychain
/// (see `FTPCredentials`), keyed by the owning destination's id — never here.
public struct FTPConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var remoteDirectory: String
    public var publicURLBase: String     // REQUIRED (no derivable default)
    public var useTLS: Bool              // FTPS via CURLOPT_USE_SSL

    public init(host: String, port: Int = 21, username: String, remoteDirectory: String,
               publicURLBase: String, useTLS: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.remoteDirectory = remoteDirectory
        self.publicURLBase = publicURLBase
        self.useTLS = useTLS
    }
}
