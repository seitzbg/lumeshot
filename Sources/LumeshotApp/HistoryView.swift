import AppKit
import QuickLookUI
import ImageIO
import SwiftUI
import LumeshotCore
import LumeshotRecord
import LumeshotUpload

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var query: String = "" { didSet { reload() } }
    @Published var filter: HistoryFilter = .all
    @Published var actionError: String?
    @Published var previewEntry: HistoryEntry?
    @Published var uploadEntry: HistoryEntry?
    @Published private(set) var uploading: Set<String> = []
    @Published var loadError: String?
    @Published var exportingEntry: HistoryEntry?
    @Published var exportError: String?
    @Published var deleteError: String?
    /// Entries with a remote deletion already in flight. Without this a
    /// second click schedules a second request, and a late failure from it
    /// would report an error for a row the first request already removed.
    @Published private(set) var deletionsInFlight: Set<String> = []
    private let settingsStore: SettingsStore?
    private let effects: any PipelineEffects
    private let uploadFile: (FilePart, UploadDestination) async throws -> UploadResult
    private let store: HistoryStore
    private let deletionService: RemoteDeletionService
    /// Re-read when the window is shown, not just when it is created.
    var recordingSettings: RecordingSettings

    init(store: HistoryStore, http: HTTPClient = URLSessionHTTPClient(),
        recordingSettings: RecordingSettings = .default,
        settingsStore: SettingsStore? = nil,
        effects: any PipelineEffects = AppPipelineEffects(),
        credentials: CredentialStore = KeychainCredentialStore(),
        uploadFile: ((FilePart, UploadDestination) async throws -> UploadResult)? = nil) {
        self.settingsStore = settingsStore
        self.effects = effects
        let service = UploadService(http: http, credentials: credentials, settingsStore: settingsStore, activity: .shared)
        self.uploadFile = uploadFile ?? { part, destination in try await service.upload(part: part, destination: destination) }
        self.store = store
        self.deletionService = RemoteDeletionService(http: http, credentials: credentials)
        self.recordingSettings = recordingSettings
        reload()
    }

    var defaultGifFPS: Int { recordingSettings.gifFPS }
    var defaultGifMaxWidth: Int? { recordingSettings.gifMaxWidth }

    func reload() {
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.all(limit: 500)
                : try store.search(matching: query, limit: 500)
            loadError = nil
        } catch {
            AppLog.log("History: load failed: \(error)")
            entries = []
            loadError = "Couldn’t load history."
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ urlString: String) {
        // Only ever open an http(s) link. A row recorded before result URLs were
        // validated (or a custom uploader whose server returned a file:/custom
        // scheme) must not turn "open the uploaded image" into launching a local
        // file or another app's URL handler.
        guard let url = WebLink.openable(urlString) else {
            AppLog.log("History: refused to open a non-web link")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var visibleEntries: [HistoryEntry] { entries.filter { filter.includes($0) } }

    var destinations: [UploadDestination] { settingsStore?.loadOrDefault().0.upload.destinations ?? [] }

    func preferredDestination(for entry: HistoryEntry) -> String? {
        let choices = destinations
        if let id = entry.destinationID, choices.contains(where: { $0.id == id }) { return id }
        // Legacy rows have names only. Never guess when two uploaders share a name.
        let matches = choices.filter { $0.name == entry.destinationName }
        if entry.destinationID == nil, matches.count == 1 { return matches[0].id }
        return nil
    }

    func isBusy(_ entry: HistoryEntry) -> Bool {
        uploading.contains(entry.id) || deletionsInFlight.contains(entry.id)
            || (entry.filePath != nil && UploadActivity.shared.running.contains { $0.filePath == entry.filePath })
    }

    func hasLocalFile(_ entry: HistoryEntry) -> Bool {
        entry.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    func preview(_ entry: HistoryEntry) {
        guard hasLocalFile(entry) else {
            actionError = "The local file is no longer available."
            return
        }
        previewEntry = entry
    }

    func copyImage(_ entry: HistoryEntry) {
        guard let path = entry.filePath, !MIMEType.isVideo(path: path),
              let image = NSImage(contentsOfFile: path) else {
            actionError = "The local image is no longer available."
            return
        }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.writeObjects([image]) { actionError = "Couldn’t copy the image." }
    }

    /// A retry updates its failed row; another upload of a successful capture gets
    /// its own row so the existing link and remote deletion token remain available.
    func upload(_ entry: HistoryEntry, to destination: UploadDestination) async {
        guard !isBusy(entry) else { return }
        guard let path = entry.filePath, hasLocalFile(entry) else {
            actionError = "The local file is no longer available, so this capture can’t be uploaded again."
            return
        }
        uploading.insert(entry.id)
        defer { uploading.remove(entry.id); reload() }
        let fileURL = URL(fileURLWithPath: path)
        var row = entry
        if entry.url != nil || entry.deletionURL != nil {
            row.id = UUID().uuidString
            row.capturedAt = Date()
        }
        row.destinationID = destination.id
        row.destinationName = destination.name
        // A new attempt owns neither link yet. Copying them from the original
        // row gave a *failed* attempt the earlier upload's remote deletion
        // token, so "Delete remote upload" on the failure deleted the upload
        // that had succeeded — while its own row still showed a working link.
        // Both are set below, and only from this attempt's own result.
        row.url = nil
        row.deletionURL = nil
        row.uploadFailed = true // A crash during transfer leaves a recoverable retry.
        do {
            let part = try FilePart.file(fieldName: "file", filename: fileURL.lastPathComponent,
                                         mimeType: MIMEType.forExtension(fileURL.pathExtension), url: fileURL)
            try store.insert(row)
            let clipboardCount = effects.clipboardChangeCount
            let result = try await uploadFile(part, destination)
            row.url = result.url
            row.deletionURL = result.deletionURL
            row.uploadFailed = false
            do {
                try store.insert(row)
            } catch {
                // Keep the returned link available even when history cannot be updated.
                actionError = "Upload succeeded, but History couldn’t save its link. The link was copied if the clipboard was unchanged."
            }
            if effects.clipboardChangeCount == clipboardCount { effects.copyTextToClipboard(result.url) }
        } catch {
            actionError = UploadFeedback.message(for: error) + " Your local file was kept."
        }
    }

    func removeFromHistory(_ entry: HistoryEntry) {
        guard !isBusy(entry) else { return }
        do { try store.delete(id: entry.id) }
        catch { deleteError = "Couldn’t remove the history entry." }
        // UploadActivity is a separate in-memory model; deleting the row alone left
        // it holding a failure the user had just dismissed, which the menu-bar icon
        // and the History banner both kept rendering.
        UploadActivity.shared.forgetEntry(id: entry.id)
        reload()
    }

    /// Explicit remote deletion leaves the local file and history row intact.
    func deleteRemote(_ entry: HistoryEntry) async {
        guard !isBusy(entry), let deletionURL = entry.deletionURL,
              let url = URL(string: deletionURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        deletionsInFlight.insert(entry.id)
        defer { deletionsInFlight.remove(entry.id); reload() }
        do {
            let destinationID = preferredDestination(for: entry)
            let destination = destinations.first { $0.id == destinationID }
            try await deletionService.delete(url.absoluteString, destination: destination)
            try store.setURL(id: entry.id, url: nil, deletionURL: nil, failed: false)
            UploadActivity.shared.forgetLink(entry.url)
        } catch {
            deleteError = "Couldn’t delete the remote upload. The entry was kept. " + RemoteDeletionService.message(for: error)
        }
    }

    func beginGifExport(_ entry: HistoryEntry) {
        guard entry.filePath != nil else { return }
        exportingEntry = entry
    }

    /// Converts `entry`'s video to a sibling `.gif` (same name, `.gif`
    /// extension; colliding names get a numeric suffix), inserts a new history
    /// row for it, and reloads. Local-first: the GIF is fully written before
    /// the row lands; the source mp4 row is never touched.
    func exportGif(for entry: HistoryEntry, fps: Int, maxWidth: Int?) async {
        guard let sourcePath = entry.filePath else { return }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let gifURL = RecordingDelivery.gifOutputURL(for: sourceURL)
        do {
            try await GifConverter.convert(videoURL: sourceURL, to: gifURL,
                                           options: .init(fps: fps, maxWidth: maxWidth))
            let row = HistoryEntry(id: UUID().uuidString, capturedAt: Date(),
                                   filePath: gifURL.path, url: nil, deletionURL: nil,
                                   destinationName: nil, uploadFailed: false)
            try store.insert(row)
            AppLog.log("GIF exported: \(gifURL.path)")
            exportError = nil
        } catch {
            AppLog.log("GIF export failed: \(error)")
            exportError = "GIF export failed: \(error.localizedDescription)"
        }
        exportingEntry = nil
        reload()
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", images = "Images", videos = "Videos", failed = "Failed uploads"
    var id: Self { self }
    func includes(_ entry: HistoryEntry) -> Bool {
        let path = entry.filePath ?? entry.url.flatMap { URL(string: $0)?.path } ?? ""
        switch self {
        case .all: return true
        case .images: return !path.isEmpty && !MIMEType.isVideo(path: path)
        case .videos: return MIMEType.isVideo(path: path)
        case .failed: return entry.uploadFailed
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject private var activity = UploadActivity.shared
    @State private var selection: String?
    @State private var removing: HistoryEntry?
    @State private var deletingRemote: HistoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("History").font(.title2.bold())
                    Spacer()
                    TextField("Search captures", text: $model.query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                }
                Picker("Filter captures", selection: $model.filter) {
                    ForEach(HistoryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .pickerStyle(.segmented)
            }
            .padding(20)
            Divider()
            UploadActivityView(activity: activity)
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(model.loadError ?? (model.entries.isEmpty && model.query.isEmpty ? "No captures yet" : "No matching captures"),
                                       systemImage: "photo.on.rectangle",
                                       description: Text("Captures and upload results appear here. Try another filter or search."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.visibleEntries) { entry in
                        historyRow(entry).tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.space) {
                    guard let entry = model.visibleEntries.first(where: { $0.id == selection }) else { return .ignored }
                    model.preview(entry)
                    return .handled
                }
            }
            Divider()
            HStack {
                Text("\(model.visibleEntries.count) captures")
                Spacer()
                Text("Select a capture and press Space to preview")
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in model.reload() }
        .sheet(item: $model.previewEntry) { entry in
            VStack(spacing: 0) {
                if let path = entry.filePath { CapturePreview(url: URL(fileURLWithPath: path)) }
                Divider()
                HStack {
                    Text(entry.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Capture").lineLimit(1)
                    Spacer()
                    Button("Done") { model.previewEntry = nil }.keyboardShortcut(.cancelAction)
                }.padding(16)
            }.frame(width: 800, height: 560)
        }
        .sheet(item: $model.uploadEntry) { entry in HistoryUploadSheet(entry: entry, model: model) }
        .sheet(item: $model.exportingEntry) { entry in GifExportSheet(entry: entry, model: model) }
        .alert("Remove from History?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let entry = removing { model.removeFromHistory(entry) }; removing = nil
            }
        } message: { Text("The local file and any remote upload will remain. The saved link and remote-deletion action will be removed from History.") }
        .alert("Delete remote upload?", isPresented: Binding(get: { deletingRemote != nil }, set: { if !$0 { deletingRemote = nil } })) {
            Button("Cancel", role: .cancel) { deletingRemote = nil }
            Button("Delete remote upload", role: .destructive) {
                if let entry = deletingRemote { Task { await model.deleteRemote(entry) } }; deletingRemote = nil
            }
        } message: { Text("This asks the server to permanently delete this upload. Your local file and history entry will remain.") }
        .alert("Couldn’t complete action", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
        .alert("Delete failed", isPresented: Binding(get: { model.deleteError != nil }, set: { if !$0 { model.deleteError = nil } })) {
            Button("OK") { model.deleteError = nil }
        } message: { Text(model.deleteError ?? "") }
        .alert("Export failed", isPresented: Binding(get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })) {
            Button("OK") { model.exportError = nil }
        } message: { Text(model.exportError ?? "") }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 16) {
            Button { model.preview(entry) } label: { Thumbnail(path: entry.filePath) }
                .buttonStyle(.plain).disabled(!model.hasLocalFile(entry)).help("Preview capture")
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? entry.url ?? "Capture")
                    .fontWeight(.medium).lineLimit(2)
                Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.isBusy(entry) ? "Working…" : entry.uploadFailed ? "Upload failed · \(entry.destinationName ?? "Unknown destination")" : entry.url != nil ? "Uploaded · \(entry.destinationName ?? "Uploader")" : "Saved locally")
                    .font(.caption).foregroundStyle(entry.uploadFailed ? Color.orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy(entry) { ProgressView().controlSize(.small) }
            else if entry.uploadFailed {
                Button("Retry…") { model.uploadEntry = entry }.disabled(!model.hasLocalFile(entry))
                    .help(model.hasLocalFile(entry) ? "Retry this upload" : "Retry requires the original local file")
            } else if let url = entry.url {
                Button("Copy link") { model.copy(url) }
            }
            Menu {
                Button("Preview") { model.preview(entry) }.disabled(!model.hasLocalFile(entry))
                if let path = entry.filePath, !MIMEType.isVideo(path: path) {
                    Button("Copy image") { model.copyImage(entry) }.disabled(!model.hasLocalFile(entry))
                }
                if let url = entry.url {
                    Button("Copy link") { model.copy(url) }
                    Button("Open link") { model.open(url) }
                }
                Button(entry.uploadFailed ? "Retry upload…" : "Upload…") { model.uploadEntry = entry }
                    .disabled(!model.hasLocalFile(entry))
                if let path = entry.filePath {
                    if MIMEType.isVideo(path: path) { Button("Export as GIF…") { model.beginGifExport(entry) } }
                    Button("Reveal in Finder") { model.reveal(path) }
                }
                Divider()
                Button("Remove from History…", role: .destructive) { removing = entry }
                if entry.deletionURL != nil {
                    Button("Delete remote upload…", role: .destructive) { deletingRemote = entry }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy(entry))
            .accessibilityLabel("Actions for capture")
        }
        .padding(.vertical, 10)
    }
}

private struct HistoryUploadSheet: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var destinationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.uploadFailed ? "Retry upload" : "Upload capture").font(.title2.bold())
            Text("Choose where to send this file. A successful upload copies its link if the clipboard hasn’t changed.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.destinations) { destination in
                        Button { destinationID = destination.id } label: {
                            Label(destination.name, systemImage: destinationID == destination.id ? "largecircle.fill.circle" : "circle")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.destinations.isEmpty { Text("Add an uploader in Settings → Uploads first.").foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Upload") {
                    guard let destination = model.destinations.first(where: { $0.id == destinationID }) else { return }
                    dismiss()
                    Task { await model.upload(entry, to: destination) }
                }
                .buttonStyle(.borderedProminent).disabled(destinationID == nil)
            }
        }
        .padding(24).frame(width: 520, height: 360)
        .onAppear { destinationID = model.preferredDestination(for: entry) }
    }
}

private struct CapturePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// fps/scale options for "Export as GIF…", pre-filled from RecordingSettings.
private struct GifExportSheet: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel
    @State private var fps: Double
    @State private var maxWidthText: String
    @State private var isExporting = false

    init(entry: HistoryEntry, model: HistoryModel) {
        self.entry = entry
        self.model = model
        _fps = State(initialValue: Double(model.defaultGifFPS))
        _maxWidthText = State(initialValue: model.defaultGifMaxWidth.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export as GIF").font(.headline)
            HStack {
                Text("Frame rate")
                Slider(value: $fps, in: 1...30, step: 1)
                Text("\(Int(fps)) fps").monospacedDigit()
            }
            HStack {
                Text("Max width (px)")
                TextField("Source width", text: $maxWidthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            HStack {
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").foregroundStyle(.secondary)
                }
                Button("Cancel") { model.exportingEntry = nil }
                    .disabled(isExporting)
                Button("Export") {
                    isExporting = true
                    // Non-numeric, zero, or negative input means "no max
                    // width" — never pass a <= 0 width down to the GIF
                    // converter's `maximumSize`.
                    let width = Int(maxWidthText).flatMap { $0 > 0 ? $0 : nil }
                    Task { await model.exportGif(for: entry, fps: Int(fps), maxWidth: width) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct Thumbnail: View {
    let path: String?
    var body: some View {
        if let path, let image = Thumbnail.downsampled(path: path, maxPixel: 192) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 64).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let path, MIMEType.isVideo(path: path) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 96, height: 64)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 96, height: 64)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    /// Decode a downsampled thumbnail directly via ImageIO, so a 4K+ screenshot
    /// is never fully decoded just to render at 96×64 (maxPixel 192 covers Retina).
    /// Videos return nil here (ImageIO can't decode a video frame) → the film
    /// fallback above; `MIMEType.isVideo` (LumeshotCore) is the single source of truth.
    static func downsampled(path: String, maxPixel: Int) -> NSImage? {
        guard !MIMEType.isVideo(path: path) else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
