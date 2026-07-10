import AppKit
import Carbon.HIToolbox
import SXCore

/// Manages global hotkey registration via Carbon's `RegisterEventHotKey` API.
///
/// Intended lifetime: a single instance is created at app launch and retained
/// for the lifetime of the app (owned by `AppDelegate`). The Carbon callback
/// resolves its target through the weak `current` static rather than an
/// unretained raw pointer, so if the instance were ever deallocated the
/// callback safely degrades to a no-op instead of dereferencing freed memory.
@MainActor
final class HotkeyManager {
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: @MainActor () -> Void)] = [:]
    private var handlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x5358_484B   // 'SXHK'
    private static weak var current: HotkeyManager?

    init() {
        HotkeyManager.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hotkey events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            MainActor.assumeIsolated { HotkeyManager.current?.fire(id: hkID.id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    func register(_ combo: HotkeyCombo, handler: @escaping @MainActor () -> Void) {
        var ref: EventHotKeyRef?
        let id = Self.nextID
        Self.nextID += 1
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Hotkey registration failed (keyCode \(combo.keyCode), status \(status))")
            return
        }
        hotKeys[id] = (ref, handler)
    }

    func unregisterAll() {
        for (_, entry) in hotKeys {
            UnregisterEventHotKey(entry.ref)
        }
        hotKeys.removeAll()
    }

    private func fire(id: UInt32) {
        hotKeys[id]?.handler()
    }
}
