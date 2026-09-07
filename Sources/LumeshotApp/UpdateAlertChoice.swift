import AppKit

/// What the user picked from the "an update is available" alert.
///
/// `NSAlert` numbers buttons in the order they were added, so offering **Download**
/// shifts every button after it — `.alertFirstButtonReturn` means Download when it is
/// present and View Release when it is not. That arithmetic was inline and is exactly
/// the kind of off-by-one that fails silently: the wrong branch runs, nothing visibly
/// breaks, and the button simply appears dead.
enum UpdateAlertChoice: Equatable {
    case download
    case viewRelease
    case dismiss

    init(response: NSApplication.ModalResponse, canDownload: Bool) {
        if canDownload {
            switch response {
            case .alertFirstButtonReturn:  self = .download
            case .alertSecondButtonReturn: self = .viewRelease
            default:                       self = .dismiss
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:  self = .viewRelease
            default:                       self = .dismiss
            }
        }
    }
}
