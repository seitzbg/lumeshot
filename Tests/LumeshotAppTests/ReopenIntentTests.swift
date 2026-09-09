import Foundation
import Testing
@testable import LumeshotApp

/// Clicking a notification activates the app, and AppKit reports that through
/// the same reopen callback as a Dock click. Settings used to open on top of the
/// Finder window or browser tab the notification had just opened.
@Suite struct ReopenIntentTests {
    private let t = Date(timeIntervalSince1970: 1_000_000)

    @Test func aReopenWithNoNotificationAtAllShowsSettings() {
        #expect(ReopenIntent.shouldRevealSettings(reopenedAt: t, lastNotificationResponse: nil))
    }

    /// The response can be delivered just before the reopen.
    @Test func aResponseJustBeforeTheReopenSuppressesSettings() {
        #expect(!ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(-0.2)))
    }

    /// ...or just after it, which is why the reveal is deferred and re-checked.
    @Test func aResponseJustAfterTheReopenSuppressesSettings() {
        #expect(!ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(0.2)))
    }

    /// A reopen well after the last notification is the user asking for Settings
    /// — dismissing a banner must not disable the Dock click that follows.
    @Test func aReopenLongAfterTheLastNotificationStillShowsSettings() {
        #expect(ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(-30)))
        #expect(ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(-0.51)))
    }

    /// The deferral has to outlast the window it depends on. Waiting less means a
    /// response arriving late in the window finds Settings already on screen, and
    /// cancelling a work item that has run does nothing — which quietly shortens
    /// the window to however long the deferral happened to be.
    @Test func theRevealOutlastsTheWindowItDependsOn() {
        #expect(ReopenIntent.revealDelay >= ReopenIntent.responseWindow)
    }

    /// A response late in the window still counts, which is the case the short
    /// deferral used to miss.
    @Test func aResponseLateInTheWindowStillSuppressesSettings() {
        #expect(!ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(0.4)))
    }

    /// The boundary belongs to the notification: exactly at the edge counts as
    /// too close to call, and the safe answer is not to hijack the click.
    @Test func theWindowEdgeIsTreatedAsANotificationActivation() {
        #expect(!ReopenIntent.shouldRevealSettings(
            reopenedAt: t, lastNotificationResponse: t.addingTimeInterval(-ReopenIntent.responseWindow)))
    }
}
