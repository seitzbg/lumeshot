import AppKit
import SwiftUI
import LumeshotCore

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)
            CaptureTab(model: model)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(PreferencesTab.capture)
            HotkeysTab(model: model)
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(PreferencesTab.hotkeys)
            UploadsTab(model: model)
                .tabItem { Label("Uploads", systemImage: "arrow.up.circle") }
                .tag(PreferencesTab.uploads)
            RecordingTab(model: model)
                .tabItem { Label("Recording", systemImage: "video") }
                .tag(PreferencesTab.recording)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Toggle("Save screenshots to disk", isOn: Binding(
                get: { model.settings.saveToDisk },
                set: { newValue in model.update { $0.saveToDisk = newValue } }
            ))
            Toggle("Copy to clipboard", isOn: Binding(
                get: { model.settings.copyToClipboard },
                set: { newValue in model.update { $0.copyToClipboard = newValue } }
            ))
            Toggle("Show notification", isOn: Binding(
                get: { model.settings.showNotification },
                set: { newValue in model.update { $0.showNotification = newValue } }
            ))
            Toggle("Annotate before sharing", isOn: Binding(
                get: { model.settings.editor.annotateBeforeShare },
                set: { newValue in model.update { $0.editor.annotateBeforeShare = newValue } }
            ))
        }
        .padding()
    }
}

private struct CaptureTab: View {
    @ObservedObject var model: PreferencesModel

    private var displayPath: String {
        (model.settings.captureSavePath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            HStack {
                TextField("Save Folder", text: .constant(displayPath))
                    .disabled(true)
                Button("Choose…") { chooseFolder() }
            }
            TextField("Filename Template", text: Binding(
                get: { model.settings.filenameTemplate },
                set: { newValue in model.update { $0.filenameTemplate = newValue } }
            ))
            Text("Tokens: %y year  %mo month  %d day  %h hour  %mi minute  %s second")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.captureSavePath = url.path }
    }
}

private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            HotkeyRow(label: "Capture Fullscreen", combo: model.settings.hotkeys.fullscreen) { newCombo in
                model.updateHotkeys { $0.fullscreen = newCombo }
            }
            HotkeyRow(label: "Capture Region", combo: model.settings.hotkeys.region) { newCombo in
                model.updateHotkeys { $0.region = newCombo }
            }
            HotkeyRow(label: "Capture Window", combo: model.settings.hotkeys.window) { newCombo in
                model.updateHotkeys { $0.window = newCombo }
            }
            HotkeyRow(label: "Toggle Recording", combo: model.settings.hotkeys.record) { newCombo in
                model.updateHotkeys { $0.record = newCombo }
            }
        }
        .padding()
    }
}

private struct HotkeyRow: View {
    let label: String
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyRecorderField(combo: combo, onChange: onChange)
        }
    }
}

private struct UploadsTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Upload after capture", isOn: Binding(
                get: { model.destinations.settings.uploadAfterCapture },
                set: { newValue in model.destinations.setUploadAfterCapture(newValue) }
            ))
            .padding([.horizontal, .top])
            Divider()
            DestinationsView(model: model.destinations)
        }
    }
}

private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    @State private var gifMaxWidthText = ""

    var body: some View {
        Form {
            Toggle("Capture system audio", isOn: Binding(
                get: { model.settings.recording.systemAudio },
                set: { newValue in model.update { $0.recording.systemAudio = newValue } }
            ))
            // VideoCodec isn't Hashable, so Picker binds through its String
            // rawValue rather than the enum itself (see Task 4's Interfaces).
            Picker("Video Codec", selection: Binding(
                get: { model.settings.recording.videoCodec.rawValue },
                set: { newValue in
                    guard let codec = RecordingSettings.VideoCodec(rawValue: newValue) else { return }
                    model.update { $0.recording.videoCodec = codec }
                }
            )) {
                Text("H.264").tag("h264")
                Text("HEVC").tag("hevc")
            }
            Stepper(value: Binding(
                get: { model.settings.recording.gifFPS },
                set: { newValue in model.update { $0.recording.gifFPS = newValue } }
            ), in: 1...60) {
                Text("GIF Frame Rate: \(model.settings.recording.gifFPS) fps")
            }
            TextField("GIF Max Width (blank = source width)", text: $gifMaxWidthText)
                .onAppear {
                    gifMaxWidthText = model.settings.recording.gifMaxWidth.map(String.init) ?? ""
                }
                .onChange(of: model.settings.recording.gifMaxWidth) { _, newValue in
                    gifMaxWidthText = newValue.map(String.init) ?? ""
                }
                .onSubmit {
                    // Non-numeric, zero, or negative input means "no max width" —
                    // same convention as HistoryView's GifExportSheet.
                    let width = Int(gifMaxWidthText).flatMap { $0 > 0 ? $0 : nil }
                    model.update { $0.recording.gifMaxWidth = width }
                }
        }
        .padding()
    }
}
