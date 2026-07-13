import SwiftUI

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
        .frame(width: 560, height: 420)
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
    var body: some View {
        Text("Capture").padding()
    }
}

private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Hotkeys").padding()
    }
}

private struct UploadsTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Uploads").padding()
    }
}

private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Recording").padding()
    }
}
