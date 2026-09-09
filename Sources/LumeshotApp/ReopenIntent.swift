import Foundation

/// Whether an app reopen means "show me Settings".
///
/// Clicking a notification activates the app, and AppKit reports that activation
/// through `applicationShouldHandleReopen` exactly as it reports a Dock click or
/// a double-click in Finder — there is no flag telling them apart. A menu-bar app
/// has no visible windows either way, so the handler that opens Settings for a
/// Dock click also fired for every notification click, putting Settings on top of
/// the Finder window or browser tab the notification had just opened.
///
/// The one signal available is that a notification click is accompanied by a
/// delivered notification response. It can arrive just before or just after the
/// reopen, so proximity in either direction counts.
enum ReopenIntent {
    /// Long enough to cover the gap between the activation and the response,
    /// short enough that a genuine reopen moments after dismissing a
    /// notification still opens Settings.
    static let responseWindow: TimeInterval = 0.5

    static func shouldRevealSettings(reopenedAt: Date,
                                     lastNotificationResponse: Date?,
                                     window: TimeInterval = responseWindow) -> Bool {
        guard let lastNotificationResponse else { return true }
        return abs(reopenedAt.timeIntervalSince(lastNotificationResponse)) > window
    }
}
