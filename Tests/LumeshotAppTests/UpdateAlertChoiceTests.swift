import Testing
import AppKit
@testable import LumeshotApp

/// Pins the button-index mapping. Offering Download shifts every later button by one,
/// and getting it wrong is invisible: the alert looks right and the button does nothing.
@Suite struct UpdateAlertChoiceTests {
    @Test func withDownloadOfferedTheButtonsAreDownloadViewLater() {
        #expect(UpdateAlertChoice(response: .alertFirstButtonReturn, canDownload: true) == .download)
        #expect(UpdateAlertChoice(response: .alertSecondButtonReturn, canDownload: true) == .viewRelease)
        #expect(UpdateAlertChoice(response: .alertThirdButtonReturn, canDownload: true) == .dismiss)
    }

    /// Without a downloadable asset the alert has only View Release and Later, so the
    /// first button means something different.
    @Test func withoutDownloadTheFirstButtonIsViewRelease() {
        #expect(UpdateAlertChoice(response: .alertFirstButtonReturn, canDownload: false) == .viewRelease)
        #expect(UpdateAlertChoice(response: .alertSecondButtonReturn, canDownload: false) == .dismiss)
    }

    /// The same raw response must mean different things depending on the layout — the
    /// property that makes the inline arithmetic worth extracting at all.
    @Test func theFirstButtonMeansDifferentThingsInTheTwoLayouts() {
        #expect(UpdateAlertChoice(response: .alertFirstButtonReturn, canDownload: true)
                != UpdateAlertChoice(response: .alertFirstButtonReturn, canDownload: false))
    }

    @Test func anUnexpectedResponseDismissesRatherThanActing() {
        for response in [NSApplication.ModalResponse.cancel, .abort, .stop, .continue] {
            #expect(UpdateAlertChoice(response: response, canDownload: true) == .dismiss)
            #expect(UpdateAlertChoice(response: response, canDownload: false) == .dismiss)
        }
    }
}
