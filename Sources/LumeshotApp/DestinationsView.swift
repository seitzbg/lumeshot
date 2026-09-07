import SwiftUI
import LumeshotCore

@MainActor
final class DestinationsModel: ObservableObject {
    @Published var settings: UploadSettings
    @Published var removeError: String?
    @Published var saveError: String?
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
        self.settings = store.loadOrDefault().0.upload
    }

    /// Reload full settings, mutate `.upload`, persist, and refresh the menu.
    @discardableResult
    private func persist(_ mutate: (inout AppSettings) -> Void) -> Bool {
        var (all, _) = store.loadOrDefault()
        mutate(&all)
        do {
            try store.save(all)
            settings = all.upload
            onChange()
            return true
        } catch {
            AppLog.log("Destinations: save failed: \(error)")
            return false
        }
    }

    /// Re-read settings from disk (e.g. after a .sxcu import happened elsewhere).
    func reloadFromDisk() {
        settings = store.loadOrDefault().0.upload
    }

    func testModel(for destination: UploadDestination) -> UploaderTestModel {
        let service = UploadService(credentials: credentials, settingsStore: store, activity: .shared)
        return UploaderTestModel(destination: destination, credentials: credentials) { part, destination in
            try await service.upload(part: part, destination: destination)
        }
    }

    /// Persisted binding for the Uploads tab's "Upload after capture" toggle
    /// — goes through the same persist() as every other Destinations edit.
    func setUploadAfterCapture(_ newValue: Bool) {
        persist { $0.upload = $0.upload.settingUploadAfterCapture(newValue) }
    }

    func setActive(_ id: String?) {
        persist { $0.upload = $0.upload.settingActive(id: id) }
    }

    /// `nil` sends recordings wherever screenshots go.
    func setActiveRecording(_ id: String?) {
        persist { $0.upload = $0.upload.settingActiveRecording(id: id) }
    }

    /// Removes a destination and its Keychain secrets.
    ///
    /// The two stores cannot be written atomically. Purging first and saving
    /// second could strand a still-visible destination whose credentials were
    /// already destroyed; saving first could orphan secrets. So: read the
    /// secrets out as we delete them, and if the settings write then fails, put
    /// them back. A purge attempts every account rather than stopping at the
    /// first error.
    func remove(_ destination: UploadDestination) {
        let (saved, purgeError) = CredentialTransaction.purgeRestorable(
            destination.secretAccounts, in: credentials)
        if let purgeError {
            AppLog.log("Destinations: secret purge failed for \(destination.id): "
                       + "\(purgeError.failedAccounts)")
            removeError = "Some stored secrets for “\(destination.name)” could not be removed "
                + "from the Keychain. The destination was kept — try again, or remove the "
                + "entries manually in Keychain Access."
            CredentialTransaction.restore(saved, into: credentials)
            return
        }
        if !persist({ $0.upload = $0.upload.removing(id: destination.id) }) {
            // Settings write failed — the destination is still there, so put its
            // credentials back rather than leaving it permanently broken.
            if let restoreError = CredentialTransaction.restore(saved, into: credentials) {
                AppLog.log("Destinations: credential restore failed for \(destination.id): "
                           + "\(restoreError.failedAccounts)")
            }
            removeError = "Couldn’t save the change, so “\(destination.name)” was kept."
        }
    }

    // MARK: - Add / edit

    /// Shared add-or-update path for every kind.
    ///
    /// `storeSecrets` runs first; on an edit that left the secret fields blank
    /// it is a no-op, so the Keychain entry is kept rather than re-entered. If
    /// the settings write then fails, compensate: a new destination's secrets
    /// are purged, an edited destination's are restored from the snapshot taken
    /// before we overwrote them. The first destination becomes active; later
    /// additions and edits preserve the selection.
    private func save(_ dest: UploadDestination, isNew: Bool,
                      storeSecrets: () throws -> Void) {
        var previous: [String: String] = [:]
        if !isNew {
            for account in dest.secretAccounts {
                if let value = try? credentials.secret(for: account) { previous[account] = value }
            }
        }
        do {
            try storeSecrets()
        } catch {
            AppLog.log("Destinations: storing credentials for \(dest.id) failed: \(error)")
            saveError = "Couldn’t store the credentials in the Keychain."
            return
        }
        let ok = persist { all in
            all.upload = all.upload.addingOrUpdating(dest)
        }
        if !ok {
            if isNew {
                _ = CredentialTransaction.purgeRestorable(dest.secretAccounts, in: credentials)
            } else {
                CredentialTransaction.restore(previous, into: credentials)
            }
            saveError = "Couldn’t save settings, so the change was not applied."
        }
    }

    /// Existing destination when editing, else nil. Used by every `save*` to
    /// decide whether to mint an id and whether blank secrets mean "keep".
    private func resolve(_ id: String?) -> (id: String, isNew: Bool) {
        id.map { ($0, false) } ?? (UUID().uuidString, true)
    }

    func saveImgur(id: String?, name: String, clientID: String) {
        let (id, isNew) = resolve(id)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "Imgur" : name,
                                     kind: .imgur, imgurClientID: clientID)
        save(dest, isNew: isNew) {}
    }

    func saveS3(id: String?, name: String, region: String, endpoint: String, bucket: String,
                prefix: String, accessKeyID: String, secretAccessKey: String, pathStyle: Bool,
                acl: String, customDomain: String) {
        let (id, isNew) = resolve(id)
        let config = S3Config(region: region, endpoint: endpoint, bucket: bucket,
                              objectPrefix: prefix,
                              addressingStyle: pathStyle ? .path : .virtualHost,
                              acl: acl.isEmpty ? nil : acl,
                              customDomain: customDomain.isEmpty ? nil : customDomain)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "S3" : name,
                                     kind: .s3, s3Config: config)
        save(dest, isNew: isNew) {
            // The sheet enforces both-or-neither, so a blank pair means "keep".
            if !accessKeyID.isEmpty || !secretAccessKey.isEmpty {
                try S3Credentials.store(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                        id: id, into: credentials)
            }
        }
    }

    func saveSFTP(id: String?, name: String, host: String, port: Int, username: String,
                  remoteDirectory: String, publicURLBase: String,
                  password: String, privateKeyPEM: String, passphrase: String) {
        let (id, isNew) = resolve(id)
        // Preserve a pinned host key across edits; a host change clears it so
        // the new server is trusted on first use rather than compared against
        // the old one's fingerprint.
        let existing = settings.destinations.first { $0.id == id }?.sftpConfig
        let knownHostKey = (existing?.host == host) ? existing?.knownHostKey : nil
        let config = SFTPConfig(host: host, port: port, username: username,
                                remoteDirectory: remoteDirectory, publicURLBase: publicURLBase,
                                knownHostKey: knownHostKey)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "SFTP" : name,
                                     kind: .sftp, sftpConfig: config)
        save(dest, isNew: isNew) {
            // Any secret entered replaces the whole set, so a stale key can't
            // linger next to a new password.
            if !password.isEmpty || !privateKeyPEM.isEmpty || !passphrase.isEmpty {
                if !isNew { try SFTPCredentials.purge(id: id, from: credentials) }
                try SFTPCredentials.store(password: password.isEmpty ? nil : password,
                                          privateKeyPEM: privateKeyPEM.isEmpty ? nil : privateKeyPEM,
                                          passphrase: passphrase.isEmpty ? nil : passphrase,
                                          id: id, into: credentials)
            }
        }
    }

    func saveFTP(id: String?, name: String, host: String, port: Int, username: String,
                 remoteDirectory: String, publicURLBase: String, password: String, useTLS: Bool) {
        let (id, isNew) = resolve(id)
        let config = FTPConfig(host: host, port: port, username: username,
                               remoteDirectory: remoteDirectory, publicURLBase: publicURLBase,
                               useTLS: useTLS)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "FTP" : name,
                                     kind: .ftp, ftpConfig: config)
        save(dest, isNew: isNew) {
            if !password.isEmpty { try FTPCredentials.store(password: password, id: id, into: credentials) }
        }
    }

    func savePicsur(id: String?, name: String, host: String, apiKey: String,
                    imageFormat: String, linkStyle: PicsurLinkStyle) {
        let (id, isNew) = resolve(id)
        let config = PicsurConfig(host: host, imageFormat: imageFormat, linkStyle: linkStyle)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "Picsur" : name,
                                     kind: .picsur, picsurConfig: config)
        save(dest, isNew: isNew) {
            if !apiKey.isEmpty { try PicsurCredentials.store(apiKey: apiKey, id: id, into: credentials) }
        }
    }

    /// Imported `.sxcu` destinations have no form; the only editable thing is
    /// the display name. The config itself is what the file said.
    func renameCustom(_ dest: UploadDestination, to name: String) {
        var updated = dest
        updated.name = name.isEmpty ? dest.name : name
        save(updated, isNew: false) {}
    }

    func kindLabel(_ kind: UploadDestinationKind) -> String {
        switch kind {
        case .customUploader: return "Custom (.sxcu)"
        case .imgur: return "Imgur"
        case .picsur: return "Picsur"
        case .s3: return "S3"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        }
    }
}

// MARK: - View

struct DestinationsView: View {
    @ObservedObject var model: DestinationsModel
    @State private var adding: UploadDestinationKind?
    @State private var editing: UploadDestination?
    @State private var choosingUploader = false
    @State private var testing: UploadDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Uploaders").font(.headline)
                Spacer()
                Button { choosingUploader = true } label: {
                    Label("Add uploader", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .popover(isPresented: $choosingUploader, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add an uploader").font(.headline).padding(.bottom, 6)
                        uploaderOption(.picsur, title: "Picsur", detail: "Your self-hosted image library", symbol: "photo.on.rectangle")
                        uploaderOption(.imgur, title: "Imgur", detail: "Share images with a public link", symbol: "photo")
                        Divider().padding(.vertical, 4)
                        uploaderOption(.s3, title: "S3-compatible storage", detail: "Amazon S3, Cloudflare R2, MinIO, and Backblaze B2", symbol: "externaldrive.badge.icloud")
                        uploaderOption(.sftp, title: "SFTP", detail: "Secure file transfer over SSH", symbol: "lock.shield")
                        uploaderOption(.ftp, title: "FTP / FTPS", detail: "File transfer with optional TLS", symbol: "network")
                    }
                    .padding(18)
                    .frame(width: 360)
                }
            }
            if model.settings.destinations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("Your captures, your destination").font(.headline)
                    Text("Add an uploader to share captures with a link.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose your active uploader").font(.subheadline.weight(.medium))
                        Text("Captures upload to the selected destination.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button { model.setActive(nil) } label: {
                            Label("None — keep captures local", systemImage: model.settings.activeDestination == nil ? "largecircle.fill.circle" : "circle")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.settings.activeDestination == nil ? .isSelected : [])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    ForEach(model.settings.destinations) { dest in
                        Divider().padding(.horizontal, 16)
                        HStack(spacing: 12) {
                            Button { model.setActive(dest.id) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: model.settings.activeDestinationID == dest.id ? "largecircle.fill.circle" : "circle")
                                        .font(.title3).foregroundStyle(model.settings.activeDestinationID == dest.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(dest.name).fontWeight(.medium)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(dest.kind.acceptsRecordings
                                             ? model.kindLabel(dest.kind)
                                             : "\(model.kindLabel(dest.kind)) · images only")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(dest.name)")
                            .accessibilityAddTraits(model.settings.activeDestinationID == dest.id ? .isSelected : [])
                            Button("Test…") { testing = dest }
                                .help("Test this uploader with a generated image")
                            Button { editing = dest } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Edit \(dest.name)")
                                .accessibilityLabel("Edit \(dest.name)")
                            Button(role: .destructive) { model.remove(dest) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(dest.name)").accessibilityLabel("Remove \(dest.name)")
                        }
                        .padding(16)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))

                // Only worth showing with somewhere else to choose: with a single
                // uploader "same as screenshots" and that uploader are the same thing.
                if model.settings.destinations.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Screen recordings").font(.subheadline.weight(.medium))
                        Text("Video can upload somewhere else. Image hosts often reject it.")
                            .font(.callout).foregroundStyle(.secondary)
                        Picker("Upload recordings to", selection: Binding<String?>(
                            get: { model.settings.activeRecordingDestinationID },
                            set: { model.setActiveRecording($0) })) {
                            Text("Same as screenshots").tag(String?.none)
                            ForEach(model.settings.destinations) { dest in
                                Text(dest.name).tag(String?.some(dest.id))
                            }
                        }
                        .frame(maxWidth: 340, alignment: .leading)
                        .accessibilityLabel("Upload recordings to")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
                }
            }
            if let blocked = model.settings.recordingDestinationRejectingVideo {
                Label("\(blocked.name) only accepts images, so screen recordings sent there "
                      + "will fail. Choose another destination under Screen recordings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("For a custom service, choose Import .sxcu… in the Lumeshot menu.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .alert("Couldn’t Remove Destination",
               isPresented: .constant(model.removeError != nil),
               presenting: model.removeError) { _ in
            Button("OK") { model.removeError = nil }
        } message: { Text($0) }
        .alert("Couldn’t Save Destination",
               isPresented: .constant(model.saveError != nil),
               presenting: model.saveError) { _ in
            Button("OK") { model.saveError = nil }
        } message: { Text($0) }
        .sheet(item: $adding) { kind in
            sheet(for: kind, existing: nil) { adding = nil }
        }
        .sheet(item: $editing) { dest in
            sheet(for: dest.kind, existing: dest) { editing = nil }
        }
        .sheet(item: $testing) { dest in
            UploaderTestSheet(model: model.testModel(for: dest))
        }
    }

    private func uploaderOption(_ kind: UploadDestinationKind, title: String, detail: String,
                                symbol: String) -> some View {
        Button {
            choosingUploader = false
            adding = kind
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One form per kind, used for both add and edit.
    @ViewBuilder
    private func sheet(for kind: UploadDestinationKind, existing: UploadDestination?,
                       dismiss: @escaping () -> Void) -> some View {
        switch kind {
        case .s3:     S3Sheet(model: model, existing: existing, dismiss: dismiss)
        case .imgur:  ImgurSheet(model: model, existing: existing, dismiss: dismiss)
        case .sftp:   SFTPSheet(model: model, existing: existing, dismiss: dismiss)
        case .ftp:    FTPSheet(model: model, existing: existing, dismiss: dismiss)
        case .picsur: PicsurSheet(model: model, existing: existing, dismiss: dismiss)
        case .customUploader:
            if let existing { RenameSheet(model: model, destination: existing, dismiss: dismiss) }
        }
    }
}

extension UploadDestinationKind: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Sheet chrome shared by every form

/// Title, form, and Cancel/Add-or-Save row. The secret-field prompt is the one
/// place add and edit genuinely differ: on edit a blank secret means "keep the
/// Keychain value", so the field says so instead of looking required.
private struct SheetFrame<Content: View>: View {
    let kind: String
    let formHeight: CGFloat
    let isEdit: Bool
    let isValid: Bool
    let dismiss: () -> Void
    let commit: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(isEdit ? "Edit" : "Add") \(kind) uploader")
                    .font(.system(size: 22, weight: .bold))
                Text(isEdit ? "Update the connection for this uploader." : "Connect a destination for your captures.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            Form { content() }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
                .frame(height: formHeight)
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save changes" : "Add uploader") { commit(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

}

private let keepPrompt = Text("unchanged")

// MARK: - Forms

private struct S3Sheet: View {
    @ObservedObject var model: DestinationsModel
    let existing: UploadDestination?
    let dismiss: () -> Void
    @State private var name: String
    @State private var region: String
    @State private var endpoint: String
    @State private var bucket: String
    @State private var prefix: String
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var pathStyle: Bool
    @State private var acl: String
    @State private var customDomain: String

    init(model: DestinationsModel, existing: UploadDestination?, dismiss: @escaping () -> Void) {
        self.model = model; self.existing = existing; self.dismiss = dismiss
        let c = existing?.s3Config
        _name = State(initialValue: existing?.name ?? "")
        _region = State(initialValue: c?.region ?? "us-east-1")
        _endpoint = State(initialValue: c?.endpoint ?? "s3.us-east-1.amazonaws.com")
        _bucket = State(initialValue: c?.bucket ?? "")
        _prefix = State(initialValue: c?.objectPrefix ?? "")
        _pathStyle = State(initialValue: c?.addressingStyle == .path)
        _acl = State(initialValue: c?.acl ?? "")
        _customDomain = State(initialValue: c?.customDomain ?? "")
    }

    private var isEdit: Bool { existing != nil }
    private var isValid: Bool {
        let keysConsistent = accessKeyID.isEmpty == secretAccessKey.isEmpty   // both or neither
        let keysPresentIfNew = isEdit || !accessKeyID.isEmpty
        return !bucket.isEmpty && !endpoint.isEmpty && keysConsistent && keysPresentIfNew
    }

    var body: some View {
        SheetFrame(kind: "S3", formHeight: 470, isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveS3(id: existing?.id, name: name, region: region, endpoint: endpoint,
                         bucket: bucket, prefix: prefix, accessKeyID: accessKeyID,
                         secretAccessKey: secretAccessKey, pathStyle: pathStyle,
                         acl: acl, customDomain: customDomain)
        }) {
            Section("Connection") {
                TextField("Name", text: $name, prompt: Text("Work screenshots"))
                TextField("Region", text: $region)
                TextField("Endpoint", text: $endpoint, prompt: Text("s3.us-east-1.amazonaws.com"))
                TextField("Bucket", text: $bucket)
                TextField("Object prefix", text: $prefix, prompt: Text("Optional"))
            }
            Section {
                TextField("Access key ID", text: $accessKeyID, prompt: isEdit ? keepPrompt : nil)
                SecureField("Secret access key", text: $secretAccessKey, prompt: isEdit ? keepPrompt : nil)
            } header: { Text("Credentials") } footer: {
                Text(isEdit ? "Leave both fields blank to keep the saved credentials." : "Credentials are stored in your Mac’s Keychain.")
            }
            Section("Advanced") {
                Toggle("Path-style addressing", isOn: $pathStyle)
                TextField("ACL", text: $acl, prompt: Text("Optional, e.g. public-read"))
                TextField("Custom domain", text: $customDomain, prompt: Text("Optional"))
            }
        }
    }
}

private struct ImgurSheet: View {
    @ObservedObject var model: DestinationsModel
    let existing: UploadDestination?
    let dismiss: () -> Void
    @State private var name: String
    @State private var clientID: String

    init(model: DestinationsModel, existing: UploadDestination?, dismiss: @escaping () -> Void) {
        self.model = model; self.existing = existing; self.dismiss = dismiss
        _name = State(initialValue: existing?.name ?? "")
        _clientID = State(initialValue: existing?.imgurClientID ?? "")
    }

    var body: some View {
        SheetFrame(kind: "Imgur", formHeight: 170, isEdit: existing != nil, isValid: !clientID.isEmpty,
                   dismiss: dismiss, commit: {
            model.saveImgur(id: existing?.id, name: name, clientID: clientID)
        }) {
            TextField("Name", text: $name)
            TextField("Client ID", text: $clientID)
        }
    }
}

private struct SFTPSheet: View {
    @ObservedObject var model: DestinationsModel
    let existing: UploadDestination?
    let dismiss: () -> Void
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var remoteDirectory: String
    @State private var publicURLBase: String
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var passphrase = ""

    init(model: DestinationsModel, existing: UploadDestination?, dismiss: @escaping () -> Void) {
        self.model = model; self.existing = existing; self.dismiss = dismiss
        let c = existing?.sftpConfig
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: c?.host ?? "")
        _port = State(initialValue: String(c?.port ?? 22))
        _username = State(initialValue: c?.username ?? "")
        _remoteDirectory = State(initialValue: c?.remoteDirectory ?? "")
        _publicURLBase = State(initialValue: c?.publicURLBase ?? "")
    }

    private var isEdit: Bool { existing != nil }
    private var portValue: Int { Int(port) ?? 22 }
    private var hasCredential: Bool { !password.isEmpty || !privateKeyPEM.isEmpty }
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !remoteDirectory.isEmpty
            && !publicURLBase.isEmpty && (isEdit || hasCredential)
    }

    var body: some View {
        SheetFrame(kind: "SFTP", formHeight: 470, isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveSFTP(id: existing?.id, name: name, host: host, port: portValue,
                           username: username, remoteDirectory: remoteDirectory,
                           publicURLBase: publicURLBase, password: password,
                           privateKeyPEM: privateKeyPEM, passphrase: passphrase)
        }) {
            Section("Connection") {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
            }
            Section("Destination") {
                TextField("Remote directory", text: $remoteDirectory)
                TextField("Public URL base", text: $publicURLBase)
            }
            Section {
                SecureField("Password", text: $password, prompt: isEdit ? keepPrompt : Text("Optional when using a key"))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Private key (PEM)")
                    TextEditor(text: $privateKeyPEM)
                        .frame(height: 80)
                        .font(.system(.body, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        .accessibilityLabel("Private key in PEM format")
                }
                SecureField("Key passphrase", text: $passphrase, prompt: isEdit ? keepPrompt : Text("Optional"))
            } header: { Text("Authentication") } footer: {
                Text(isEdit ? "Leave all credentials blank to keep the stored ones. Entering any replaces the entire credential set." : "Use a password or private key. Credentials are stored in your Mac’s Keychain.")
            }
            if isEdit, existing?.sftpConfig?.knownHostKey != nil {
                Text("Host key pinned. Changing the host clears the pin so the new server is trusted on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FTPSheet: View {
    @ObservedObject var model: DestinationsModel
    let existing: UploadDestination?
    let dismiss: () -> Void
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var remoteDirectory: String
    @State private var publicURLBase: String
    @State private var password = ""
    @State private var useTLS: Bool

    init(model: DestinationsModel, existing: UploadDestination?, dismiss: @escaping () -> Void) {
        self.model = model; self.existing = existing; self.dismiss = dismiss
        let c = existing?.ftpConfig
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: c?.host ?? "")
        _port = State(initialValue: String(c?.port ?? 21))
        _username = State(initialValue: c?.username ?? "")
        _remoteDirectory = State(initialValue: c?.remoteDirectory ?? "")
        _publicURLBase = State(initialValue: c?.publicURLBase ?? "")
        _useTLS = State(initialValue: c?.useTLS ?? false)
    }

    private var isEdit: Bool { existing != nil }
    private var portValue: Int { Int(port) ?? 21 }
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !remoteDirectory.isEmpty
            && !publicURLBase.isEmpty && (isEdit || !password.isEmpty)
    }

    var body: some View {
        SheetFrame(kind: "FTP", formHeight: 400, isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveFTP(id: existing?.id, name: name, host: host, port: portValue,
                          username: username, remoteDirectory: remoteDirectory,
                          publicURLBase: publicURLBase, password: password, useTLS: useTLS)
        }) {
            Section("Connection") {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                Toggle("Use FTPS (TLS)", isOn: $useTLS)
            }
            Section("Destination") {
                TextField("Remote directory", text: $remoteDirectory)
                TextField("Public URL base", text: $publicURLBase)
            }
            Section {
                SecureField("Password", text: $password, prompt: isEdit ? keepPrompt : nil)
            } header: { Text("Credentials") } footer: {
                Text(isEdit ? "Leave blank to keep the saved password." : "Your password is stored in your Mac’s Keychain.")
            }
        }
    }
}

private struct PicsurSheet: View {
    @ObservedObject var model: DestinationsModel
    let existing: UploadDestination?
    let dismiss: () -> Void
    @State private var name: String
    @State private var host: String
    @State private var apiKey = ""
    @State private var imageFormat: String
    @State private var linkStyle: PicsurLinkStyle

    /// Picsur converts on the fly, so these are serving formats, not source formats.
    private let formats = ["png", "jpg", "webp", "avif", "gif", "bmp", "tiff", "qoi"]

    init(model: DestinationsModel, existing: UploadDestination?, dismiss: @escaping () -> Void) {
        self.model = model; self.existing = existing; self.dismiss = dismiss
        let c = existing?.picsurConfig
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: c?.host ?? "")
        _imageFormat = State(initialValue: c?.imageFormat ?? "png")
        _linkStyle = State(initialValue: c?.linkStyle ?? .directImage)
    }

    private var isEdit: Bool { existing != nil }
    private var isValid: Bool {
        PicsurConfig.isValidHost(PicsurConfig.normalizeHost(host)) && (isEdit || !apiKey.isEmpty)
    }

    var body: some View {
        SheetFrame(kind: "Picsur", formHeight: 380, isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.savePicsur(id: existing?.id, name: name, host: host, apiKey: apiKey,
                             imageFormat: imageFormat, linkStyle: linkStyle)
        }) {
            Section("Connection") {
                TextField("Name", text: $name)
                TextField("Host", text: $host, prompt: Text("https://pic.example.net"))
                SecureField("API key", text: $apiKey, prompt: isEdit ? keepPrompt : nil)
            }
            if PicsurConfig(host: host, imageFormat: imageFormat).isInsecureTransport {
                Label("Plain HTTP sends your API key and captures without encryption.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("Sharing") {
                Picker("Image format", selection: $imageFormat) {
                    ForEach(formats, id: \.self) { Text(".\($0)").tag($0) }
                }
                Picker("Copied link", selection: $linkStyle) {
                    Text("Direct image").tag(PicsurLinkStyle.directImage)
                    Text("Viewer page").tag(PicsurLinkStyle.viewerPage)
                }
            }
            Text(isEdit ? "Leave the API key blank to keep the saved key." : "Create a key in Picsur → Settings → API keys. It is stored in your Mac’s Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Imported `.sxcu` destinations: rename only.
private struct RenameSheet: View {
    @ObservedObject var model: DestinationsModel
    let destination: UploadDestination
    let dismiss: () -> Void
    @State private var name: String

    init(model: DestinationsModel, destination: UploadDestination, dismiss: @escaping () -> Void) {
        self.model = model; self.destination = destination; self.dismiss = dismiss
        _name = State(initialValue: destination.name)
    }

    var body: some View {
        SheetFrame(kind: "Custom (.sxcu)", formHeight: 190, isEdit: true, isValid: !name.isEmpty,
                   dismiss: dismiss, commit: { model.renameCustom(destination, to: name) }) {
            TextField("Name", text: $name)
            Text("The uploader definition comes from the imported file. To change it, remove this destination and import an updated .sxcu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
