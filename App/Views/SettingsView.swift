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

                Section {
                    Picker("Detail", selection: $settings.detailLevel) {
                        Text("Full").tag(DetailLevel.full)
                        Text("Folded").tag(DetailLevel.folded)
                        Text("Digest").tag(DetailLevel.digest)
                    }
                    Toggle("Show Working Subagents", isOn: $settings.showWorkingSubagents)
                } header: {
                    Text("Conversations")
                } footer: {
                    Text("Full expands every step. Folded groups steps. Digest keeps messages and turning points. Show Working Subagents pins subagents that are still running above the conversation; finished ones move into it.")
                }


                Section {
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
                } header: {
                    Text("Inbox")
                } footer: {
                    Text("Choose the inbox view, host scope, grouping, sort order, and whether read idle agents are folded.")
                }
                NotificationSettings()
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
                } footer: {
                    Text("A tap when a message is delivered and a warning when an agent needs you.")
                }

                Section {
                    Toggle("Autocorrect Messages", isOn: $settings.composerAutocorrect)
                    Toggle("On-screen Return Sends", isOn: $settings.returnKeySends)
                } footer: {
                    Text("Autocorrect is off by default to keep commands exactly as typed. With a hardware keyboard, Return and ⌘Return always send; ⇧Return or ⌥Return adds a line.")
                }
                Section {
                    Picker("Keep Uploads", selection: $settings.attachmentRetention) {
                        ForEach(AttachmentRetention.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Uploads go to the host's temporary folder. omp, Claude Code and Codex copy images into their own history when sent, so these are swept after this long.")
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
                } footer: {
                    if model.profiles.count > 1 { Text("Touch and hold a host to drag it into a new order. Swipe the title to move between them.") }
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
        } footer: {
            Text("Alerts come while Herdwick is open, or when iOS lets it check in the background, which can be late. Needs You also badges the app icon. Opening a finished agent, at its latest message, marks it read.")
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
            } footer: {
                Text("While Herdwick is closed, your computers send these alerts on time through Herdwick's push relay. Nothing but ids leaves them.")
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
            Section {
                Button("Forget Pinned Host Key") { Keychain.delete(profile.hostKeyAccount) }
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
