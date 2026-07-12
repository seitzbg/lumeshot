import AppKit
import ImageIO
import SwiftUI
import SXCore
import SXRecord
import SXUpload

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var query: String = "" { didSet { reload() } }
    @Published var loadError: String?
    @Published var exportingEntry: HistoryEntry?
    @Published var exportError: String?
    private let store: HistoryStore
    private let http: HTTPClient
    private let recordingSettings: RecordingSettings

    init(store: HistoryStore, http: HTTPClient = URLSessionHTTPClient(),
        recordingSettings: RecordingSettings = .default) {
        self.store = store
        self.http = http
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
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func delete(_ entry: HistoryEntry) {
        do { try store.delete(id: entry.id) }
        catch { AppLog.log("History: delete failed for \(entry.id): \(error)") }
        // Best-effort remote deletion; local removal already succeeded.
        if let del = entry.deletionURL, let url = URL(string: del) {
            let http = self.http
            Task {
                do { _ = try await http.send(PreparedRequest(method: .get, url: url.absoluteString)) }
                catch { AppLog.log("History: remote deletion failed for \(entry.id): \(error)") }
            }
        }
        reload()
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

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search captures", text: $model.query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(8)
            Divider()
            if model.entries.isEmpty {
                Spacer()
                Text(model.loadError ?? "No captures yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    HistoryRow(entry: entry, model: model)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .sheet(item: $model.exportingEntry) { entry in
            GifExportSheet(entry: entry, model: model)
        }
        .alert("Export Failed", isPresented: .constant(model.exportError != nil), presenting: model.exportError) { _ in
            Button("OK") { model.exportError = nil }
        } message: { message in
            Text(message)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(path: entry.filePath)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url ?? entry.filePath.map { ($0 as NSString).lastPathComponent }
                     ?? "Capture")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    if let dest = entry.destinationName { Text("· \(dest)") }
                    if entry.uploadFailed { Text("· upload failed").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = entry.url {
                Button { model.copy(url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy URL")
                Button { model.open(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open URL")
            }
            if let path = entry.filePath {
                if MIMEType.isVideo(path: path) {
                    Button { model.beginGifExport(entry) } label: { Image(systemName: "film.stack") }
                        .buttonStyle(.borderless).help("Export as GIF…")
                }
                Button { model.reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            Button(role: .destructive) { model.delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 2)
    }
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
                Button("Cancel") { model.exportingEntry = nil }
                    .disabled(isExporting)
                Button("Export") {
                    isExporting = true
                    let width = Int(maxWidthText)
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
        if let path, let image = Thumbnail.downsampled(path: path, maxPixel: 96) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 36).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let path, MIMEType.isVideo(path: path) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    /// Decode a downsampled thumbnail directly via ImageIO, so a 4K+ screenshot
    /// is never fully decoded just to render at 48×36 (maxPixel 96 covers Retina).
    /// Videos return nil here (ImageIO can't decode a video frame) → the film
    /// fallback above; `MIMEType.isVideo` (SXCore) is the single source of truth.
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
