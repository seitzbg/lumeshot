import SwiftUI
import SXCore
import SXUpload

@MainActor
final class DestinationsModel: ObservableObject {
    @Published var settings: UploadSettings
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

    func setActive(_ id: String) {
        persist { $0.upload = $0.upload.settingActive(id: id) }
    }

    func remove(_ destination: UploadDestination) {
        // Purge Keychain secrets BEFORE dropping the destination so nothing is orphaned.
        do {
            switch destination.kind {
            case .customUploader:
                if let cfg = destination.customUploader {
                    try SecretVault.purge(cfg, id: destination.id, from: credentials)
                }
            case .s3:
                try S3Credentials.purge(id: destination.id, from: credentials)
            case .imgur:
                break
            case .ftp:
                try FTPCredentials.purge(id: destination.id, from: credentials)
            case .sftp:
                try SFTPCredentials.purge(id: destination.id, from: credentials)
            }
        } catch {
            AppLog.log("Destinations: secret purge failed for \(destination.id): \(error)")
        }
        persist { $0.upload = $0.upload.removing(id: destination.id) }
    }

    func addImgur(name: String, clientID: String) {
        let dest = UploadDestination(id: UUID().uuidString,
                                     name: name.isEmpty ? "Imgur" : name,
                                     kind: .imgur, imgurClientID: clientID)
        persist { $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: dest.id) }
    }

    func addS3(name: String, region: String, endpoint: String, bucket: String, prefix: String,
               accessKeyID: String, secretAccessKey: String, pathStyle: Bool,
               acl: String, customDomain: String) {
        let id = UUID().uuidString
        do {
            try S3Credentials.store(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                    id: id, into: credentials)
        } catch {
            AppLog.log("Destinations: storing S3 credentials failed: \(error)")
            return
        }
        let config = S3Config(region: region, endpoint: endpoint, bucket: bucket,
                              objectPrefix: prefix,
                              addressingStyle: pathStyle ? .path : .virtualHost,
                              acl: acl.isEmpty ? nil : acl,
                              customDomain: customDomain.isEmpty ? nil : customDomain)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "S3" : name,
                                     kind: .s3, s3Config: config)
        if !persist({ $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: id) }) {
            // Save failed: roll back the orphaned Keychain secret we just wrote,
            // so the Keychain never drifts out of sync with settings.json.
            try? S3Credentials.purge(id: id, from: credentials)
        }
    }

    func addSFTP(name: String, host: String, port: Int, username: String, remoteDirectory: String,
                publicURLBase: String, password: String, privateKeyPEM: String, passphrase: String) {
        let id = UUID().uuidString
        do {
            try SFTPCredentials.store(password: password.isEmpty ? nil : password,
                                      privateKeyPEM: privateKeyPEM.isEmpty ? nil : privateKeyPEM,
                                      passphrase: passphrase.isEmpty ? nil : passphrase,
                                      id: id, into: credentials)
        } catch {
            AppLog.log("Destinations: storing SFTP credentials failed: \(error)")
            return
        }
        let config = SFTPConfig(host: host, port: port, username: username,
                                remoteDirectory: remoteDirectory, publicURLBase: publicURLBase)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "SFTP" : name,
                                     kind: .sftp, sftpConfig: config)
        if !persist({ $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: id) }) {
            // Save failed: roll back the orphaned Keychain secret we just wrote,
            // so the Keychain never drifts out of sync with settings.json.
            try? SFTPCredentials.purge(id: id, from: credentials)
        }
    }

    func addFTP(name: String, host: String, port: Int, username: String, remoteDirectory: String,
               publicURLBase: String, password: String, useTLS: Bool) {
        let id = UUID().uuidString
        do {
            try FTPCredentials.store(password: password, id: id, into: credentials)
        } catch {
            AppLog.log("Destinations: storing FTP credentials failed: \(error)")
            return
        }
        let config = FTPConfig(host: host, port: port, username: username,
                               remoteDirectory: remoteDirectory, publicURLBase: publicURLBase,
                               useTLS: useTLS)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "FTP" : name,
                                     kind: .ftp, ftpConfig: config)
        if !persist({ $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: id) }) {
            try? FTPCredentials.purge(id: id, from: credentials)
        }
    }

    func kindLabel(_ kind: UploadDestinationKind) -> String {
        switch kind {
        case .customUploader: return "Custom (.sxcu)"
        case .imgur: return "Imgur"
        case .s3: return "S3"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        }
    }
}

struct DestinationsView: View {
    @ObservedObject var model: DestinationsModel
    @State private var showAddS3 = false
    @State private var showAddImgur = false
    @State private var showAddSFTP = false
    @State private var showAddFTP = false

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
                            Button(role: .destructive) { model.remove(dest) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.setActive(dest.id) }
                    }
                }
            }
            HStack {
                Button("Add S3…") { showAddS3 = true }
                Button("Add Imgur…") { showAddImgur = true }
                Button("Add SFTP…") { showAddSFTP = true }
                Button("Add FTP…") { showAddFTP = true }
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $showAddS3) { AddS3Sheet(model: model, isPresented: $showAddS3) }
        .sheet(isPresented: $showAddImgur) { AddImgurSheet(model: model, isPresented: $showAddImgur) }
        .sheet(isPresented: $showAddSFTP) { AddSFTPSheet(model: model, isPresented: $showAddSFTP) }
        .sheet(isPresented: $showAddFTP) { AddFTPSheet(model: model, isPresented: $showAddFTP) }
    }
}

private struct AddS3Sheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var region = "us-east-1"
    @State private var endpoint = "s3.us-east-1.amazonaws.com"
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var pathStyle = false
    @State private var acl = ""
    @State private var customDomain = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add S3 Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Region", text: $region)
                TextField("Endpoint (host, no bucket)", text: $endpoint)
                TextField("Bucket", text: $bucket)
                TextField("Object prefix (optional)", text: $prefix)
                TextField("Access Key ID", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                Toggle("Path-style addressing", isOn: $pathStyle)
                TextField("ACL (optional, e.g. public-read)", text: $acl)
                TextField("Custom domain (optional)", text: $customDomain)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addS3(name: name, region: region, endpoint: endpoint, bucket: bucket,
                                prefix: prefix, accessKeyID: accessKeyID,
                                secretAccessKey: secretAccessKey, pathStyle: pathStyle,
                                acl: acl, customDomain: customDomain)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bucket.isEmpty || endpoint.isEmpty || accessKeyID.isEmpty
                          || secretAccessKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

private struct AddImgurSheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var clientID = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add Imgur Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Client ID", text: $clientID)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addImgur(name: name, clientID: clientID)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientID.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

private struct AddSFTPSheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var remoteDirectory = ""
    @State private var publicURLBase = ""
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var passphrase = ""

    private var portValue: Int { Int(port) ?? 22 }
    private var hasCredential: Bool { !password.isEmpty || !privateKeyPEM.isEmpty }
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !remoteDirectory.isEmpty
            && !publicURLBase.isEmpty && hasCredential
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add SFTP Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                TextField("Remote directory", text: $remoteDirectory)
                TextField("Public URL base", text: $publicURLBase)
                SecureField("Password (optional if using a key)", text: $password)
                TextEditor(text: $privateKeyPEM)
                    .frame(height: 80)
                    .font(.system(.body, design: .monospaced))
                SecureField("Key passphrase (optional)", text: $passphrase)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addSFTP(name: name, host: host, port: portValue, username: username,
                                  remoteDirectory: remoteDirectory, publicURLBase: publicURLBase,
                                  password: password, privateKeyPEM: privateKeyPEM, passphrase: passphrase)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

private struct AddFTPSheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var host = ""
    @State private var port = "21"
    @State private var username = ""
    @State private var remoteDirectory = ""
    @State private var publicURLBase = ""
    @State private var password = ""
    @State private var useTLS = false

    private var portValue: Int { Int(port) ?? 21 }
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !remoteDirectory.isEmpty
            && !publicURLBase.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add FTP Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                TextField("Remote directory", text: $remoteDirectory)
                TextField("Public URL base", text: $publicURLBase)
                SecureField("Password", text: $password)
                Toggle("Use FTPS (TLS)", isOn: $useTLS)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addFTP(name: name, host: host, port: portValue, username: username,
                                 remoteDirectory: remoteDirectory, publicURLBase: publicURLBase,
                                 password: password, useTLS: useTLS)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
