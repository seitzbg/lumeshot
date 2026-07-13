@preconcurrency import Citadel
import NIOCore
import Crypto
import Foundation
import SXCore

/// Real SFTP transport over Citadel (SwiftNIO-SSH). `SSHClient` is NOT
/// Sendable, so it is created, used, and closed entirely within this one
/// `upload(_:)` call — never stored, never escapes.
public struct CitadelSFTPTransport: SFTPTransport {
    public init() {}

    public func upload(_ data: Data, to remotePath: String, host: String, port: Int,
                       username: String, secret: SFTPSecret) async throws {
        let auth: SSHAuthenticationMethod
        if let pem = secret.privateKeyPEM {
            let dk = secret.passphrase.map { Data($0.utf8) }
            do {
                // VERIFY on Mac: exact Citadel 0.12.1 key-init signature —
                // Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:) — confirm it
                // exists with this name/label set on the resolved SDK before relying on it.
                if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: dk) {
                    auth = .ed25519(username: username, privateKey: ed)
                } else {
                    // The `try?` above only means "not ed25519" (or an ed25519 key
                    // with the wrong passphrase) — it does not mean the key is
                    // valid RSA. Fall through to RSA and let ITS failure (or
                    // success) decide; either way the outer `catch` below turns
                    // any real parse failure into a typed UploadError instead of
                    // leaking the raw Citadel/Crypto error.
                    // VERIFY on Mac: exact Citadel 0.12.1 RSA key-init signature —
                    // Insecure.RSA.PrivateKey(sshRsa:decryptionKey:) — confirm the type
                    // name and initializer on the resolved SDK; adjust if it differs.
                    // The key-then-password-else-throw LOGIC above/below is the
                    // contract; this one call is what may need adjusting on the Mac.
                    let rsa = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: dk)   // throws if neither parses
                    auth = .rsa(username: username, privateKey: rsa)
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

        let client: SSHClient
        do {
            client = try await SSHClient.connect(host: host, port: port,
                authenticationMethod: auth, hostKeyValidator: .acceptAnything(), reconnect: .never)
        } catch {
            throw UploadError.transport("SFTP connect failed: \(error)")
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
