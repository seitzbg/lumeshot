import AppKit
import SwiftUI
import LumeshotCore

@MainActor
final class UploadActivity: ObservableObject {
    static let shared = UploadActivity()

    struct Operation: Identifiable {
        let id: UUID
        let filename: String
        let destination: String
        let filePath: String?
        var url: String?
        var error: String?
        var linkCopied = false
    }

    @Published private(set) var running: [Operation] = []
    @Published private(set) var latest: Operation?

    var summary: String? {
        if running.count > 1 { return "Uploading \(running.count) files…" }
        if let operation = running.first { return "Uploading to \(operation.destination)…" }
        guard let latest else { return nil }
        if latest.error != nil { return "Upload failed" }
        return latest.linkCopied ? "Link copied" : "Upload complete"
    }

    func begin(filename: String, destination: String, filePath: String? = nil) -> UUID {
        let operation = Operation(id: UUID(), filename: filename, destination: destination, filePath: filePath)
        running.append(operation)
        return operation.id
    }

    func finish(_ id: UUID, url: String? = nil, error: String? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var operation = running.remove(at: index)
        operation.url = url
        operation.error = error
        latest = operation
    }

    func copied(_ url: String) {
        guard latest?.url == url else { return }
        latest?.linkCopied = true
    }

    func forgetLink(_ url: String?) {
        guard let url, latest?.url == url else { return }
        latest = nil
    }

    func copyLatestLink() {
        guard let url = latest?.url else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(url, forType: .string) { copied(url) }
    }
}

struct UploadActivityView: View {
    @ObservedObject var activity: UploadActivity

    var body: some View {
        if let summary = activity.summary {
            HStack(spacing: 12) {
                if !activity.running.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: activity.latest?.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(activity.latest?.error == nil ? Color.green : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).fontWeight(.medium)
                    Text(activity.running.first?.filename ?? activity.latest?.error ?? activity.latest?.filename ?? "")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if activity.running.isEmpty, activity.latest?.url != nil {
                    Button("Copy link") { activity.copyLatestLink() }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06))
        }
    }
}
