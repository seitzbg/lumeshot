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

/// The outcome of committing a trust-on-first-use fingerprint against the
/// authoritative store, resolved *inside* the persistence transaction rather
/// than from the stale snapshot the validator captured when it was built.
///
/// The snapshot goes stale under concurrency: two uploads to a never-pinned
/// destination each start with `knownHostKey == nil`, so each independently
/// decides "first use". Once the first persists key A, the second must not still
/// be treated as first use — if it presents key B, that is a conflict with the
/// pin now on disk, not a fresh trust decision. Only the store knows this, so
/// only the store's transaction can return it.
public enum HostKeyPinResult: Equatable, Sendable {
    /// Pinned just now, or the presented fingerprint matched a pin written since
    /// the validator was built. Either way the connection may proceed.
    case accepted
    /// A *different* fingerprint is already pinned for this endpoint — refuse and
    /// let the caller report both, exactly like an ordinary host-key mismatch.
    case conflict(saved: String, presented: String)
    /// The trust decision could not be recorded. Fail closed: proceeding would
    /// accept a key we never pinned, leaving every later connection in first-use
    /// mode to re-trust whatever is presented.
    case persistenceFailed(String)
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
