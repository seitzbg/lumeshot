@preconcurrency import Citadel
import NIOCore
import NIOSSH
import Crypto
import Foundation
import LumeshotCore

/// Trust-on-first-use host-key validator.
///
/// Citadel only ships `.acceptAnything()` and `.trustedKeys(Set<NIOSSHPublicKey>)`;
/// neither can express "pin whatever we saw the first time". `.custom` can, and
/// fingerprints (rather than key objects) are what we can persist and show the
/// user. Verification runs on a NIO event loop thread, so the outcome is handed
/// back through a lock-guarded box rather than shared mutable state.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let knownHostKey: String?
    private let remember: @Sendable (String) -> Void
    private let lock = NSLock()
    private var _mismatch: (saved: String, presented: String)?

    /// Set when the connection was refused because the key changed, so the
    /// caller can report which fingerprints were involved instead of a generic
    /// handshake failure.
    var mismatch: (saved: String, presented: String)? {
        lock.lock(); defer { lock.unlock() }
        return _mismatch
    }

    init(knownHostKey: String?, remember: @escaping @Sendable (String) -> Void) {
        self.knownHostKey = knownHostKey
        self.remember = remember
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let blob = Array(buffer.readableBytesView)
        let presented = HostKeyTrust.fingerprint(sha256Digest: Array(SHA256.hash(data: blob)))

        switch HostKeyTrust.decide(saved: knownHostKey, presented: presented) {
        case .match:
            validationCompletePromise.succeed(())
        case .trustOnFirstUse(let fingerprint):
            remember(fingerprint)
            validationCompletePromise.succeed(())
        case .mismatch(let saved, let presented):
            lock.lock(); _mismatch = (saved, presented); lock.unlock()
            validationCompletePromise.fail(UploadError.hostKeyMismatch(presented))
        }
    }
}

/// Real SFTP transport over Citadel (SwiftNIO-SSH). `SSHClient` is NOT
/// Sendable, so it is created, used, and closed entirely within this one
/// `upload(_:)` call — never stored, never escapes.
public struct CitadelSFTPTransport: SFTPTransport {
    public init() {}

    /// Citadel 0.12.1 — and the swift-nio-ssh it builds on — can only sign with
    /// the legacy "ssh-rsa" algorithm, which is SHA-1 based. OpenSSH has
    /// excluded it from `PubkeyAcceptedAlgorithms` by default since 8.8 (2021),
    /// so an RSA key that authenticates fine with the `ssh` command fails here,
    /// and the handshake reports only "allAuthenticationOptionsFailed". Naming
    /// the real cause is the difference between a user switching key type and a
    /// user re-checking a key that was never the problem.
    static let rsaSHA1Note = " \u{2014} the key is RSA, and this build can only offer the legacy "
        + "ssh-rsa (SHA-1) signature, which OpenSSH 8.8 and newer reject by default. "
        + "Use an Ed25519 key for this destination."

    public func upload(_ data: Data, to remotePath: String, host: String, port: Int,
                       username: String, secret: SFTPSecret,
                       knownHostKey: String?,
                       rememberHostKey: @escaping @Sendable (String) -> Void) async throws {
        let auth: SSHAuthenticationMethod
        var usingRSAKey = false
        if let pem = secret.privateKeyPEM {
            let dk = secret.passphrase.map { Data($0.utf8) }
            do {
                if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: dk) {
                    auth = .ed25519(username: username, privateKey: ed)
                } else {
                    // The `try?` above only means "not ed25519" (or an ed25519 key
                    // with the wrong passphrase) — it does not mean the key is
                    // valid RSA. Fall through to RSA and let ITS failure (or
                    // success) decide; either way the outer `catch` below turns
                    // any real parse failure into a typed UploadError instead of
                    // leaking the raw Citadel/Crypto error.
                    let rsa = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: dk)   // throws if neither parses
                    auth = .rsa(username: username, privateKey: rsa)
                    usingRSAKey = true
                }
            } catch {
                throw UploadError.missingCredential(
                    "SFTP private key could not be parsed (bad key or wrong passphrase): \(error)")
            }
        } else if let pw = secret.password {
            auth = .passwordBased(username: username, password: pw)
        } else {
            throw UploadError.missingCredential("SFTP destination has neither password nor private key")
        }

        let validator = TOFUHostKeyValidator(knownHostKey: knownHostKey,
                                             remember: rememberHostKey)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(host: host, port: port,
                authenticationMethod: auth, hostKeyValidator: .custom(validator),
                reconnect: .never)
        } catch {
            // A refused key surfaces here as an opaque handshake failure, so
            // recover the specific reason from the validator and fail closed
            // with both fingerprints.
            if let (saved, presented) = validator.mismatch {
                throw UploadError.hostKeyMismatch(
                    HostKeyTrust.mismatchMessage(host: host, saved: saved, presented: presented))
            }
            // The RSA note explains a *rejected key*. This catch also covers DNS
            // failures, refused ports and timeouts, where no key was ever
            // offered — appending it there would send the user after the wrong
            // thing. Gate it on the error that means "the server turned down
            // everything we offered".
            var everyCredentialRejected = false
            if case .allAuthenticationOptionsFailed? = error as? SSHClientError {
                everyCredentialRejected = true
            }
            throw UploadError.transport(
                "SFTP connect failed: \(error)"
                + (usingRSAKey && everyCredentialRejected ? Self.rsaSHA1Note : ""))
        }
        do {
            try await client.withSFTP { sftp in
                try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { handle in
                    try await handle.write(ByteBuffer(data: data))
                }
            }
            try await client.close()
        } catch {
            try? await client.close()   // explicit close on the error path (no fire-and-forget Task)
            throw UploadError.transport("SFTP write failed: \(error)")
        }
    }
}
