import Foundation
import Testing
@testable import LumeshotUpload
import LumeshotCore

/// Coordinates for the throwaway SFTP/FTP/HTTP servers that
/// `scripts/test-servers/up.sh` starts. When they are not configured every test
/// below skips itself, so CI and a plain `swift test` behave exactly as before.
enum LiveUploadServers {
    static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    static var host: String? { env("LUMESHOT_LIVE_UPLOAD_HOST") }
    static var configured: Bool { host != nil }

    static var sftpPort: Int { Int(env("LUMESHOT_LIVE_SFTP_PORT") ?? "") ?? 2222 }
    static var ftpPort: Int { Int(env("LUMESHOT_LIVE_FTP_PORT") ?? "") ?? 2121 }
    static var user: String { env("LUMESHOT_LIVE_USER") ?? "lume" }
    static var password: String { env("LUMESHOT_LIVE_PASSWORD") ?? "lumepass" }
    static var httpBase: String { env("LUMESHOT_LIVE_HTTP_BASE") ?? "http://\(host ?? ""):8080" }
    static var keyDir: URL { URL(fileURLWithPath: env("LUMESHOT_LIVE_KEY_DIR") ?? ".") }

    static func privateKey(_ name: String) throws -> String {
        try String(contentsOf: keyDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// A distinct filename per upload, so a failure is never a leftover from an
    /// earlier run and the tests can run in any order.
    static func filename(_ label: String) -> String {
        "\(label)-\(UUID().uuidString.lowercased()).png"
    }

    static func part(_ filename: String, bytes: Data) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: "image/png", data: bytes)
    }

    /// Fetch a URL the uploader handed back and return its bytes. This is the
    /// part `docs/smoke-m5a.md` did by pasting the link into a browser.
    static func fetch(_ url: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw UploadError.http(status: status, body: "GET \(url)")
        }
        return data
    }
}

/// `CitadelSFTPTransport` against a real SSH server. Everything here used to be
/// reachable only through the manual `docs/smoke-m5a.md` run — including the
/// three key-init calls that carried "VERIFY on Mac" comments because no
/// automated test had ever executed them.
@Suite(.enabled(if: LiveUploadServers.configured), .serialized)
struct LiveSFTPTransportTests {
    private func config(directory: String = "/upload",
                        knownHostKey: String? = nil,
                        port: Int? = nil) -> SFTPConfig {
        SFTPConfig(host: LiveUploadServers.host!,
                   port: port ?? LiveUploadServers.sftpPort,
                   username: LiveUploadServers.user,
                   remoteDirectory: directory,
                   publicURLBase: "\(LiveUploadServers.httpBase)/sftp",
                   knownHostKey: knownHostKey)
    }

    private func uploadAndReadBack(secret: SFTPSecret, label: String) async throws {
        let name = LiveUploadServers.filename(label)
        let bytes = Data("lumeshot-\(label)-\(name)".utf8)
        let uploader = SFTPUploader(config: config(), secret: secret)

        let result = try await uploader.upload(LiveUploadServers.part(name, bytes: bytes))

        #expect(result.url == "\(LiveUploadServers.httpBase)/sftp/\(name)")
        let served = try await LiveUploadServers.fetch(result.url)
        #expect(served == bytes)
    }

    @Test func passwordAuthUploadsAndThePublicURLServesTheBytes() async throws {
        try await uploadAndReadBack(secret: SFTPSecret(password: LiveUploadServers.password),
                                    label: "sftp-password")
    }

    @Test func ed25519KeyAuthUploads() async throws {
        try await uploadAndReadBack(
            secret: SFTPSecret(privateKeyPEM: try LiveUploadServers.privateKey("ed25519")),
            label: "sftp-ed25519")
    }

    @Test func ed25519KeyWithPassphraseUploads() async throws {
        try await uploadAndReadBack(
            secret: SFTPSecret(privateKeyPEM: try LiveUploadServers.privateKey("ed25519-pass"),
                               passphrase: "lumepassphrase"),
            label: "sftp-ed25519-passphrase")
    }

    /// The RSA branch — reached only after the ed25519 parse fails. The key
    /// parses and is offered, but Citadel can only sign with the SHA-1
    /// "ssh-rsa" algorithm that OpenSSH has excluded by default since 8.8, so a
    /// current server refuses it. That part is not ours to fix; the diagnosis
    /// is, so this pins the diagnosis: the failure must name the cause instead
    /// of surfacing a bare "allAuthenticationOptionsFailed".
    ///
    /// If this test ever fails because the upload SUCCEEDED, Citadel gained
    /// rsa-sha2-* support — delete `CitadelSFTPTransport.rsaSHA1Note`, this
    /// test, and the README note along with it.
    @Test func anRSAKeyFailsWithAnErrorThatNamesTheSHA1Cause() async throws {
        let uploader = SFTPUploader(config: config(),
                                    secret: SFTPSecret(privateKeyPEM: try LiveUploadServers.privateKey("rsa")))
        do {
            _ = try await uploader.upload(
                LiveUploadServers.part(LiveUploadServers.filename("sftp-rsa"), bytes: Data("x".utf8)))
            Issue.record("RSA authentication succeeded — see the note above, this is good news")
        } catch let error as UploadError {
            guard case .transport(let message) = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
            #expect(message.contains("ssh-rsa"))
            #expect(message.contains("Ed25519"))
        }
    }

    /// A key that will not decrypt is a credential problem, and has to be
    /// reported as one — `.transport` here would send the user looking at the
    /// network for a bad passphrase.
    @Test func aWrongPassphraseIsReportedAsABadCredentialNotAConnectionFailure() async throws {
        let secret = SFTPSecret(privateKeyPEM: try LiveUploadServers.privateKey("ed25519-pass"),
                                passphrase: "not-the-passphrase")
        let uploader = SFTPUploader(config: config(), secret: secret)
        do {
            _ = try await uploader.upload(
                LiveUploadServers.part(LiveUploadServers.filename("sftp-badpass"), bytes: Data("x".utf8)))
            Issue.record("expected the undecryptable key to be rejected")
        } catch let error as UploadError {
            guard case .missingCredential = error else {
                Issue.record("expected UploadError.missingCredential, got \(error)"); return
            }
        }
    }

    /// The note is about a key the server turned down. A refused port never got
    /// as far as offering one, so telling the user their key type is wrong would
    /// point them away from the actual problem.
    @Test func aConnectionFailureWithAnRSAKeyDoesNotBlameTheKeyType() async throws {
        let uploader = SFTPUploader(config: config(port: 1),
                                    secret: SFTPSecret(privateKeyPEM: try LiveUploadServers.privateKey("rsa")))
        do {
            _ = try await uploader.upload(
                LiveUploadServers.part(LiveUploadServers.filename("sftp-rsa-refused"), bytes: Data("x".utf8)))
            Issue.record("expected the connection to be refused")
        } catch let error as UploadError {
            guard case .transport(let message) = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
            #expect(!message.contains("Ed25519"))
        }
    }

    @Test func aWrongPasswordFailsAndWritesNothing() async throws {
        let name = LiveUploadServers.filename("sftp-wrongpw")
        let uploader = SFTPUploader(config: config(), secret: SFTPSecret(password: "wrong-password"))
        do {
            _ = try await uploader.upload(LiveUploadServers.part(name, bytes: Data("x".utf8)))
            Issue.record("expected authentication to fail")
        } catch let error as UploadError {
            guard case .transport = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LiveUploadServers.fetch("\(LiveUploadServers.httpBase)/sftp/\(name)")
        }
    }

    @Test func anUnreachablePortFailsAsATransportError() async throws {
        // Port 1 on the same host: refused immediately rather than waiting out
        // CURLOPT_CONNECTTIMEOUT-style dead-air.
        let uploader = SFTPUploader(config: config(port: 1), secret: SFTPSecret(password: LiveUploadServers.password))
        do {
            _ = try await uploader.upload(
                LiveUploadServers.part(LiveUploadServers.filename("sftp-refused"), bytes: Data("x".utf8)))
            Issue.record("expected the connection to be refused")
        } catch let error as UploadError {
            guard case .transport = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
        }
    }

    /// Trust on first use: an unpinned destination connects and reports the
    /// fingerprint it saw, which is what the app persists into `knownHostKey`.
    @Test func aFirstConnectionLearnsTheHostKeyFingerprint() async throws {
        let learned = LockedValueBox<String?>(nil)
        let uploader = SFTPUploader(config: config(), secret: SFTPSecret(password: LiveUploadServers.password),
                                    rememberHostKey: { learned.set($0); return .accepted })

        _ = try await uploader.upload(
            LiveUploadServers.part(LiveUploadServers.filename("sftp-tofu"), bytes: Data("x".utf8)))

        let fingerprint = learned.get()
        #expect(fingerprint?.hasPrefix("SHA256:") == true)
    }

    /// The other half of the pin: once a fingerprint is recorded, a server
    /// presenting a different key must be refused rather than silently trusted.
    @Test func aChangedHostKeyIsRefused() async throws {
        let name = LiveUploadServers.filename("sftp-mismatch")
        let pinned = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let uploader = SFTPUploader(config: config(knownHostKey: pinned),
                                    secret: SFTPSecret(password: LiveUploadServers.password))
        do {
            _ = try await uploader.upload(LiveUploadServers.part(name, bytes: Data("x".utf8)))
            Issue.record("expected the pinned host key mismatch to refuse the connection")
        } catch let error as UploadError {
            guard case .hostKeyMismatch(let message) = error else {
                Issue.record("expected UploadError.hostKeyMismatch, got \(error)"); return
            }
            #expect(message.contains(pinned))
        }
        await #expect(throws: (any Error).self) {
            _ = try await LiveUploadServers.fetch("\(LiveUploadServers.httpBase)/sftp/\(name)")
        }
    }
}

/// `CurlFTPTransport` against a real FTP server that accepts both plaintext and
/// TLS, so a silent plaintext fallback would show up here as a passing TLS test
/// rather than being invisible.
@Suite(.enabled(if: LiveUploadServers.configured), .serialized)
struct LiveFTPTransportTests {
    private func config(useTLS: Bool = false, port: Int? = nil) -> FTPConfig {
        FTPConfig(host: LiveUploadServers.host!,
                  port: port ?? LiveUploadServers.ftpPort,
                  username: LiveUploadServers.user,
                  remoteDirectory: "",
                  publicURLBase: "\(LiveUploadServers.httpBase)/ftp",
                  useTLS: useTLS)
    }

    @Test func plainUploadPutsTheBytesBehindThePublicURL() async throws {
        let name = LiveUploadServers.filename("ftp-plain")
        let bytes = Data("lumeshot-ftp-\(name)".utf8)
        let uploader = FTPUploader(config: config(), secret: FTPSecret(password: LiveUploadServers.password))

        let result = try await uploader.upload(LiveUploadServers.part(name, bytes: bytes))

        #expect(result.url == "\(LiveUploadServers.httpBase)/ftp/\(name)")
        let served = try await LiveUploadServers.fetch(result.url)
        #expect(served == bytes)
    }

    /// The FTPS half of `CURLOPT_USE_SSL`, and the only leverage available for
    /// it without a publicly trusted certificate: the throwaway server accepts
    /// *both* plaintext and TLS, and `plainUploadPutsTheBytesBehindThePublicURL`
    /// above shows a plaintext upload to the very same host and port succeeding.
    /// So if the TLS option were being dropped on the floor, this upload would
    /// succeed too. It must instead fail in TLS — which is what proves the flag
    /// reaches libcurl and that there is no quiet plaintext fallback.
    ///
    /// What this does NOT cover is a successful transfer over TLS; that needs a
    /// certificate the Mac's trust store accepts, which a throwaway container
    /// cannot have. `docs/smoke-m5a.md` keeps that one live check.
    @Test func requestingTLSNeverFallsBackToPlaintext() async throws {
        let name = LiveUploadServers.filename("ftp-tls")
        let uploader = FTPUploader(config: config(useTLS: true),
                                   secret: FTPSecret(password: LiveUploadServers.password))
        do {
            _ = try await uploader.upload(LiveUploadServers.part(name, bytes: Data("x".utf8)))
            Issue.record("a self-signed server should not have passed certificate verification")
        } catch let error as UploadError {
            guard case .transport(let message) = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
            #expect(message.contains("SSL"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await LiveUploadServers.fetch("\(LiveUploadServers.httpBase)/ftp/\(name)")
        }
    }

    @Test func aWrongPasswordFailsAndWritesNothing() async throws {
        let name = LiveUploadServers.filename("ftp-wrongpw")
        let uploader = FTPUploader(config: config(), secret: FTPSecret(password: "wrong-password"))
        do {
            _ = try await uploader.upload(LiveUploadServers.part(name, bytes: Data("x".utf8)))
            Issue.record("expected authentication to fail")
        } catch let error as UploadError {
            guard case .transport = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LiveUploadServers.fetch("\(LiveUploadServers.httpBase)/ftp/\(name)")
        }
    }

    @Test func anUnreachablePortFailsAsATransportError() async throws {
        let uploader = FTPUploader(config: config(port: 1), secret: FTPSecret(password: LiveUploadServers.password))
        do {
            _ = try await uploader.upload(
                LiveUploadServers.part(LiveUploadServers.filename("ftp-refused"), bytes: Data("x".utf8)))
            Issue.record("expected the connection to be refused")
        } catch let error as UploadError {
            guard case .transport = error else {
                Issue.record("expected UploadError.transport, got \(error)"); return
            }
        }
    }
}

/// Minimal lock-guarded box for the `@Sendable` host-key callback, which fires
/// on a NIO event-loop thread rather than the test's.
private final class LockedValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
