import HerdrAPI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(Tailnet.self) private var tailnet
    @Environment(\.dismiss) private var dismiss
    @State private var addingHost = false

    var body: some View {
        NavigationStack {
            // iOS order: the hosts (Settings' account row) and how to reach them, then what's used
            // daily, then look, then About. The root is a short list of pages, like Settings; rows
            // are names, and what a name doesn't say sits behind ⓘ on its page.
            Form {
                Section("Hosts") {
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            HostEditor(profile: profile)
                        } label: {
                            // Stacked for every host: LabeledContent sets a short name's address
                            // beside it and a long one's below, so the list zigzags.
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                    Text(profile.address).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if !profile.isEnabled {
                                    Spacer()
                                    Text("Off").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(profile.isEnabled ? "Turn Off" : "Turn On") {
                                model.setEnabled(!profile.isEnabled, for: profile.id)
                            }
                            .tint(profile.isEnabled ? .orange : .green)
                        }
                    }
                    .onMove { model.moveProfiles(from: $0, to: $1) }
                    Button("Add Host…", systemImage: "plus") { addingHost = true }
                }

                Section {
                    NavigationLink { KeySettings() } label: { SettingsLabel("SSH Key", symbol: "key") }
                    if tailnet.state == .off {
                        SettingsLabel("Tailscale", symbol: "point.3.connected.trianglepath.dotted", value: "Off")
                    } else {
                        NavigationLink { TailscaleSettings() } label: {
                            SettingsLabel("Tailscale", symbol: "point.3.connected.trianglepath.dotted", value: tailscaleStatus)
                        }
                    }
                    // The page's state on its row, as Settings shows Wi-Fi's network (round 95:
                    // opus#14, three chevrons gave no hint of what was set behind them).
                    NavigationLink { NotificationSettings() } label: {
                        SettingsLabel("Notifications", symbol: "bell.badge",
                                      value: settings.notifyNeedsYou || settings.notifyFinished ? "On" : "Off")
                    }
                    NavigationLink { PrivacySettings() } label: { SettingsLabel("Privacy", symbol: "hand.raised") }
                }

                Section {
                    NavigationLink { ConversationSettings() } label: {
                        SettingsLabel("Conversations", symbol: "bubble.left.and.text.bubble.right")
                    }
                    NavigationLink { ComposerSettings() } label: { SettingsLabel("Composer & Dictation", symbol: "keyboard") }
                    NavigationLink { AppearanceSettings() } label: {
                        SettingsLabel("Appearance & Terminal", symbol: "paintbrush", value: settings.appearance.label)
                    }
                }

                Section {
                    // Says where it goes and that it leaves the app, as an outbound row should
                    // (round 55: opus#13, sa#15, a bare green "herdr" read as a stray link).
                    Link(destination: URL(string: "https://herdr.dev")!) {
                        LabeledContent("herdr Website") {
                            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(Color.primary)
                    }
                    .accessibilityHint("Opens herdr.dev in Safari")
                    NavigationLink("Acknowledgements") { Acknowledgements() }
                } header: {
                    Text("About")
                } footer: {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // The close button every browsing sheet has, top trailing; settings save as they
            // change, so there's nothing to confirm (round 81: opus#8, Done here, an X elsewhere).
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() } }
            }
            .sheet(isPresented: $addingHost) { AddHostView() }
        }
    }

    private var tailscaleStatus: String {
        switch tailnet.state {
        case .running: tailnet.tailnetName ?? "On"
        case .off: "Off"
        default: "Starting…"
        }
    }
}

/// A monochrome symbol in a fixed column, the setting's name, and an optional value.
private struct SettingsLabel: View {
    let title: String
    let symbol: String
    var value: String?
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    init(_ title: String, symbol: String, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
            if let value {
                Spacer(minLength: Tokens.Space.s)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// How threads read and what the inbox shows of them. Grouping, order and idle folding live in
/// the inbox's View menu, where their effect is in sight.
private struct ConversationSettings: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: $settings.inboxPreviews) {
                    InfoLabel("Message Previews", info: "Shows a line of each agent's newest message in the inbox and the dock. Search finds it either way.")
                }
            }
            Section {
                SettingsMenuRow("Thread View", value: DetailLevelOptions.title(settings.detailLevel)) {
                    DetailLevelOptions(selection: $settings.detailLevel)
                }
                Toggle("Agent Dock", isOn: $settings.showsDock)
                NavigationLink("Launch Presets") { PresetsEditor() }
            }
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ComposerSettings: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Composer") {
                Toggle("Autocorrect", isOn: $settings.composerAutocorrect)
                Toggle("On-screen Return Sends", isOn: $settings.returnKeySends)
                NavigationLink("Snippets") { SnippetsEditor() }
                SettingsMenuRow("Keep Uploads", value: settings.attachmentRetention.label,
                                info: "Expired uploads are removed from the host at your next upload.") {
                    Picker("Keep Uploads", selection: $settings.attachmentRetention) {
                        ForEach(AttachmentRetention.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            Section("Dictation") {
                Toggle("Show Live Transcript", isOn: $settings.showsLiveTranscript)
                NavigationLink("Dictionary") { DictionaryEditor() }
            }
        }
        .navigationTitle("Composer & Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettings: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Haptics", isOn: $settings.haptics)
            }
            Section("Terminal") {
                SettingsMenuRow("Font", value: settings.font.label) {
                    Picker("Font", selection: $settings.font) {
                        ForEach(TerminalFont.allCases) { Text($0.label).tag($0) }
                    }
                }
                Stepper(value: $settings.fontSize, in: Settings.fontSizes, step: 1) {
                    LabeledContent("Size", value: "\(Int(settings.fontSize)) pt")
                }
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
                TerminalPreview()
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Appearance & Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// This device's SSH identity: the line to authorize, and replacing it.
private struct KeySettings: View {
    var body: some View {
        Form {
            AuthorizedKeySection()
            Section {
                NavigationLink("Replace Key…") { DeviceKeyReplacement() }
            }
        }
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TailscaleSettings: View {
    @Environment(Tailnet.self) private var tailnet

    var body: some View {
        Form {
            switch tailnet.state {
            case .running:
                Section {
                    if let name = tailnet.tailnetName { LabeledContent("Tailnet", value: name) }
                    LabeledContent("Device", value: "herdwick-\(UIDeviceName.short)")
                }
                Section {
                    Button("Sign Out of Tailscale", role: .destructive) { Task { await tailnet.signOut() } }
                }
            case .off:
                Text("Signed out").foregroundStyle(.secondary)
            default:
                Text("Starting…").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tailscale")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An ⓘ that opens a short explanation, for what a setting's name doesn't say.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More Info")
        .popover(isPresented: $shown) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: 300)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A row title with its ⓘ beside it.
struct InfoLabel: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(info)
        }
    }
}

private struct PrivacySettings: View {
    @Environment(Settings.self) private var settings
    @State private var deletingCopies = false
    @State private var failure: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: $settings.appLock) {
                    InfoLabel("App Lock", info: "Asks for Face ID or your passcode at launch and after 30 seconds away, and hides Herdwick in the app switcher.")
                }
                Toggle(isOn: Binding(get: { settings.offlineTranscripts }, set: { on in
                    if on { settings.offlineTranscripts = true }
                    else { deletingCopies = true }
                })) {
                    InfoLabel("Keep Offline Copies", info: "Up to 20 conversations, at most 4 MB each, protected while your device is locked. Turning this off deletes them.")
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete all offline copies?", isPresented: $deletingCopies) {
            Button("Delete Copies", role: .destructive) {
                do {
                    try TranscriptCache.removeAll()
                    settings.offlineTranscripts = false
                } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
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
        .alert("Permanently remove the old private key?", isPresented: $confirmingRemoval) {
            Button("Remove Old Key", role: .destructive) {
                guard let pending else { return }
                do {
                    try DeviceKey.finishRotation(pending, profiles: model.profiles)
                    self.pending = nil
                    completed = true
                } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
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
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Needs You", isOn: binding(\.notifyNeedsYou))
                Toggle("Done", isOn: binding(\.notifyFinished))
            }
            Section {
                Toggle("Answer from Notifications", isOn: $settings.answerFromNotifications)
            } footer: {
                Text("Approve, deny or reply from an alert or the Lock Screen. Face ID or your passcode is asked first.")
            }
            if denied {
                Section {
                    Link("Allow Notifications in Settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                }
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
                    Text("Last armed is when a watcher was handed off, not proof of delivery. Watchers expire after 24 hours; hosts that weren't connected aren't covered.")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
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

/// The detail levels as checkmarked menu items, named by what a thread then shows, each with
/// what it leaves out (round 16: "Folded" and "Digest" named the mechanism, not the result).
struct DetailLevelOptions: View {
    @Binding var selection: DetailLevel

    static func title(_ level: DetailLevel) -> String {
        switch level {
        case .folded: "Messages and Steps"
        case .digest: "Messages Only"
        }
    }

    static func subtitle(_ level: DetailLevel) -> String {
        switch level {
        case .folded: "Each run of steps on one line"
        case .digest: "Steps only while running or failed"
        }
    }

    var body: some View {
        ForEach(DetailLevel.allCases) { level in
            Toggle(isOn: Binding(get: { selection == level }, set: { if $0 { selection = level } })) {
                Text(Self.title(level))
                Text(Self.subtitle(level))
            }
        }
    }
}

/// A setting chosen from a menu. Not a menu-style Picker: iOS 26 can animate a closing menu's
/// value at its old screen position, so a list scrolled while it closed left the value floating
/// where the row had been (and the row blank) until the morph ended. An identity-glass label in
/// its own container keeps the value in the row. The menu sprouts from its label, so the label is
/// the trailing value alone, as a menu Picker's is.
private struct SettingsMenuRow<Options: View>: View {
    let title: String
    let value: String
    let info: String?
    let options: Options

    init(_ title: String, value: String, info: String? = nil, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        self.info = info
        self.options = options()
    }

    var body: some View {
        LabeledContent {
            GlassEffectContainer {
                Menu {
                    options
                } label: {
                    HStack(spacing: 4) {
                        Text(value)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .foregroundStyle(.secondary)
                    .glassEffect(.identity)
                }
                .tint(.primary)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).accessibilityHidden(true)
                if let info { InfoButton(info) }
            }
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
    @State private var lanAddress = ""
    @State private var confirmDelete = false
    @State private var confirmForgetKey = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Toggle(isOn: $profile.isEnabled) {
                    InfoLabel("Connect", info: "Off keeps the host saved but never connects to it, until you turn it back on.")
                }
            }
            Section {
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
                SettingsMenuRow("Sign in with", value: profile.auth.label) {
                    Picker("Sign in with", selection: $profile.auth) {
                        ForEach(HostProfile.Auth.allCases.filter { $0 != .tailscaleSSH || profile.isTailnet }) { Text($0.label).tag($0) }
                    }
                }
                if profile.auth == .password {
                    SecureField("New password (leave empty to keep)", text: $password)
                }
                if profile.auth != .tailscaleSSH {
                    HStack {
                        TextField("LAN address (optional)", text: $lanAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        InfoButton("On Wi-Fi, the LAN address is tried alongside \(profile.isTailnet ? "Tailscale" : "the address above") and whichever answers first is used. It must present this host's pinned key.")
                    }
                }
            } header: {
                Text("Connection")
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
                Button("Remove Host", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(profile.name)
        .onAppear {
            if case .direct(let host, let port) = profile.route { address = port == 22 ? host : "\(host):\(port)" }
            lanAddress = profile.lanAddress ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(profile.username.isEmpty || !lanAddressValid)
            }
        }
        .alert("Forget the pinned host key?", isPresented: $confirmForgetKey) {
            Button("Forget Key", role: .destructive) { Keychain.delete(profile.hostKeyAccount) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection trusts whatever key the host presents, including an impostor's.")
        }
        .alert("Remove \(profile.name)?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                model.delete(profile.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var lanAddressValid: Bool {
        let trimmed = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || HostAddress.parse(trimmed) != nil
    }

    private func save() {
        let lan = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.lanAddress = lan.isEmpty ? nil : lan
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

/// Words dictation should spell a certain way, and phrases it keeps mishearing, fixed before its
/// words reach the draft.
private struct DictionaryEditor: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("GitHub, PostgreSQL, herdr", text: $settings.dictationTerms, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Known Terms")
            } footer: {
                Text("Names and jargon, separated by commas or lines. Dictation listens for them, and writes them as entered here when it hears them with any capitalization or spacing (\"git hub\", \"R and D\") or, for longer terms, a near miss (\"poster SQL\").")
            }
            Section {
                ForEach($settings.dictationReplacements) { $rule in
                    HStack {
                        TextField("Heard", text: $rule.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Write", text: $rule.write)
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
                .onDelete { settings.dictationReplacements.remove(atOffsets: $0) }
                Button("Add Replacement", systemImage: "plus") {
                    settings.dictationReplacements.append(WordReplacement(heard: "", write: ""))
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("When dictation hears a word or phrase on the left, it writes the right side exactly as entered. Matches whole words, ignoring capitalization and how the words are joined (\"poster SQL\", \"poster-SQL\"); the longest match wins. Applied before known terms. Typed text is never changed.")
            }
        }
        .navigationTitle("Dictation Dictionary")
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
                        SettingsMenuRow("Agent", value: agentKindLabel(preset.kind)) {
                            Picker("Agent", selection: $preset.kind) {
                                ForEach(["omp", "claude", "codex"], id: \.self) { Text(agentKindLabel($0)).tag($0) }
                            }
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
