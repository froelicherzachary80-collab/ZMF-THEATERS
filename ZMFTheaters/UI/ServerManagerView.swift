import SwiftUI

struct ServerManagerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @State private var editing: ServerAccount?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                Text("Connect as many personal Jellyfin servers as you like. Passwords and access tokens are stored only in the iOS Keychain, and each token is only ever sent to the server that issued it. Nothing on your servers is ever modified or deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Home4DXSection(link: model.home4DX)
            ForEach(library.servers) { server in
                ServerRow(server: server, onEdit: { editing = server })
            }
            Section {
                Button { adding = true } label: { Label("Add Server", systemImage: "plus.circle.fill") }
                if !library.servers.isEmpty {
                    Button {
                        Task {
                            await library.syncAll()
                            model.refreshProgramme()
                        }
                    } label: { Label("Sync All Libraries", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
        }
        .navigationTitle("Server Manager")
        .sheet(isPresented: $adding) { NavigationStack { ServerEditor(existing: nil) } }
        .sheet(item: $editing) { s in NavigationStack { ServerEditor(existing: s) } }
    }
}

private struct ServerRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    let server: ServerAccount
    let onEdit: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(server.isOnline ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(server.displayName).font(.headline)
                Spacer()
                if library.syncing.contains(server.id) { ProgressView().controlSize(.small) }
            }
            Text("\(server.url) · \(server.username)").font(.caption).foregroundStyle(.secondary)
            if !server.isHTTPS {
                Label("Not using HTTPS — only use plain HTTP on a trusted LAN or private VPN (e.g. Tailscale).", systemImage: "exclamationmark.shield")
                    .font(.caption2).foregroundStyle(.yellow)
            }
            if let status = server.lastStatus { Text(status).font(.caption2) }
            Text("Last successful sync: \(server.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Test") { Task { _ = await library.testConnection(server) } }
                Button("Sync") {
                    Task {
                        await library.sync(server)
                        model.refreshProgramme()
                    }
                }
                Button("Edit", action: onEdit)
                Spacer()
                Button("Remove", role: .destructive) { confirmRemove = true }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove \(server.displayName)?", isPresented: $confirmRemove) {
            Button("Remove server from ZMF THEATERS+", role: .destructive) {
                library.removeServer(server)
                model.refreshProgramme()
            }
        } message: {
            Text("This only disconnects the app. Nothing on the Jellyfin server is changed.")
        }
    }
}

struct ServerEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    let existing: ServerAccount?

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?
    @State private var connected: ServerAccount?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Display name (e.g. Movies, Marvel Collection)", text: $name)
                TextField("https://jellyfin.example.com", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(existing == nil ? "Password" : "Password (leave blank to keep)", text: $password)
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text(existing == nil ? "Test & Connect" : "Test & Save"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || url.isEmpty || username.isEmpty)
                if let message { Text(message).font(.caption).foregroundStyle(message.hasPrefix("✓") ? .green : .red) }
            }
            if let account = connected ?? existing, !account.knownLibraries.isEmpty {
                Section("Libraries to include (none selected = all video libraries)") {
                    ForEach(account.knownLibraries) { lib in
                        Toggle(isOn: Binding(get: { selected.contains(lib.id) }, set: { on in
                            if on { selected.insert(lib.id) } else { selected.remove(lib.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(lib.name)
                                Text(lib.collectionType ?? "mixed").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Save libraries & sync now") {
                        Task {
                            library.setSelectedLibraries(account, ids: Array(selected))
                            if let updated = library.servers.first(where: { $0.id == account.id }) { await library.sync(updated) }
                            model.refreshProgramme()
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Jellyfin Server" : "Edit Server")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear {
            if let e = existing {
                name = e.displayName; url = e.url; username = e.username
                selected = Set(e.selectedLibraryIds)
            }
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do {
            let account = try await library.addOrUpdateServer(existing: existing, name: name, url: url, username: username, password: password)
            connected = account
            message = "✓ Connected to \(account.serverName ?? "Jellyfin") \(account.serverVersion ?? "") as \(username). Choose libraries below, then sync."
            password = ""
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Connect to the Windows PC that runs Home 4DX (fan + lights). The access
/// code is shown on the PC in Admin → Immersive Home 4DX → PC + iPhone Companion.
private struct Home4DXSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @ObservedObject var link: Home4DXLink
    @State private var code = Keychain.get(Home4DXLink.codeKey) ?? ""

    var body: some View {
        Section {
            TextField("PC address, e.g. 192.168.1.20:8977", text: $settingsStore.settings.home4DXHost)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("Access code from the PC", text: $code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            HStack {
                Button(link.connected ? "Reconnect" : "Connect") {
                    Keychain.set(code, for: Home4DXLink.codeKey)
                    let host = settingsStore.settings.home4DXHost
                    Task { await link.connect(host: host, code: code) }
                }
                Spacer()
                Button(role: .destructive) { Task { await link.emergencyStop() } } label: {
                    Label("Emergency stop", systemImage: "stop.circle.fill")
                }.disabled(!link.connected)
            }
            Text(link.status).font(.caption).foregroundStyle(link.connected ? .green : .secondary)
            if link.connected {
                HStack {
                    Label(link.stopped ? "EMERGENCY STOP" : link.physicalArmed ? "PHYSICAL ARMED" : "PHYSICAL OFF",
                          systemImage: link.stopped ? "stop.circle.fill" : "power")
                    Spacer()
                    Button("Refresh devices") { Task { await link.refreshEquipment() } }
                }.font(.caption)
                Text(link.equipmentStatus).font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !link.hostNote.isEmpty { Text(link.hostNote).font(.caption2).foregroundStyle(.orange) }
            Toggle("Connect automatically", isOn: $settingsStore.settings.home4DXAutoConnect)
        } header: {
            Text("Home 4DX (Windows PC)")
        } footer: {
            Text("Your Windows PC is the only real hardware controller. TAPO_01 switches a tested Sweetfull fan; TAPO_02 switches power to the tested Govee strip. Bluetooth (on the PC) handles RGB colour once the strip is powered. TAPO_03 remains unassigned. Sync requires the PC's analysed title timeline and a trusted local network; guests cannot switch equipment.")
        }
    }
}
