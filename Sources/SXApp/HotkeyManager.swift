import AppKit
import Carbon.HIToolbox
import SXCore

@MainActor
final class HotkeyManager {
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: @MainActor () -> Void)] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x5358_484B   // 'SXHK'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hotkey events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hkID.id
            MainActor.assumeIsolated { manager.fire(id: id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ combo: HotkeyCombo, handler: @escaping @MainActor () -> Void) {
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
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
