import AppKit
import SwiftUI
import SXCore

/// A "click to record" control for a single global hotkey. Mirrors the
/// System Settings > Keyboard Shortcuts recording UX: idle shows the current
/// combo (or a prompt); clicking installs a local keyDown monitor that
/// captures the very next modified keypress and reports it back, then tears
/// the monitor down. A trailing clear button (visible only when a combo is
/// set) reports nil.
struct HotkeyRecorderField: View {
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press a key…" : (combo?.displayString ?? "Click to record"))
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            if combo != nil {
                Button {
                    stopRecording()
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear this hotkey")
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if isRecording { stopRecording() }
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbonMods = HotkeyModifiers.carbonMask(
                fromAppKit: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            // A hotkey with no modifier at all would shadow ordinary typing
            // system-wide the instant it's registered — ignore it and keep
            // recording instead of producing an unmodified global hotkey.
            guard carbonMods != 0 else { return event }
            let newCombo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            stopRecording()
            onChange(newCombo)
            return nil   // swallow the keypress that finished recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
