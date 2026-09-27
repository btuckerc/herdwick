import HerdrAPI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(Tailnet.self) private var tailnet
    @Environment(\.dismiss) private var dismiss
    @State private var addingHost = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("System").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    NavigationLink {
                        ThemePicker(selection: $settings.darkThemeID, dark: true)
                    } label: {
                        LabeledContent("Dark Theme", value: TerminalTheme.named(settings.darkThemeID).name)
                    }
                    NavigationLink {
                        ThemePicker(selection: $settings.lightThemeID, dark: false)
                    } label: {
                        LabeledContent("Light Theme", value: TerminalTheme.named(settings.lightThemeID).name)
                    }
                }

                Section("Conversations") {
                    LabeledContent("Detail") {
                        Menu {
                            DetailLevelOptions(selection: $settings.detailLevel)
                        } label: {
                            HStack(spacing: 4) {
                                Text(DetailLevelOptions.title(settings.detailLevel))
                                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .tint(.secondary)
                    }
                    Toggle("Show Working Subagents", isOn: $settings.showWorkingSubagents)
                    NavigationLink("Launch Presets") { PresetsEditor() }
                }

                Section("Inbox") {
                    Picker("View", selection: $settings.inboxView) {
                        ForEach(InboxKind.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("All Hosts", isOn: $settings.allHosts)
                    Picker("Group", selection: $settings.inboxGrouping) {
                        ForEach(InboxGrouping.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Sort", selection: $settings.inboxSort) {
                        ForEach(InboxSort.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Collapse Idle Agents", isOn: $settings.collapseIdle)
                    Toggle("Message Previews", isOn: $settings.inboxPreviews)
                }
                NotificationSettings()
                PrivacySettings()
                Section("Terminal") {
                    Picker("Font", selection: $settings.font) {
                        ForEach(TerminalFont.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper(value: $settings.fontSize, in: 8...20, step: 1) {
                        LabeledContent("Size", value: "\(Int(settings.fontSize)) pt")
                    }
                    TerminalPreview()
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    Toggle("Haptics", isOn: $settings.haptics)
                }

                Section {
                    Toggle("Autocorrect", isOn: $settings.composerAutocorrect)
                    Toggle("On-screen Return Sends", isOn: $settings.returnKeySends)
                    Picker("Keep Uploads", selection: $settings.attachmentRetention) {
                        ForEach(AttachmentRetention.allCases) { Text($0.label).tag($0) }
                    }
                    NavigationLink("Snippets") { SnippetsEditor() }
                } header: {
                    Text("Messages")
                } footer: {
                    Text("Expired uploads are removed from the host at your next upload.")
                }

                Section {
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            HostEditor(profile: profile)
                        } label: {
                            LabeledContent(profile.name, value: profile.address)
                        }
                    }
                    .onMove { model.moveProfiles(from: $0, to: $1) }
                    Button("Add Host…", systemImage: "plus") { addingHost = true }
                } header: {
                    Text("Hosts")
                }

                AuthorizedKeySection()

                Section("Tailscale") {
                    switch tailnet.state {
                    case .running:
                        if let name = tailnet.tailnetName { LabeledContent("Tailnet", value: name) }
                        LabeledContent("Device", value: "herdwick-\(UIDeviceName.short)")
                        Button("Sign Out of Tailscale", role: .destructive) { Task { await tailnet.signOut() } }
                    case .off:
                        Text("Not signed in").foregroundStyle(.secondary)
                    default:
                        Text("Starting…").foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("herdr", destination: URL(string: "https://herdr.dev")!)
                    NavigationLink("Acknowledgements") { Acknowledgements() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $addingHost) { AddHostView() }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(Settings.self) private var settings
    @State private var deletingCopies = false
    @State private var failure: String?

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("App Lock", isOn: $settings.appLock)
            Toggle("Keep Offline Copies", isOn: Binding(get: { settings.offlineTranscripts }, set: { on in
                if on { settings.offlineTranscripts = true }
                else { deletingCopies = true }
            }))
            NavigationLink("Replace This Device's Key…") { DeviceKeyReplacement() }
        } header: {
            Text("Privacy")
        } footer: {
            Text("App Lock requires Face ID or your passcode at launch and after 30 seconds away. Offline copies keep up to 20 conversations, at most 4 MB each, protected while your device is locked. Turning this off deletes the copies.")
        }
        .confirmationDialog("Delete all offline copies?", isPresented: $deletingCopies, titleVisibility: .visible) {
            Button("Delete Copies", role: .destructive) {
                do {
                    try TranscriptCache.removeAll()
                    settings.offlineTranscripts = false
                } catch { failure = error.localizedDescription }
            }
        }
        .alert("Couldn't Delete Copies", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

private struct DeviceKeyReplacement: View {
    @Environment(AppModel.self) private var model
    @State private var pending = DeviceKey.rotation()
    @State private var confirmingRemoval = false
    @State private var failure: String?
    @State private var completed = false

    var body: some View {
        Form {
            if let pending {
                Section("New Public Key") {
                    Text(pending.publicKeyLine).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink("Share Public Key", item: pending.publicKeyLine)
                }
                Section {
                    ForEach(pending.hosts.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending.hosts[id] ?? "Host")
                            if pending.confirmed.contains(id) {
                                Label("Confirmed by you", systemImage: "checkmark")
                            } else if pending.testing.contains(id) {
                                Text("New key selected for the next connection. Close and reopen Herdwick, connect to this host, then confirm here.").font(.caption)
                                Button("I Connected Successfully with the New Key") {
                                    update { $0.confirmed.insert(id) }
                                }
                            } else {
                                Button("Use New Key on Next Connection") { update { $0.testing.insert(id) } }
                            }
                            if pending.testing.contains(id) || pending.confirmed.contains(id) {
                                Button("Use Old Key Again") {
                                    update { $0.testing.remove(id); $0.confirmed.remove(id) }
                                }
                            }
                        }
                    }
                } header: { Text("Host Progress") } footer: {
                    Text("Append the new public key to authorized_keys on every host first; keep the old line. Confirmation is your verification, not an automatic connection test. Unreachable hosts must stay pending.")
                }
                Section {
                    Button("Remove Old Key…", role: .destructive) { confirmingRemoval = true }
                        .disabled(!Set(pending.hosts.keys).isSubset(of: pending.confirmed))
                } footer: {
                    Text("Removes the old private key from this device only. Afterward, remove its public-key line from each host yourself.")
                }
            } else {
                Section {
                    Text(completed ? "The new device key is now active." : "Generate a replacement, install its public key on each host, and confirm every host before removing the old key.")
                    Button("Generate Replacement Key") {
                        do { pending = try DeviceKey.beginRotation(profiles: model.profiles) }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("Replace Device Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { includeNewHosts() }
        .onChange(of: model.profiles) { includeNewHosts() }
        .confirmationDialog("Permanently remove the old private key?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Old Key", role: .destructive) {
                guard let pending else { return }
                do {
                    try DeviceKey.finishRotation(pending, profiles: model.profiles)
                    self.pending = nil
                    completed = true
                } catch { failure = error.localizedDescription }
            }
        }
        .alert("Key Replacement Failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func update(_ change: (inout DeviceKey.Rotation) -> Void) {
        guard var next = pending else { return }
        change(&next)
        do { try DeviceKey.saveRotation(next); pending = next }
        catch { failure = error.localizedDescription }
    }

    private func includeNewHosts() {
        update { next in
            for profile in model.profiles where profile.auth == .deviceKey {
                next.hosts[profile.id] = profile.name
            }
        }
    }
}

/// Local alerts come while Herdwick is open or refreshing in the background, which iOS
/// schedules as it sees fit; alerts while away are the opt-in push path.
private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @State private var denied = false

    var body: some View {
        Section {
            Toggle("Needs You", isOn: binding(\.notifyNeedsYou))
            Toggle("Finished", isOn: binding(\.notifyFinished))
            if denied {
                Link("Allow Notifications in Settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
            }
        } header: {
            Text("Notifications")
        }
        if Push.relay != nil {
            Section {
                Toggle("Alerts While Away", isOn: Binding {
                    settings.pushWhileAway
                } set: { on in
                    settings.pushWhileAway = on
                    if on { model.registerForPush() }
                })
                .disabled(!settings.notifyNeedsYou && !settings.notifyFinished)
                NavigationLink("How It Works") { PushDisclosure() }
                if settings.pushWhileAway, let push = model.push {
                    ForEach(push.coverage.values.sorted { $0.id < $1.id }) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.profiles.first { $0.id == row.hostID }?.name ?? "Host") · \(row.session)")
                            Group {
                                if row.message == "Last armed", let date = row.lastArmed {
                                    Text("Last armed \(date.formatted(date: .abbreviated, time: .shortened))")
                                } else {
                                    Text(row.message)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("No names, paths or conversation content are sent. Last armed is when a watcher was handed off, not proof of delivery; watchers expire after 24 hours, and hosts that weren't connected aren't covered.")
            }
        }
    }

    /// Turning an alert on asks for permission first and stays off if it isn't given.
    private func binding(_ key: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding {
            settings[keyPath: key]
        } set: { on in
            guard on else { settings[keyPath: key] = false; return }
            Task {
                let allowed = await model.requestNotifications()
                denied = !allowed
                settings[keyPath: key] = allowed
            }
        }
    }
}

/// Exactly what alerts while away send, and to whom.
private struct PushDisclosure: View {
    var body: some View {
        Form {
            Section("On Your Computer") {
                Text("As Herdwick leaves the screen, it starts a small watcher on each connected computer over SSH. The watcher waits on herdr without polling, stops when you come back and exits on its own after a day. It installs nothing that lasts.")
            }
            Section("What Is Sent") {
                Text("When an agent needs you or finishes, the watcher sends this iPhone's notification token, the ids of the computer, session and pane, the new state and a change number. Never a name, a path or anything an agent wrote.")
            }
            Section("The Relay") {
                Text("The relay hands that to Apple's push service and keeps nothing: no storage, no logs. This iPhone fills in the names it already knows.")
                Link("Relay Source Code", destination: URL(string: "https://github.com/btuckerc/herdwick/blob/main/relay/src/index.js")!)
            }
        }
        .navigationTitle("Alerts While Away")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The detail levels as menu items, each with a subtitle. A Picker can't carry subtitles in a
/// menu (its tag spreads to every Text), but a Toggle's label can.
struct DetailLevelOptions: View {
    @Binding var selection: DetailLevel

    static func title(_ level: DetailLevel) -> String {
        switch level {
        case .full: "Full"
        case .folded: "Folded"
        case .digest: "Digest"
        }
    }

    var body: some View {
        option(.full, "Every step, expanded")
        option(.folded, "Steps grouped")
        option(.digest, "Messages and turning points")
    }

    private func option(_ level: DetailLevel, _ subtitle: String) -> some View {
        Toggle(isOn: Binding(get: { selection == level }, set: { if $0 { selection = level } })) {
            Text(Self.title(level))
            Text(subtitle)
        }
    }
}

private struct ThemePicker: View {
    @Binding var selection: String
    let dark: Bool

    var body: some View {
        List {
            ForEach(TerminalTheme.all.filter { $0.isDark == dark } + TerminalTheme.all.filter { $0.isDark != dark }) { theme in
                Button {
                    selection = theme.id
                } label: {
                    HStack(spacing: 14) {
                        ThemeSwatch(theme: theme)
                        Text(theme.name).foregroundStyle(.primary)
                        Spacer()
                        if theme.id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
        }
        .navigationTitle(dark ? "Dark Theme" : "Light Theme")
    }
}

private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: theme.ansi[index])).frame(width: 6, height: 18)
            }
        }
        .padding(6)
        .background(theme.backgroundColor, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

/// A static sample so theme and font changes are visible without a connection.
private struct TerminalPreview: View {
    @Environment(Settings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = settings.theme(for: colorScheme)
        let font = Font(settings.font.uiFont(size: settings.fontSize))
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Text("~/src/herdwick ").foregroundStyle(Color(hex: theme.ansi[4])))\(Text("main").foregroundStyle(Color(hex: theme.ansi[5])))")
            Text("❯ swift test").foregroundStyle(theme.foregroundColor)
            Text("\(Text("✔ ").foregroundStyle(Color(hex: theme.ansi[2])))\(Text("28 tests passed").foregroundStyle(theme.foregroundColor))")
            Text("\(Text("! ").foregroundStyle(Color(hex: theme.ansi[3])))\(Text("agent needs approval").foregroundStyle(theme.foregroundColor))")
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.backgroundColor)
    }
}

private struct Acknowledgements: View {
    var body: some View {
        List {
            Section {
                Text("SwiftTerm, © Miguel de Icaza, MIT License")
                Text("SwiftNIO, SwiftNIO SSH and Swift Crypto, © Apple Inc., Apache License 2.0")
                Text("TailscaleKit (libtailscale), © Tailscale Inc & AUTHORS, BSD 3-Clause License")
            } footer: {
                Text("herdr is © its authors. Herdwick is an independent client.")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

/// Edit or remove a saved host.
struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: HostProfile
    @State private var address = ""
    @State private var password = ""
    @State private var confirmDelete = false
    @State private var confirmForgetKey = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $profile.name)
            }
            Section("Connection") {
                switch profile.route {
                case .direct:
                    TextField("Address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                case .tailnet(_, let name, _):
                    LabeledContent("Tailscale machine", value: name)
                }
                TextField("Username", text: $profile.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Sign in with", selection: $profile.auth) {
                    ForEach(HostProfile.Auth.allCases.filter { $0 != .tailscaleSSH || profile.isTailnet }) { Text($0.label).tag($0) }
                }
                if profile.auth == .password {
                    SecureField("New password (leave empty to keep)", text: $password)
                }
            }
            if let link = model.connections.first(where: { $0.profile.id == profile.id }), !link.missingIntegrations.isEmpty {
                Section {
                    IntegrationOffer(connection: link)
                } header: {
                    Text("Integrations")
                } footer: {
                    Text("Lets Herdwick open these agents' conversations and see when they're working, waiting for you or idle. Agents you don't use don't need one.")
                }
            }
            Section {
                Button("Forget Pinned Host Key…", role: .destructive) { confirmForgetKey = true }
                    .confirmationDialog("Forget the pinned host key?", isPresented: $confirmForgetKey, titleVisibility: .visible) {
                        Button("Forget Key", role: .destructive) { Keychain.delete(profile.hostKeyAccount) }
                    } message: {
                        Text("The next connection trusts whatever key the host presents, including an impostor's.")
                    }
            } footer: {
                Text("The next connection trusts whatever key the host presents.")
            }
            Section {
                Button("Remove Host", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(profile.name)
        .onAppear {
            if case .direct(let host, let port) = profile.route { address = port == 22 ? host : "\(host):\(port)" }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(profile.username.isEmpty)
            }
        }
        .confirmationDialog("Remove \(profile.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.delete(profile.id)
                dismiss()
            }
        }
    }

    private func save() {
        if case .direct = profile.route, let parsed = HostAddress.parse(address) {
            profile.route = .direct(host: parsed.host, port: parsed.port ?? 22)
        }
        if profile.auth == .password, !password.isEmpty {
            Keychain.set(password, for: profile.passwordAccount)
        }
        model.update(profile)
        dismiss()
    }
}

/// Text the composer's + menu inserts. Nothing here is sent until you send it.
private struct SnippetsEditor: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach($settings.snippets) { $snippet in
                    VStack(alignment: .leading) {
                        TextField("Title", text: $snippet.title).font(.headline)
                        TextField("Text", text: $snippet.text, axis: .vertical).lineLimit(1...6)
                    }
                }
                .onDelete { settings.snippets.remove(atOffsets: $0) }
                .onMove { settings.snippets.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Snippet", systemImage: "plus") { settings.snippets.append(Snippet(title: "", text: "")) }
            } footer: {
                Text("Inserted from the + menu next to the message field.")
            }
        }
        .navigationTitle("Snippets")
        .toolbar { EditButton() }
    }
}

/// A named agent start: its kind plus arguments passed exactly as written, one per line.
private struct PresetsEditor: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach($settings.launchPresets) { $preset in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $preset.name).font(.headline)
                        Picker("Agent", selection: $preset.kind) {
                            ForEach(["omp", "claude", "codex"], id: \.self) { Text(agentKindLabel($0)).tag($0) }
                        }
                        TextField("Arguments, one per line", text: Binding {
                            preset.arguments.joined(separator: "\n")
                        } set: {
                            preset.arguments = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        }, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                .onDelete { settings.launchPresets.remove(atOffsets: $0) }
                .onMove { settings.launchPresets.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Preset", systemImage: "plus") {
                    settings.launchPresets.append(LaunchPreset(name: "", kind: "omp", arguments: []))
                }
            } footer: {
                Text("Arguments go to the agent exactly as written, one per line, with no shell in between: no quoting, variables or globs. Blank lines are ignored.")
            }
        }
        .navigationTitle("Launch Presets")
        .toolbar { EditButton() }
    }
}
