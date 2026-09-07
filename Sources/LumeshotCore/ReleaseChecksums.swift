import Foundation
import CryptoKit

/// Reads the `SHA256SUMS.txt` published alongside each release dmg.
///
/// **What this does and does not buy.** The sums file comes from the same release
/// as the dmg, so a matching digest proves the download arrived intact — it does
/// not prove the release is genuine, because anyone able to replace the dmg could
/// replace the sums file too. The real guarantee is the Developer ID signature and
/// notarization, which macOS enforces when the dmg is opened, provided the file
/// carries the quarantine attribute (see `UpdateCheckController`). Treat a digest
/// match as "not truncated or corrupted", nothing stronger.
public enum ReleaseChecksums {
    /// The digest recorded for `filename`, or nil if the file does not list it.
    ///
    /// Accepts `shasum -a 256` output: `<64 hex>  <name>` in text mode, and the
    /// `<64 hex> *<name>` binary-mode spelling, since either is a plausible way for
    /// the release workflow to be rewritten later.
    public static func expectedSHA256(for filename: String, in sumsFile: Data) -> String? {
        guard let text = String(data: sumsFile, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let digest = String(parts[0]).lowercased()
            guard isSHA256Hex(digest) else { continue }
            var name = parts.dropFirst().joined(separator: " ")
            if name.hasPrefix("*") { name.removeFirst() }   // binary-mode marker
            if name == filename { return digest }
        }
        return nil
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `data` hashes to `expected`. Case-insensitive; the comparison is
    /// integrity, not authentication, so it needs no constant-time treatment.
    public static func matches(_ data: Data, expected: String) -> Bool {
        guard isSHA256Hex(expected.lowercased()) else { return false }
        return sha256Hex(data) == expected.lowercased()
    }

    private static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }
}
