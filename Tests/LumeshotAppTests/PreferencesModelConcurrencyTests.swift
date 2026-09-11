import Foundation
import Testing
import LumeshotCore
@testable import LumeshotApp

@MainActor @Suite struct PreferencesModelConcurrencyTests {
    /// A General/Capture/Recording/Shortcut edit must not clobber a host-key pin
    /// the SSH callback writes from a background thread mid-edit. The whole
    /// load-modify-save now runs inside one `SettingsStore` transaction; separate
    /// load and save calls let the pin land in the gap between them and then wrote
    /// the pre-pin snapshot back over it, so the next connection trusted a
    /// presented key afresh.
    ///
    /// The edit closure fires the background pin, then waits briefly. Under the
    /// old separate load/save the pin completes during that wait and the following
    /// save overwrites it; under the transaction the background write blocks on
    /// the lock until the edit commits, so both survive.
    @Test func aPreferenceEditDoesNotDropAConcurrentlyLearnedPin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        var initial = AppSettings.default
        initial.upload = initial.upload.addingOrUpdating(
            UploadDestination(id: "d", name: "S", kind: .sftp,
                sftpConfig: SFTPConfig(host: "h", port: 22, username: "u",
                                       remoteDirectory: "/up", publicURLBase: "https://x")))
        try store.save(initial)

        let prefs = PreferencesModel(store: store, credentials: UnusedCredentials(),
                                     onChange: {}, applyHotkeys: { _ in })

        let pinWritten = DispatchSemaphore(value: 0)
        prefs.update { s in
            s.filenameTemplate = "changed-by-preference"
            // The SSH host-key callback, firing on a background thread mid-edit.
            DispatchQueue.global().async {
                _ = try? store.mutate { pinned in
                    if let i = pinned.upload.destinations.firstIndex(where: { $0.id == "d" }) {
                        pinned.upload.destinations[i].sftpConfig?.knownHostKey = "SHA256:learned"
                    }
                }
                pinWritten.signal()
            }
            Thread.sleep(forTimeInterval: 0.2)   // give the background write time to land
        }
        pinWritten.wait()

        let onDisk = store.loadOrDefault().0
        #expect(onDisk.filenameTemplate == "changed-by-preference")   // the edit survived…
        #expect(onDisk.upload.destinations.first?.sftpConfig?.knownHostKey == "SHA256:learned")   // …and so did the pin
    }
}
