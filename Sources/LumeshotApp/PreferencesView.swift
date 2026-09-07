import AppKit
import SwiftUI
import LumeshotCore

extension PreferencesTab: Identifiable {
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .hotkeys: "Shortcuts"
        case .uploads: "Uploads"
        case .recording: "Recording"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .capture: "viewfinder"
        case .hotkeys: "keyboard"
        case .uploads: "arrow.up.circle"
        case .recording: "record.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Make every capture feel like your own."
        case .capture: "A place and a name for your screenshots."
        case .hotkeys: "Your next capture is a keystroke away."
        case .uploads: "Choose where your captures go."
        case .recording: "Fine-tune video and animated GIFs."
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let showAbout: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Group {
                        if let icon = NSApp.applicationIconImage {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "viewfinder").resizable().padding(8)
                        }
                    }
                    .frame(width: 42, height: 42).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lumeshot").font(.headline)
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 22)
                List(selection: $model.selectedTab) {
                    ForEach(PreferencesTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .padding(.vertical, 6).tag(tab)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 8) {
                    Button("About Lumeshot", action: showAbout)
                        .buttonStyle(.link)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .frame(width: 190).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedTab.title).font(.system(size: 26, weight: .bold))
                    Text(model.selectedTab.subtitle).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 8)
                Group {
                    switch model.selectedTab {
                    case .general: GeneralTab(model: model)
                    case .capture: CaptureTab(model: model)
                    case .hotkeys: HotkeysTab(model: model)
                    case .uploads: UploadsTab(model: model.destinations)
                    case .recording: RecordingTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

/// A setting label with supporting text that wraps without crowding its control.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section("After capture") {
                Toggle(isOn: Binding(
                    get: { model.settings.editor.annotateBeforeShare },
                    set: { value in model.update { $0.editor.annotateBeforeShare = value } }
                )) {
                    SettingLabel("Open the editor", detail: "Annotate, crop, or redact before sharing.")
                }
                Toggle(isOn: Binding(
                    get: { model.settings.saveToDisk },
                    set: { value in model.update { $0.saveToDisk = value } }
                )) {
                    SettingLabel("Save a copy", detail: "Keep screenshots in your capture folder.")
                }
                Toggle(isOn: Binding(
                    get: { model.settings.showNotification },
                    set: { value in model.update { $0.showNotification = value } }
                )) {
                    SettingLabel("Show notifications", detail: "Know when captures are saved or uploaded.")
                }
            }
            Section {
                Label {
                    SettingLabel("Ready to paste", detail: "Captures copy an image. Successful uploads copy a link. Configure automatic uploads in Uploads.")
                } icon: {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped).toggleStyle(.switch).padding(.horizontal, 8)
    }
}

private struct CaptureTab: View {
    @ObservedObject var model: PreferencesModel

    private var displayPath: String {
        (model.settings.captureSavePath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            Section("Storage") {
                HStack(spacing: 16) {
                    Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Capture folder")
                        Text(displayPath).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(displayPath)
                    }
                    Spacer(minLength: 8)
                    Button("Choose…", action: chooseFolder)
                }
                .padding(.vertical, 6)
            }
            Section {
                TextField("Filename template", text: Binding(
                    get: { model.settings.filenameTemplate },
                    set: { value in model.update { $0.filenameTemplate = value } }
                ))
                .textFieldStyle(.roundedBorder)
            } header: { Text("File naming") } footer: {
                Text("Use %y for year, %mo for month, %d for day, %h for hour, %mi for minute, and %s for second. Screenshots are saved as PNG.")
            }
        }
        .formStyle(.grouped).padding(.horizontal, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        panel.directoryURL = URL(fileURLWithPath: (model.settings.captureSavePath as NSString).expandingTildeInPath)
        let applySelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.update { $0.captureSavePath = url.path }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: applySelection)
        } else {
            applySelection(panel.runModal())
        }
    }
}

private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section {
                HotkeyRow(label: "Capture fullscreen", symbol: "display", combo: model.settings.hotkeys.fullscreen) { combo in
                    model.updateHotkeys { $0.fullscreen = combo }
                }
                HotkeyRow(label: "Capture region", symbol: "viewfinder", combo: model.settings.hotkeys.region) { combo in
                    model.updateHotkeys { $0.region = combo }
                }
                HotkeyRow(label: "Capture window", symbol: "macwindow", combo: model.settings.hotkeys.window) { combo in
                    model.updateHotkeys { $0.window = combo }
                }
                HotkeyRow(label: "Start or stop recording", symbol: "record.circle", combo: model.settings.hotkeys.record) { combo in
                    model.updateHotkeys { $0.record = combo }
                }
            } header: { Text("Global shortcuts") } footer: {
                Text("Click a shortcut, then press a key combination with ⌘, ⌥, ⌃, or ⇧. Shortcuts work even when Lumeshot is in the background.")
            }
        }
        .formStyle(.grouped).padding(.horizontal, 8)
    }
}

private struct HotkeyRow: View {
    let label: String
    let symbol: String
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            Text(label)
            Spacer()
            HotkeyRecorderField(combo: combo, onChange: onChange).accessibilityLabel(label)
        }
        .padding(.vertical, 6)
    }
}

private struct UploadsTab: View {
    @ObservedObject var model: DestinationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        SettingLabel("Upload after capture", detail: "Upload to your active uploader and copy the link.")
                        Spacer(minLength: 0)
                        Toggle("Upload after capture", isOn: Binding(
                        get: { model.settings.uploadAfterCapture },
                        set: { model.setUploadAfterCapture($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.settings.activeDestination == nil && !model.settings.uploadAfterCapture)
                    }
                    if model.settings.activeDestination == nil {
                        Text("Choose an active uploader below to turn this on.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
                DestinationsView(model: model)
            }
            .padding(28)
        }
    }
}

private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    @State private var gifMaxWidthText = ""
    @FocusState private var editingWidth: Bool

    var body: some View {
        Form {
            Section("Video") {
                Toggle(isOn: Binding(
                    get: { model.settings.recording.systemAudio },
                    set: { value in model.update { $0.recording.systemAudio = value } }
                )) {
                    SettingLabel("System audio", detail: "Include sound playing on your Mac.")
                }
                .toggleStyle(.switch)
                Picker("Video format", selection: Binding(
                    get: { model.settings.recording.videoCodec.rawValue },
                    set: { value in
                        guard let codec = RecordingSettings.VideoCodec(rawValue: value) else { return }
                        model.update { $0.recording.videoCodec = codec }
                    }
                )) {
                    Text("H.264 · Most compatible").tag("h264")
                    Text("HEVC · Smaller files").tag("hevc")
                }
            }
            Section {
                Stepper(value: Binding(
                    get: { model.settings.recording.gifFPS },
                    set: { value in model.update { $0.recording.gifFPS = value } }
                ), in: 1...60) {
                    LabeledContent("Frame rate", value: "\(model.settings.recording.gifFPS) fps")
                }
                TextField("Maximum width", text: $gifMaxWidthText, prompt: Text("Original size"))
                    .textFieldStyle(.roundedBorder)
                    .focused($editingWidth)
                    .onAppear { gifMaxWidthText = model.settings.recording.gifMaxWidth.map(String.init) ?? "" }
                    .onChange(of: model.settings.recording.gifMaxWidth) { _, value in
                        gifMaxWidthText = value.map(String.init) ?? ""
                    }
                    .onSubmit { saveWidth() }
                    .onChange(of: editingWidth) { _, focused in if !focused { saveWidth() } }
            } header: { Text("Animated GIFs") } footer: {
                Text("Width is in pixels. Leave it blank to keep the source width. Lower frame rates and smaller dimensions produce smaller files.")
            }
        }
        .formStyle(.grouped).padding(.horizontal, 8)
    }

    private func saveWidth() {
        let width = Int(gifMaxWidthText).flatMap { $0 > 0 ? $0 : nil }
        model.update { $0.recording.gifMaxWidth = width }
        // Normalize even when the stored value is unchanged (and onChange
        // therefore does not fire), e.g. invalid input when already unlimited.
        gifMaxWidthText = width.map(String.init) ?? ""
    }
}
