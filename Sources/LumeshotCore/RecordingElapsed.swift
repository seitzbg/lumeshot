import Foundation

/// The menu-bar recording timer's text.
///
/// Both readings are derived from the recording's start time rather than from a
/// counter the ticker owns. That is the whole point: the menu is rebuilt
/// whenever anything in it changes (toggling System Audio, for one), and a
/// rebuild that re-rendered a counter would snap a running timer back to 0:00
/// — the regression `docs/smoke-m5b.md` P1 was written for. Passing `now`
/// explicitly is what makes that testable without waiting out a real minute.
public enum RecordingElapsed {
    /// "m:ss" since `start`. Clamped at zero so a clock that steps backwards
    /// mid-recording renders 0:00 instead of "0:-1".
    public static func label(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Title for the disabled elapsed menu item. `start` is nil only when no
    /// recording is in progress.
    public static func menuTitle(start: Date?, now: Date = Date()) -> String {
        "● \(start.map { label(since: $0, now: now) } ?? "0:00")"
    }
}
