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
