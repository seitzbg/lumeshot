import AppKit
import LumeshotCore
import UserNotifications

@MainActor
final class AppPipelineEffects: NSObject, PipelineEffects, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter requires a real bundle; bare `swift run` has none.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func setUpNotifications() {
        guard notificationsAvailable else {
            AppLog.log("Notifications unavailable (not running from a bundle)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Report the *decision*, not just that we asked. On a machine where the
        // unified log is unreadable (non-admin ssh), the file log is the only
        // channel, and "did the user allow notifications" is the first thing a
        // "nothing appeared" report needs answered.
        center.getNotificationSettings { @Sendable settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "notDetermined (prompt pending or never shown)"
            case .denied:        status = "denied"
            case .authorized:    status = "authorized"
            case .provisional:   status = "provisional"
            case .ephemeral:     status = "ephemeral"
            @unknown default:    status = "unknown(\(settings.authorizationStatus.rawValue))"
            }
            AppLog.log("Notification Center: authorization=\(status) "
                       + "alerts=\(settings.alertSetting.rawValue) "
                       + "banners=\(settings.alertStyle.rawValue)")
        }
        // @Sendable is load-bearing, not decoration. This type is @MainActor, so a
        // bare closure here inherits main-actor isolation — but UserNotifications
        // invokes it on its own queue (UNUserNotificationServiceConnection.call-out).
        // The Swift runtime then checks the executor on entry and traps with
        // EXC_BREAKPOINT before the body runs. macOS 15's runtime tolerated it;
        // macOS 26's does not, so the app died on launch there.
        // The closure captures nothing and NSLog is thread-safe, so making it
        // non-isolated is sufficient and needs no hop.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error { AppLog.log("Notification auth error: \(error)") }
            else { AppLog.log("Notification auth granted: \(granted)") }
        }
    }

    // MARK: PipelineEffects

    var clipboardChangeCount: Int { NSPasteboard.general.changeCount }

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
        // Same isolation trap as setUpNotifications(): add(_:) calls back off the
        // main actor. This one would fire on the first notification posted rather
        // than at launch.
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error { AppLog.log("Notification post failed: \(error)") }
            else { AppLog.log("Notification posted: \(title)") }
        }
    }

    func copyTextToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setString(text, forType: .string) {
            AppLog.log("Pasteboard text write failed")
        }
    }

    func notifyURL(title: String, body: String, url: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["url": url]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        // @Sendable for the same reason as setUpNotifications() — see there.
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error { AppLog.log("Notification post failed: \(error)") }
            else { AppLog.log("Notification posted: \(title)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            completionHandler()
            return
        }
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
