import AppKit
import SXCore
import UserNotifications

@MainActor
final class AppPipelineEffects: NSObject, PipelineEffects, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter requires a real bundle; bare `swift run` has none.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func setUpNotifications() {
        guard notificationsAvailable else {
            NSLog("Notifications unavailable (not running from a bundle)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notification auth error: \(error)") }
            else { NSLog("Notification auth granted: \(granted)") }
        }
    }

    // MARK: PipelineEffects

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func copyImageToClipboard(_ pngData: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setData(pngData, forType: .png) {
            NSLog("Pasteboard write failed")
        }
    }

    func notify(title: String, body: String, fileURL: URL?) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL { content.userInfo = ["path": fileURL.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Notification error: \(error)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let path = userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])   // show banners while app is frontmost too
    }
}
