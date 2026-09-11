import Foundation
import Testing
import LumeshotCore
@testable import LumeshotApp

/// `UploadService.hostKeyPinner` is the transaction that closes the P1 race: it
/// decides — against the authoritative store, not a snapshot — whether a
/// first-seen key may be trusted.
@MainActor @Suite struct HostKeyPinnerTests {
    private func storeWithUnpinnedSFTP(id: String, host: String, port: Int) throws -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.upload = settings.upload.addingOrUpdating(
            UploadDestination(id: id, name: "S", kind: .sftp,
                sftpConfig: SFTPConfig(host: host, port: port, username: "u",
                                       remoteDirectory: "/up", publicURLBase: "https://x")))
        try store.save(settings)
        return store
    }

    private func pinnedKey(_ store: SettingsStore, id: String) -> String? {
        store.loadOrDefault().0.upload.destinations.first { $0.id == id }?.sftpConfig?.knownHostKey
    }

    private func service(_ store: SettingsStore) -> UploadService {
        UploadService(credentials: UnusedCredentials(), settingsStore: store)
    }

    @Test func firstUsePinsTheKeyAndAccepts() throws {
        let store = try storeWithUnpinnedSFTP(id: "d", host: "h", port: 22)
        let pin = service(store).hostKeyPinner(for: "d", host: "h", port: 22)
        #expect(pin("SHA256:A") == .accepted)
        #expect(pinnedKey(store, id: "d") == "SHA256:A")
    }

    @Test func theSameKeyOnALaterConnectionMatchesAndAccepts() throws {
        let store = try storeWithUnpinnedSFTP(id: "d", host: "h", port: 22)
        let pin = service(store).hostKeyPinner(for: "d", host: "h", port: 22)
        #expect(pin("SHA256:A") == .accepted)
        #expect(pin("SHA256:A") == .accepted)
        #expect(pinnedKey(store, id: "d") == "SHA256:A")
    }

    /// The race, at the transaction that fixes it: two pinners for the same
    /// still-unpinned destination (the two concurrent first-use connections). The
    /// first pins A; the second presenting B is a conflict, and A is untouched.
    @Test func aConflictingSecondFirstUseIsRefusedAndTheExistingPinIsKept() throws {
        let store = try storeWithUnpinnedSFTP(id: "d", host: "h", port: 22)
        let service = service(store)
        let first = service.hostKeyPinner(for: "d", host: "h", port: 22)
        let second = service.hostKeyPinner(for: "d", host: "h", port: 22)
        #expect(first("SHA256:A") == .accepted)
        #expect(second("SHA256:B") == .conflict(saved: "SHA256:A", presented: "SHA256:B"))
        #expect(pinnedKey(store, id: "d") == "SHA256:A")   // B never overwrote A
    }

    /// The same race with the two pinners fired *concurrently* behind a barrier:
    /// the `SettingsStore.mutate` lock must serialize them so exactly one key is
    /// pinned and the other is reported as a conflict against it — never both
    /// accepted, and never a lost write.
    @Test func twoConcurrentFirstUsePinnersSerializeToOneWinnerAndOneConflict() throws {
        let store = try storeWithUnpinnedSFTP(id: "d", host: "h", port: 22)
        let service = service(store)
        let a = service.hostKeyPinner(for: "d", host: "h", port: 22)
        let b = service.hostKeyPinner(for: "d", host: "h", port: 22)

        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = ResultsBox()
        for (pinner, key) in [(a, "SHA256:A"), (b, "SHA256:B")] {
            group.enter()
            DispatchQueue.global().async {
                start.wait()                 // both released together
                results.add(pinner(key))
                group.leave()
            }
        }
        start.signal(); start.signal()
        group.wait()

        let outcomes = results.all
        #expect(outcomes.count == 2)
        #expect(outcomes.filter { $0 == .accepted }.count == 1)
        let stored = pinnedKey(store, id: "d")
        #expect(stored == "SHA256:A" || stored == "SHA256:B")
        // The loser conflicts, naming the stored (winning) key as the saved one.
        guard let conflict = outcomes.first(where: { if case .conflict = $0 { return true }; return false }),
              case .conflict(let saved, let presented) = conflict else {
            Issue.record("expected exactly one conflict outcome"); return
        }
        #expect(saved == stored)
        #expect(presented != stored)
    }

    /// If the destination was retargeted (or removed) while connecting, the key
    /// from the endpoint that actually answered is accepted but not stapled onto
    /// the new endpoint.
    @Test func aKeyForANoLongerMatchingEndpointIsAcceptedWithoutPinning() throws {
        let store = try storeWithUnpinnedSFTP(id: "d", host: "h", port: 22)
        let pin = service(store).hostKeyPinner(for: "d", host: "other-host", port: 22)
        #expect(pin("SHA256:A") == .accepted)
        #expect(pinnedKey(store, id: "d") == nil)
    }

    /// With no settings store there is nothing to pin against, so first use is
    /// simply trusted — the behaviour for tests and non-app callers.
    @Test func withoutAStoreEverythingIsAccepted() {
        let pin = UploadService(credentials: UnusedCredentials()).hostKeyPinner(for: "d", host: "h", port: 22)
        #expect(pin("SHA256:anything") == .accepted)
    }
}

/// Collects pin outcomes from concurrent threads.
private final class ResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [HostKeyPinResult] = []
    func add(_ r: HostKeyPinResult) { lock.lock(); _all.append(r); lock.unlock() }
    var all: [HostKeyPinResult] { lock.lock(); defer { lock.unlock() }; return _all }
}
