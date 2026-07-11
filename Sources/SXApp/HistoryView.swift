import AppKit
import SwiftUI
import SXCore
import SXUpload

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var query: String = "" { didSet { reload() } }
    private let store: HistoryStore
    private let http: HTTPClient

    init(store: HistoryStore, http: HTTPClient = URLSessionHTTPClient()) {
        self.store = store
        self.http = http
        reload()
    }

    func reload() {
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.all(limit: 500)
                : try store.search(matching: query, limit: 500)
        } catch {
            AppLog.log("History: load failed: \(error)")
            entries = []
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
                Text("No captures yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    HistoryRow(entry: entry, model: model)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
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
                Button { model.reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            Button(role: .destructive) { model.delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 2)
    }
}

private struct Thumbnail: View {
    let path: String?
    var body: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 36).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
