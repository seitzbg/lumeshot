import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About Lumeshot"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 420, height: 270))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OpenSourceCredit: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let url: URL
    let license: String
    let notice: String

    static func load() throws -> [Self] {
        // Release bundles copy the resource directly; SwiftPM uses its resource bundle.
        let url = Bundle.main.url(forResource: "OpenSourceCredits", withExtension: "json")
            ?? Bundle.module.url(forResource: "OpenSourceCredits", withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }
}

private struct AboutView: View {
    private let project = URL(string: "https://github.com/seitzbg/lumeshot")!
    @State private var showingCredits = false

    private var version: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development build"
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != version { return "Version \(version) (\(build))" }
        return "Version \(version)"
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lumeshot").font(.system(size: 26, weight: .bold))
                    Text(version).font(.caption).foregroundStyle(.secondary)
                    Text("Capture. Annotate. Share.").font(.callout)
                }
            }
            Divider()
            HStack(spacing: 20) {
                Link("GitHub", destination: project)
                Link("Releases", destination: project.appendingPathComponent("releases"))
                Link("Report an issue", destination: project.appendingPathComponent("issues"))
            }
            Button("Open source credits…") { showingCredits = true }
            Link("Licensed under GPL-3.0", destination: project.appendingPathComponent("blob/main/LICENSE"))
                .font(.caption)
        }
        .padding(24)
        // Bound the hosting view too: its intrinsic size must not grow with the credits.
        .frame(width: 420, height: 270)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingCredits) {
            OpenSourceCreditsView()
        }
    }
}

private struct OpenSourceCreditsView: View {
    @Environment(\.dismiss) private var dismiss
    private let credits = Result { try OpenSourceCredit.load() }
    @State private var selectedCredit: OpenSourceCredit?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedCredit?.name ?? "Open source credits").font(.title2.bold())
                Text(selectedCredit?.license ?? "With thanks to these projects and their contributors.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            ScrollView {
                Group {
                    if let credit = selectedCredit {
                        Text(credit.notice).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        creditList
                    }
                }
                // Keep the scrollbar outside the rows and text, with breathing room.
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            HStack(spacing: 16) {
                if let credit = selectedCredit {
                    Button("Back to credits") { selectedCredit = nil }
                    Link("Project website", destination: credit.url)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 620, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var creditList: some View {
        switch credits {
        case .success(let entries):
            VStack(spacing: 0) {
                ForEach(entries) { credit in
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Link(credit.name, destination: credit.url)
                                .fontWeight(.medium)
                            Text("\(credit.version) · \(credit.license)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("View license") { selectedCredit = credit }
                            .fixedSize()
                            .accessibilityLabel("Read \(credit.name) license")
                    }
                    .padding(.vertical, 14)
                    if credit.id != entries.last?.id { Divider() }
                }
            }
        case .failure:
            VStack(alignment: .leading, spacing: 12) {
                Text("Acknowledgments couldn’t be loaded. Visit GitHub for the project’s dependencies.")
                    .foregroundStyle(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/seitzbg/lumeshot")!)
            }
            .padding(.vertical)
        }
    }
}
