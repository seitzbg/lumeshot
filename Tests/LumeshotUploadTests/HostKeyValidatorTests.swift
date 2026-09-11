import Foundation
import Testing
@testable import LumeshotUpload
import LumeshotCore

/// The trust-and-pin decision, isolated from NIO. `TOFUHostKeyValidator.outcome`
/// is what `validateHostKey` calls once it has the presented fingerprint, so
/// exercising it directly covers the concurrent-first-use race without a live SSH
/// server or a constructed `NIOSSHPublicKey`.
@Suite struct HostKeyValidatorTests {
    @Test func firstUseAcceptedByTheTransactionSucceeds() {
        let validator = TOFUHostKeyValidator(knownHostKey: nil, remember: { _ in .accepted })
        #expect(validator.outcome(forPresented: "SHA256:whatever") == .accept)
    }

    /// The heart of the P1: two uploads to an unpinned destination each begin as
    /// first use; once one pins key A, the other — which still snapshotted "no pin"
    /// — presents key B. The persistence transaction sees the pin the snapshot
    /// missed and reports a conflict, so the handshake fails closed instead of
    /// trusting B.
    @Test func firstUseThatConflictsWithAConcurrentlyPinnedKeyIsRefused() {
        let validator = TOFUHostKeyValidator(
            knownHostKey: nil,
            remember: { presented in .conflict(saved: "SHA256:A", presented: presented) })
        #expect(validator.outcome(forPresented: "SHA256:B") == .reject(.hostKeyMismatch("SHA256:B")))
        #expect(validator.mismatch?.saved == "SHA256:A")
        #expect(validator.mismatch?.presented == "SHA256:B")
    }

    /// A trust decision that could not be recorded fails closed rather than
    /// proceeding on a key that was never pinned.
    @Test func firstUseThatCannotBeRecordedFailsClosed() {
        let validator = TOFUHostKeyValidator(
            knownHostKey: nil, remember: { _ in .persistenceFailed("disk full") })
        guard case .reject(.transport(let reason)) = validator.outcome(forPresented: "SHA256:X") else {
            Issue.record("expected a transport rejection"); return
        }
        #expect(reason.contains("disk full"))
    }

    /// A presented key matching the pin is accepted without touching persistence.
    @Test func aMatchingPinnedKeyIsAcceptedWithoutRemembering() {
        let flag = CallFlag()
        let validator = TOFUHostKeyValidator(
            knownHostKey: "SHA256:pinned", remember: { _ in flag.mark(); return .accepted })
        #expect(validator.outcome(forPresented: "SHA256:pinned") == .accept)
        #expect(!flag.called)
    }

    /// A different key when one is already pinned is refused with both fingerprints.
    @Test func aChangedPinnedKeyIsRefused() {
        let validator = TOFUHostKeyValidator(knownHostKey: "SHA256:pinned", remember: { _ in .accepted })
        #expect(validator.outcome(forPresented: "SHA256:changed")
                == .reject(.hostKeyMismatch("SHA256:changed")))
        #expect(validator.mismatch?.saved == "SHA256:pinned")
        #expect(validator.mismatch?.presented == "SHA256:changed")
    }
}

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _called = false
    func mark() { lock.lock(); _called = true; lock.unlock() }
    var called: Bool { lock.lock(); defer { lock.unlock() }; return _called }
}
