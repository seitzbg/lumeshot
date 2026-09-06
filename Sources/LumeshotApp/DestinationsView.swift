import SwiftUI
import LumeshotCore
import LumeshotUpload

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

    /// Persisted binding for the Uploads tab's "Upload after capture" toggle
    /// — goes through the same persist() as every other Destinations edit.
    func setUploadAfterCapture(_ newValue: Bool) {
        persist { $0.upload.uploadAfterCapture = newValue }
    }

    func setActive(_ id: String) {
        persist { $0.upload = $0.upload.settingActive(id: id) }
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
    /// before we overwrote them. New destinations become active; edits leave
    /// the selection alone.
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
            if isNew { all.upload = all.upload.settingActive(id: dest.id) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinations").font(.headline)
            if model.settings.destinations.isEmpty {
                Text("No destinations yet. Add one below or import a .sxcu from the menu.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(model.settings.destinations) { dest in
                        HStack {
                            Image(systemName: model.settings.activeDestinationID == dest.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                                .onTapGesture { model.setActive(dest.id) }
                            VStack(alignment: .leading) {
                                Text(dest.name)
                                Text(model.kindLabel(dest.kind))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { editing = dest } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Edit")
                            Button(role: .destructive) { model.remove(dest) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = dest }
                        .onTapGesture { model.setActive(dest.id) }
                    }
                }
            }
            HStack {
                Button("Add S3…") { adding = .s3 }
                Button("Add Imgur…") { adding = .imgur }
                Button("Add SFTP…") { adding = .sftp }
                Button("Add FTP…") { adding = .ftp }
                Button("Add Picsur…") { adding = .picsur }
                Spacer()
            }
        }
        .padding()
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
    let isEdit: Bool
    let isValid: Bool
    let dismiss: () -> Void
    let commit: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(isEdit ? "Edit" : "Add") \(kind) Destination").font(.headline)
            Form { content() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isEdit ? "Save" : "Add") { commit(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 420)
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
        SheetFrame(kind: "S3", isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveS3(id: existing?.id, name: name, region: region, endpoint: endpoint,
                         bucket: bucket, prefix: prefix, accessKeyID: accessKeyID,
                         secretAccessKey: secretAccessKey, pathStyle: pathStyle,
                         acl: acl, customDomain: customDomain)
        }) {
            TextField("Name", text: $name)
            TextField("Region", text: $region)
            TextField("Endpoint (host, no bucket)", text: $endpoint)
            TextField("Bucket", text: $bucket)
            TextField("Object prefix (optional)", text: $prefix)
            TextField("Access Key ID", text: $accessKeyID, prompt: isEdit ? keepPrompt : nil)
            SecureField("Secret Access Key", text: $secretAccessKey, prompt: isEdit ? keepPrompt : nil)
            Toggle("Path-style addressing", isOn: $pathStyle)
            TextField("ACL (optional, e.g. public-read)", text: $acl)
            TextField("Custom domain (optional)", text: $customDomain)
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
        SheetFrame(kind: "Imgur", isEdit: existing != nil, isValid: !clientID.isEmpty,
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
        SheetFrame(kind: "SFTP", isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveSFTP(id: existing?.id, name: name, host: host, port: portValue,
                           username: username, remoteDirectory: remoteDirectory,
                           publicURLBase: publicURLBase, password: password,
                           privateKeyPEM: privateKeyPEM, passphrase: passphrase)
        }) {
            TextField("Name", text: $name)
            TextField("Host", text: $host)
            TextField("Port", text: $port)
            TextField("Username", text: $username)
            TextField("Remote directory", text: $remoteDirectory)
            TextField("Public URL base", text: $publicURLBase)
            SecureField("Password (optional if using a key)", text: $password,
                        prompt: isEdit ? keepPrompt : nil)
            if isEdit {
                Text("Leave the credentials blank to keep the stored ones. Entering any replaces all of them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $privateKeyPEM)
                .frame(height: 80)
                .font(.system(.body, design: .monospaced))
            SecureField("Key passphrase (optional)", text: $passphrase,
                        prompt: isEdit ? keepPrompt : nil)
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
        SheetFrame(kind: "FTP", isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.saveFTP(id: existing?.id, name: name, host: host, port: portValue,
                          username: username, remoteDirectory: remoteDirectory,
                          publicURLBase: publicURLBase, password: password, useTLS: useTLS)
        }) {
            TextField("Name", text: $name)
            TextField("Host", text: $host)
            TextField("Port", text: $port)
            TextField("Username", text: $username)
            TextField("Remote directory", text: $remoteDirectory)
            TextField("Public URL base", text: $publicURLBase)
            SecureField("Password", text: $password, prompt: isEdit ? keepPrompt : nil)
            Toggle("Use FTPS (TLS)", isOn: $useTLS)
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
        SheetFrame(kind: "Picsur", isEdit: isEdit, isValid: isValid, dismiss: dismiss, commit: {
            model.savePicsur(id: existing?.id, name: name, host: host, apiKey: apiKey,
                             imageFormat: imageFormat, linkStyle: linkStyle)
        }) {
            TextField("Name", text: $name)
            TextField("Host", text: $host, prompt: Text("https://pic.example.net"))
            SecureField("API key", text: $apiKey, prompt: isEdit ? keepPrompt : nil)
            Picker("Image format", selection: $imageFormat) {
                ForEach(formats, id: \.self) { Text(".\($0)").tag($0) }
            }
            Picker("Copied link", selection: $linkStyle) {
                Text("Direct image").tag(PicsurLinkStyle.directImage)
                Text("Viewer page").tag(PicsurLinkStyle.viewerPage)
            }
            .pickerStyle(.radioGroup)
            if PicsurConfig(host: host, imageFormat: imageFormat).isInsecureTransport {
                Label("Plain http — the API key and your captures are sent in cleartext.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Create the API key in Picsur under Settings → API keys.")
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
        SheetFrame(kind: "Custom (.sxcu)", isEdit: true, isValid: !name.isEmpty,
                   dismiss: dismiss, commit: { model.renameCustom(destination, to: name) }) {
            TextField("Name", text: $name)
            Text("The uploader definition comes from the imported file. To change it, remove this destination and import an updated .sxcu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
