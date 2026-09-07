import AppKit
import LumeshotCore

/// "Check for Updates…": asks GitHub whether a newer release exists and reports the
/// answer in an alert.
///
/// It can download an update and reveal it in Finder, but it does not install one.
/// Replacing the running app is a privileged code path — see `UpdateDownloader` for
/// why that is left to Sparkle rather than reimplemented here.
///
/// The decision itself lives in `UpdateCheck` as a pure function, so it is tested
/// without a network; this type only performs the request and presents the result.
@MainActor
final class UpdateCheckController {
    // One flag per network operation, and each is cleared BEFORE any alert is shown.
    // A single shared flag deadlocked the feature: runModal() blocks inside the check's
    // Task, so the flag was still set when the Download button ran, and startDownload's
    // own guard rejected it — silently, with no download and no error.
    private var checkInFlight = false
    private var downloadInFlight = false
    private let downloader = UpdateDownloader()

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    /// Set only by the release workflow (see `scripts/bundle.sh`). The version string
    /// alone cannot tell us this: a local bundle defaults to 0.1.0, which reads as a
    /// valid older release.
    private var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "LumeshotReleaseChannel") as? String == "release"
    }

    func checkForUpdates() {
        guard !checkInFlight else { return }   // double-click on the menu item
        checkInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.fetchLatestRelease()
            // Cleared before presenting, not in a defer: the alert below blocks until
            // the user clicks, and the flag describes the request, not the dialog.
            self.checkInFlight = false
            switch outcome {
            case .payload(let data):
                do {
                    self.present(try UpdateCheck.result(currentVersion: self.currentVersion,
                                                        isReleaseBuild: self.isReleaseBuild,
                                                        latestReleaseJSON: data))
                } catch {
                    self.presentFailure(error: error)
                }
            case .httpStatus(let code):
                self.presentFailure(status: code)
            case .failed(let error):
                self.presentFailure(error: error)
            }
        }
    }

    private enum FetchOutcome {
        case payload(Data)
        case httpStatus(Int)
        case failed(Error)
    }

    private static func fetchLatestRelease() async -> FetchOutcome {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI)
        // GitHub asks for an explicit API version and rejects requests with no User-Agent.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lumeshot", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .httpStatus(http.statusCode)   // 403/429 is rate limiting
            }
            return .payload(data)
        } catch {
            return .failed(error)
        }
    }

    private func present(_ result: UpdateCheckResult) {
        let alert = NSAlert()
        switch result {
        case .updateAvailable(let latest, let page, let download):
            alert.messageText = "Lumeshot \(latest) is available"
            alert.informativeText = "You are running \(currentVersion)."
            // Download is the default only when there is something to download and a
            // checksum to check it against; otherwise the release page is all we can
            // honestly offer.
            let canDownload = download?.checksumsURL != nil
            if canDownload { alert.addButton(withTitle: "Download") }
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            switch UpdateAlertChoice(response: alert.runModal(), canDownload: canDownload) {
            case .download:      if let download { startDownload(download) }
            case .viewRelease:   NSWorkspace.shared.open(page)
            case .dismiss:       break
            }
            return
        case .upToDate(let current):
            alert.messageText = "Lumeshot is up to date"
            alert.informativeText = "You are running \(current)."
        case .notAReleaseBuild:
            alert.messageText = "This is not a published build"
            alert.informativeText = """
            Update checks compare published releases. This copy was built locally, so \
            there is nothing meaningful to compare it against.
            """
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func startDownload(_ update: UpdateDownload) {
        guard !downloadInFlight else { return }
        downloadInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.downloader.download(update)
                self.downloadInFlight = false   // cleared before the alert blocks
                let done = NSAlert()
                done.messageText = "Downloaded \(file.lastPathComponent)"
                done.informativeText = """
                Saved to your Downloads folder and checked against the published \
                checksum. Open it and drag Lumeshot to Applications, replacing the \
                current copy. Quit Lumeshot first.
                """
                done.addButton(withTitle: "Show in Finder")
                done.addButton(withTitle: "Done")
                NSApp.activate()
                if done.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } catch {
                self.downloadInFlight = false
                self.presentFailure(title: "Could not download the update", error: error)
            }
        }
    }

    private func presentFailure(title: String = "Could not check for updates",
                                status: Int? = nil, error: Error? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        if let status, status == 403 || status == 429 {
            alert.informativeText = "GitHub is rate-limiting requests. Try again later."
        } else if let status {
            alert.informativeText = "GitHub returned HTTP \(status)."
        } else {
            alert.informativeText = error?.localizedDescription ?? "The request failed."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
