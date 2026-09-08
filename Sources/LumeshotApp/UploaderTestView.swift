import AppKit
import AVFoundation
import SwiftUI
import LumeshotCore
import LumeshotUpload

@MainActor
final class UploaderTestModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var result: UploadResult?
    @Published private(set) var deleted = false
    @Published private(set) var error: String?
    let destination: UploadDestination
    private let upload: (FilePart, UploadDestination) async throws -> UploadResult
    private let deletionService: RemoteDeletionService

    init(destination: UploadDestination, http: HTTPClient = URLSessionHTTPClient(),
         credentials: CredentialStore = KeychainCredentialStore(),
         upload: @escaping (FilePart, UploadDestination) async throws -> UploadResult) {
        self.destination = destination
        self.deletionService = RemoteDeletionService(http: http, credentials: credentials)
        self.upload = upload
    }

    static func sampleImage() throws -> FilePart {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw UploadError.unsupported("Couldn’t create a test image")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.27, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        ("Lumeshot upload test" as NSString).draw(at: NSPoint(x: 24, y: 105), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
        ("Generated image • No screen content" as NSString).draw(at: NSPoint(x: 24, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw UploadError.unsupported("Couldn’t encode a test image")
        }
        return FilePart(fieldName: "file", filename: "lumeshot-test-\(UUID().uuidString).png",
                        mimeType: "image/png", data: data)
    }

    /// A one-second 160x90 H.264 clip, written to a temporary file because
    /// AVAssetWriter only writes to disk, then read back and the file removed.
    ///
    /// Small on purpose: this is a reachability and acceptance check, not a
    /// throughput benchmark, and it lands in someone's bucket or home directory.
    static func sampleVideo() async throws -> FilePart {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumeshot-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else {
            throw UploadError.unsupported("Couldn’t create a test video")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw UploadError.unsupported("Couldn’t create a test video")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<8 {
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            // A shifting grey so successive frames differ; an all-identical clip
            // can encode to something a server treats as degenerate.
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 + frame * 20), CVPixelBufferGetBytesPerRow(buffer)
                       * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 8))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw UploadError.unsupported("Couldn’t encode a test video")
        }
        let data = try Data(contentsOf: url)
        return FilePart(fieldName: "file", filename: "lumeshot-test-\(UUID().uuidString).mp4",
                        mimeType: "video/mp4", data: data)
    }

    /// Tests what the destination will actually be asked to carry. A host that
    /// takes video is a general file transport, so a clip exercises strictly more
    /// than a PNG would — size, MIME handling, and any upload limits. An image-only
    /// host gets the image, since sending it a clip only proves it says no.
    static func sampleArtifact(for destination: UploadDestination) async throws -> FilePart {
        destination.kind.acceptsRecordings ? try await sampleVideo() : try sampleImage()
    }

    /// What this test will upload, for the sheet to say so before it runs.
    var artifactDescription: String {
        destination.kind.acceptsRecordings ? "a short test video" : "a generated test image"
    }

    func run() async {
        guard !isRunning, result == nil else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do { result = try await upload(Self.sampleArtifact(for: destination), destination) }
        catch { self.error = UploadFeedback.message(for: error) }
    }

    func deleteTestUpload() async {
        guard !isRunning, !deleted, let value = result?.deletionURL,
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            try await deletionService.delete(url.absoluteString, destination: destination)
            deleted = true
            UploadActivity.shared.forgetLink(result?.url)
        } catch { self.error = "Couldn’t delete the test upload. " + RemoteDeletionService.message(for: error) }
    }
}

struct UploaderTestSheet: View {
    @StateObject var model: UploaderTestModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Test uploader").font(.title2.bold())
                Text(model.destination.name).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Uploads \(model.artifactDescription) — no screen content.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if model.deleted {
                Label("Test succeeded and the test upload was deleted.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else if let result = model.result {
                Label("Upload succeeded", systemImage: "checkmark.circle").foregroundStyle(.green)
                if let url = URL(string: result.url) {
                    Link("Open test image", destination: url)
                    Text(result.url).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(3)
                }
                Text(result.deletionURL == nil
                     ? "This uploader doesn’t provide a deletion link. Remove the test image through your hosting service when you’re finished."
                     : "The test image remains on the server until you delete it. Copy its link if you want to keep it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.url, forType: .string)
                    }
                    if model.result?.deletionURL != nil {
                        Button("Delete test upload…", role: .destructive) { confirmingDeletion = true }
                    }
                }.disabled(model.isRunning)
            } else {
                Label("Uploads a generated test image", systemImage: "arrow.up.doc")
                    .font(.headline)
                Text("A small PNG will be sent to this destination using its saved settings. It contains no screen content. This creates a real remote file and may produce a public link.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if model.isRunning { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isRunning)
                if model.result == nil {
                    Button(model.error == nil ? "Upload test image" : "Try again") { Task { await model.run() } }
                        .buttonStyle(.borderedProminent).disabled(model.isRunning)
                }
            }
        }
        .padding(24).frame(width: 540, height: model.result == nil && model.error == nil ? 300 : 420)
        .interactiveDismissDisabled(model.isRunning)
        .alert("Delete test upload?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await model.deleteTestUpload() } }
        } message: { Text("This permanently deletes the generated test image from the server.") }
    }
}
