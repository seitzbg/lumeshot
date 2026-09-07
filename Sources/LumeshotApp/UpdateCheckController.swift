import AppKit
import LumeshotCore

/// "Check for Updates…": asks GitHub whether a newer release exists and reports the
/// answer in an alert.
///
/// This deliberately does not download or install anything. A real auto-updater
/// (Sparkle) needs an EdDSA key pair, a hosted appcast and update-signing in the
/// release workflow; until that exists, telling the user a release is out beats the
/// current situation, which is no signal at all.
///
/// The decision itself lives in `UpdateCheck` as a pure function, so it is tested
/// without a network; this type only performs the request and presents the result.
@MainActor
final class UpdateCheckController {
    private var inFlight = false

    /// The running build's version, or a placeholder that `UpdateCheck` treats as
    /// "not comparable" so a dev build is never told it is out of date.
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    func checkForUpdates() {
        guard !inFlight else { return }   // double-click on the menu item
        inFlight = true
        Task { [weak self] in
            defer { self?.inFlight = false }
            do {
                var request = URLRequest(url: UpdateCheck.latestReleaseAPI)
                // GitHub asks for an explicit API version and rejects requests with no
                // User-Agent.
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("Lumeshot", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // Rate limiting (403/429) is the common one and deserves its own words.
                    self?.presentFailure(status: http.statusCode)
                    return
                }
                let result = try UpdateCheck.result(currentVersion: self?.currentVersion ?? "",
                                                    latestReleaseJSON: data)
                self?.present(result)
            } catch {
                self?.presentFailure(error: error)
            }
        }
    }

    private func present(_ result: UpdateCheckResult) {
        let alert = NSAlert()
        switch result {
        case .updateAvailable(let latest, let page):
            alert.messageText = "Lumeshot \(latest) is available"
            alert.informativeText = "You are running \(currentVersion)."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            return
        case .upToDate(let current):
            alert.messageText = "Lumeshot is up to date"
            alert.informativeText = "You are running \(current)."
        case .unknownCurrentVersion:
            alert.messageText = "This build has no release version"
            alert.informativeText = """
            Local builds are not stamped with a version, so there is nothing to compare \
            against a published release.
            """
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func presentFailure(status: Int? = nil, error: Error? = nil) {
        let alert = NSAlert()
        alert.messageText = "Could not check for updates"
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
