import Testing
import Foundation
@testable import LumeshotCore

@Suite struct ReleaseChecksumsTests {
    /// Exactly what `shasum -a 256 *.dmg > SHA256SUMS.txt` writes, which is what
    /// .github/workflows/release.yml runs.
    private let real = Data("""
    6f6ab7ee9870a450bde8cff27593d177672c9e091e93041574bdd172f5feda3b  Lumeshot-0.1.10.dmg
    """.utf8)

    @Test func readsTheDigestTheReleaseWorkflowActuallyWrites() {
        #expect(ReleaseChecksums.expectedSHA256(for: "Lumeshot-0.1.10.dmg", in: real)
                == "6f6ab7ee9870a450bde8cff27593d177672c9e091e93041574bdd172f5feda3b")
    }

    @Test func returnsNilForAFileTheSumsDoNotList() {
        #expect(ReleaseChecksums.expectedSHA256(for: "Lumeshot-9.9.9.dmg", in: real) == nil)
    }

    @Test func readsOneEntryOutOfSeveral() {
        let many = Data("""
        1111111111111111111111111111111111111111111111111111111111111111  a.dmg
        2222222222222222222222222222222222222222222222222222222222222222  Lumeshot-1.0.0.dmg
        3333333333333333333333333333333333333333333333333333333333333333  z.txt
        """.utf8)
        #expect(ReleaseChecksums.expectedSHA256(for: "Lumeshot-1.0.0.dmg", in: many)
                == "2222222222222222222222222222222222222222222222222222222222222222")
    }

    /// `shasum -b` writes `<hex> *<name>`; accepted so a later workflow tweak does
    /// not silently stop verifying.
    @Test func acceptsBinaryModeLines() {
        let binary = Data("4444444444444444444444444444444444444444444444444444444444444444 *Lumeshot-1.0.0.dmg\n".utf8)
        #expect(ReleaseChecksums.expectedSHA256(for: "Lumeshot-1.0.0.dmg", in: binary)
                == "4444444444444444444444444444444444444444444444444444444444444444")
    }

    @Test func ignoresLinesThatAreNotDigests() {
        let noisy = Data("""
        # SHA256 checksums
        not-a-digest  Lumeshot-1.0.0.dmg
        5555555555555555555555555555555555555555555555555555555555555555  Lumeshot-1.0.0.dmg
        """.utf8)
        #expect(ReleaseChecksums.expectedSHA256(for: "Lumeshot-1.0.0.dmg", in: noisy)
                == "5555555555555555555555555555555555555555555555555555555555555555")
    }

    @Test func rejectsShortOrNonHexDigests() {
        for bad in ["abc123  f.dmg", "zzzz\(String(repeating: "z", count: 60))  f.dmg"] {
            #expect(ReleaseChecksums.expectedSHA256(for: "f.dmg", in: Data(bad.utf8)) == nil)
        }
    }

    @Test func emptyOrBinaryInputYieldsNothing() {
        #expect(ReleaseChecksums.expectedSHA256(for: "f.dmg", in: Data()) == nil)
        #expect(ReleaseChecksums.expectedSHA256(for: "f.dmg", in: Data([0xff, 0xfe, 0x00])) == nil)
    }

    @Test func hashesAKnownValue() {
        // The SHA-256 of the empty input, the standard published vector.
        #expect(ReleaseChecksums.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func matchesAcceptsTheRightDataAndRejectsTampering() {
        let payload = Data("lumeshot".utf8)
        let digest = ReleaseChecksums.sha256Hex(payload)
        #expect(ReleaseChecksums.matches(payload, expected: digest))
        #expect(ReleaseChecksums.matches(payload, expected: digest.uppercased()))
        #expect(!ReleaseChecksums.matches(Data("lumeshot ".utf8), expected: digest))
        #expect(!ReleaseChecksums.matches(payload, expected: "not-a-digest"))
    }
}
