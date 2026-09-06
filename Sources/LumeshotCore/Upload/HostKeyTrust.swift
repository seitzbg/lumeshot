import Foundation

/// What to do with the host key an SSH server just presented.
public enum HostKeyDecision: Equatable, Sendable {
    /// Nothing pinned yet — accept and remember this fingerprint.
    case trustOnFirstUse(String)
    /// Matches what we pinned.
    case match
    /// Differs from what we pinned. Fail closed: either the server was
    /// legitimately rekeyed or someone is impersonating it, and we cannot tell
    /// which, so the user has to decide.
    case mismatch(saved: String, presented: String)
}

/// Trust-on-first-use host-key policy, kept pure so it is testable without a
/// live SSH server.
///
/// `.acceptAnything()` — what this replaces — removes SSH's entire
/// server-authentication guarantee: an active network attacker can impersonate
/// the configured host, collect the password or a key-auth attempt, and take or
/// replace the uploaded capture.
public enum HostKeyTrust {
    public static func decide(saved: String?, presented: String) -> HostKeyDecision {
        guard let saved, !saved.isEmpty else { return .trustOnFirstUse(presented) }
        return saved == presented ? .match : .mismatch(saved: saved, presented: presented)
    }

    /// OpenSSH-style `SHA256:<unpadded base64>` over the SSH wire-format public
    /// key blob — the same string `ssh-keygen -lf` prints, so a user can compare
    /// it against `ssh-keyscan` output by eye.
    public static func fingerprint(sha256Digest: [UInt8]) -> String {
        "SHA256:" + Data(sha256Digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// Human-readable explanation for a refused connection.
    public static func mismatchMessage(host: String, saved: String, presented: String) -> String {
        """
        The SSH host key for \(host) changed. Refusing to connect.
        Pinned:    \(saved)
        Presented: \(presented)
        If you rekeyed the server on purpose, remove and re-add the destination \
        to trust the new key.
        """
    }
}
