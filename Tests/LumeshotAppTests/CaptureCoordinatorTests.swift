import AppKit
import ImageIO
import LumeshotCore
import Testing
@testable import LumeshotApp

struct UnusedCredentials: CredentialStore {
    func secret(for account: String) throws -> String? { nil }
    func setSecret(_ value: String, for account: String) throws {}
    func deleteSecret(for account: String) throws {}
}

@MainActor
private final class ImmediateEditor: EditorPresenting {
    let action: EditorAction
    init(action: EditorAction) { self.action = action }

    func present(image: CGImage, completion: @escaping @MainActor (EditorResult?) -> Void) {
        completion(EditorResult(action: action, image: image))
    }
}

@Suite @MainActor struct CaptureCoordinatorTests {
    // Region/window callers omit the outcome callback; fullscreen supplies one.
    // Exercise the actual coordinator and inspect the resulting PNG on disk.
    @Test(arguments: ["passthrough", "save", "upload"], [false, true])
    func persistsWithOrWithoutOutcomeCallback(route: String, observesOutcome: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.captureSavePath = directory.appendingPathComponent("captures").path
        settings.filenameTemplate = "capture"
        settings.showNotification = false
        settings.upload = .disabled
        settings.editor.annotateBeforeShare = route != "passthrough"
        // Explicit editor Save must also override disabled automatic saving.
        settings.saveToDisk = route != "save"
        try store.save(settings)

        let presenter: ImmediateEditor? = route == "passthrough"
            ? nil : ImmediateEditor(action: route == "save" ? .save : .upload)
        let coordinator = CaptureCoordinator(settingsStore: store, effects: CaptureTestEffects(),
            uploadService: UploadService(credentials: UnusedCredentials()), historyStore: nil,
            editorPresenter: presenter)
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = try #require(context.makeImage()?.cropping(to: CGRect(x: 2, y: 2, width: 8, height: 6)))

        var outcomes: [Bool] = []
        if observesOutcome {
            coordinator.deliver(image: image, appName: nil) { outcomes.append($0) }
        } else {
            coordinator.deliver(image: image, appName: nil)
        }
        #expect(outcomes == (observesOutcome ? [true] : []))
        let output = directory.appendingPathComponent("captures/capture.png")
        let data = try Data(contentsOf: output)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 8)
        #expect(decoded.height == 6)
        let files = try FileManager.default.contentsOfDirectory(
            at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }
}
