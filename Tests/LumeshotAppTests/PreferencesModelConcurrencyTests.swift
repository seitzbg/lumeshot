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
    /// Deterministic, not timing-based: the edit closure releases the background
    /// pin, waits until it has reached its transaction attempt, then waits for it
    /// to *complete*. Under the old split load/save no lock is held during the
    /// closure, so the pin completes and the following save overwrites it (the
    /// completion wait returns) — the bug. Under the transaction the lock is held
    /// during the closure, so the pin is blocked until the edit commits; that
    /// completion wait times out (confirming it is blocked, not lost) and both
    /// writes survive once the lock is released.
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

        let startPin = DispatchSemaphore(value: 0)
        let reachedMutate = DispatchSemaphore(value: 0)
        let pinDone = DispatchSemaphore(value: 0)

        // The SSH host-key callback, firing on a background thread mid-edit.
        DispatchQueue.global().async {
            startPin.wait()          // not until the edit is in flight
            reachedMutate.signal()   // about to enter the pin transaction
            _ = try? store.mutate { pinned in
                if let i = pinned.upload.destinations.firstIndex(where: { $0.id == "d" }) {
                    pinned.upload.destinations[i].sftpConfig?.knownHostKey = "SHA256:learned"
                }
            }
            pinDone.signal()
        }

        prefs.update { s in
            s.filenameTemplate = "changed-by-preference"
            startPin.signal()
            reachedMutate.wait()
            // Old split load/save holds no lock here, so the pin completes and is
            // then overwritten (this returns). The transaction holds the lock, so
            // the pin is blocked until this closure returns; bound the wait.
            _ = pinDone.wait(timeout: .now() + 1.0)
        }
        pinDone.wait()   // the pin has fully completed before we read the file

        let onDisk = store.loadOrDefault().0
        #expect(onDisk.filenameTemplate == "changed-by-preference")   // the edit survived…
        #expect(onDisk.upload.destinations.first?.sftpConfig?.knownHostKey == "SHA256:learned")   // …and so did the pin
    }
}
