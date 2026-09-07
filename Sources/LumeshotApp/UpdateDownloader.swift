import AppKit
import Foundation
import LumeshotCore

/// Fetches a published update's dmg into ~/Downloads and reveals it in Finder.
///
/// It deliberately stops there rather than installing. Replacing the running app
/// is a privileged code path, and getting its signature checking subtly wrong turns
/// the update channel into a way to run arbitrary code — which is why Sparkle
/// exists and why this does not try to reimplement it.
///
/// Two things make the downloaded file trustworthy, and only one of them is the
/// checksum:
///
/// - The `SHA256SUMS.txt` published with the release proves the download arrived
///   intact. It proves nothing about authenticity: anyone able to replace the dmg
///   could replace the sums file beside it.
/// - The **quarantine attribute** set below is what makes macOS run its full
///   Gatekeeper assessment on first open, checking the Developer ID signature and
///   the notarization ticket. That is the real guarantee. A browser sets this on
///   anything it downloads; a file fetched by URLSession does not get it
///   automatically, and without it the user would open a dmg that was never
///   properly assessed.
@MainActor
final class UpdateDownloader {
    enum Failure: LocalizedError {
        case httpStatus(Int)
        case checksumsUnavailable
        case checksumMissingForFile(String)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "The download failed (HTTP \(code))."
            case .checksumsUnavailable:
                return "This release did not publish a checksum file, so the download could not be verified."
            case .checksumMissingForFile(let name):
                return "The checksum file does not list \(name), so the download could not be verified."
            case .checksumMismatch:
                return "The downloaded file did not match its published checksum and was discarded."
            }
        }
    }

    /// Downloads, verifies, quarantines and returns the saved file's location.
    func download(_ update: UpdateDownload) async throws -> URL {
        guard let checksumsURL = update.checksumsURL else { throw Failure.checksumsUnavailable }
        let sums = try await fetch(checksumsURL)
        guard let expected = ReleaseChecksums.expectedSHA256(for: update.dmgName, in: sums) else {
            throw Failure.checksumMissingForFile(update.dmgName)
        }
        let dmg = try await fetch(update.dmgURL)
        // Verify before anything touches the filesystem, so a corrupted download is
        // never written somewhere the user might open it.
        guard ReleaseChecksums.matches(dmg, expected: expected) else { throw Failure.checksumMismatch }

        let destination = uniqueDestination(for: update.dmgName)
        try dmg.write(to: destination, options: .atomic)
        try? applyQuarantine(to: destination)
        return destination
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Lumeshot", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.httpStatus(http.statusCode)
        }
        return data
    }

    /// ~/Downloads/Lumeshot-1.2.3.dmg, or …-1.dmg, …-2.dmg if that name is taken —
    /// never overwrite a file the user already has.
    private func uniqueDestination(for filename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Marks the file as downloaded from the internet so Gatekeeper assesses it on
    /// first open, the way it would for a browser download. Without this the dmg
    /// opens with no notarization check at all.
    private func applyQuarantine(to url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Lumeshot",
        ]
        try url.setResourceValues(values)
    }
}
