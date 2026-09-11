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
    private let remember: @Sendable (String) -> HostKeyPinResult
    private let lock = NSLock()
    private var _mismatch: (saved: String, presented: String)?

    /// Whether to accept the presented key, or refuse it (fail closed) with a
    /// typed reason. Pure and NIO-free so the trust-and-pin logic — the part the
    /// concurrent-first-use race lives in — is unit-testable without a live SSH
    /// server or a constructed public key.
    enum Outcome: Equatable {
        case accept
        case reject(UploadError)
    }

    /// Set when the connection was refused because the key changed, so the
    /// caller can report which fingerprints were involved instead of a generic
    /// handshake failure.
    var mismatch: (saved: String, presented: String)? {
        lock.lock(); defer { lock.unlock() }
        return _mismatch
    }

    init(knownHostKey: String?, remember: @escaping @Sendable (String) -> HostKeyPinResult) {
        self.knownHostKey = knownHostKey
        self.remember = remember
    }

    /// Decides the fate of a presented fingerprint. On first use, the persistence
    /// transaction (`remember`) has the last word: it, not this validator's stale
    /// `knownHostKey` snapshot, knows whether another connection has pinned a
    /// different key in the meantime.
    func outcome(forPresented presented: String) -> Outcome {
        switch HostKeyTrust.decide(saved: knownHostKey, presented: presented) {
        case .match:
            return .accept
        case .trustOnFirstUse(let fingerprint):
            switch remember(fingerprint) {
            case .accepted:
                return .accept
            case .conflict(let saved, let presented):
                recordMismatch(saved: saved, presented: presented)
                return .reject(.hostKeyMismatch(presented))
            case .persistenceFailed(let reason):
                return .reject(.transport("could not record the server's host key: \(reason)"))
            }
        case .mismatch(let saved, let presented):
            recordMismatch(saved: saved, presented: presented)
            return .reject(.hostKeyMismatch(presented))
        }
    }

    private func recordMismatch(saved: String, presented: String) {
        lock.lock(); _mismatch = (saved, presented); lock.unlock()
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let blob = Array(buffer.readableBytesView)
        let presented = HostKeyTrust.fingerprint(sha256Digest: Array(SHA256.hash(data: blob)))

        switch outcome(forPresented: presented) {
        case .accept:
            validationCompletePromise.succeed(())
        case .reject(let error):
            validationCompletePromise.fail(error)
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

    /// A transport-failure reason that carries no server-supplied text.
    ///
    /// `\(error)` on a Citadel error can quote the server verbatim: an
    /// SSH_FXP_STATUS surfaces as `SFTPMessage.Status` (directly, or wrapped in
    /// `SFTPError.errorStatus`), whose description embeds the server's `message`
    /// — which can echo a remote path, or an auth/error string that leaks a
    /// token — and that reason is written to `~/Library/Logs/Lumeshot.log`. Keep
    /// the typed SSH_FX_* status code and the error type/case (all fixed, app-
    /// or library-authored), and never interpolate the free-form description. An
    /// app-authored prefix like "SFTP write failed:" does not make it safe.
    static func redactedReason(_ error: Error) -> String {
        if let status = error as? SFTPMessage.Status {
            return "SFTP status \(status.errorCode)"
        }
        if let sftp = error as? SFTPError {
            if case .errorStatus(let status) = sftp { return "SFTP status \(status.errorCode)" }
            return "SFTPError.\(sftp)"                    // remaining cases carry no server text
        }
        if let ssh = error as? SSHClientError { return "SSHClientError.\(ssh)" }
        if let urlError = error as? URLError { return "URLError(\(urlError.code.rawValue))" }
        return String(describing: type(of: error))       // type only; no server-influenced text
    }

    public func upload(_ data: Data, to remotePath: String, host: String, port: Int,
                       username: String, secret: SFTPSecret,
                       knownHostKey: String?,
                       rememberHostKey: @escaping @Sendable (String) -> HostKeyPinResult) async throws {
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
                "SFTP connect failed: \(Self.redactedReason(error))"
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
            throw UploadError.transport("SFTP write failed: \(Self.redactedReason(error))")
        }
    }
}
