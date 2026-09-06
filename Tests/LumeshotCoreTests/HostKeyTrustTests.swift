import Foundation
import Testing
@testable import LumeshotCore

@Suite struct HostKeyTrustTests {
    private let fp1 = "SHA256:AAAAbbbbCCCCddddEEEEffffGGGGhhhhIIIIjjjjKKK"
    private let fp2 = "SHA256:ZZZZyyyyXXXXwwwwVVVVuuuuTTTTssssRRRRqqqqPPP"

    @Test func nothingPinnedYetTrustsOnFirstUse() {
        #expect(HostKeyTrust.decide(saved: nil, presented: fp1) == .trustOnFirstUse(fp1))
    }

    /// An empty string is what a hand-edited settings.json can produce; treat it
    /// as "not pinned" rather than as a pin that can never match.
    @Test func anEmptyPinCountsAsUnpinned() {
        #expect(HostKeyTrust.decide(saved: "", presented: fp1) == .trustOnFirstUse(fp1))
    }

    @Test func theSameKeyMatches() {
        #expect(HostKeyTrust.decide(saved: fp1, presented: fp1) == .match)
    }

    /// The case that matters: a changed key must fail closed, not re-pin.
    @Test func aChangedKeyIsAMismatch() {
        #expect(HostKeyTrust.decide(saved: fp1, presented: fp2)
                == .mismatch(saved: fp1, presented: fp2))
    }

    @Test func fingerprintMatchesTheOpenSSHFormat() {
        // SHA-256 of the empty input, which ssh-keygen would render the same way.
        let digest: [UInt8] = [
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8,
            0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
            0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
        ]
        let fingerprint = HostKeyTrust.fingerprint(sha256Digest: digest)
        #expect(fingerprint == "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        #expect(!fingerprint.contains("="))   // OpenSSH strips base64 padding
    }

    @Test func theMismatchMessageNamesBothFingerprints() {
        let message = HostKeyTrust.mismatchMessage(host: "sftp.example.com",
                                                   saved: fp1, presented: fp2)
        #expect(message.contains("sftp.example.com"))
        #expect(message.contains(fp1))
        #expect(message.contains(fp2))
    }
}
