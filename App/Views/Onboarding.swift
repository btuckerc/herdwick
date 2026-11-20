import HerdrAPI
import SafariServices
import SwiftUI

/// First run: pick how to reach the computer running herdr.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    @State private var path: [HostChoices.Choice] = []
    @State private var setupURL: URL?

    var body: some View {
        NavigationStack(path: $path) {
            // The actions sit at the screen's foot, in thumb reach (round 41: opus#3, both actions
            // in the top 60 % over an empty black 40 %), the hero and sample centred in the room
            // above them (round 42: sa#8, opus#3, top-aligned they left the empty band between).
            // Taller than the screen, at accessibility sizes, it scrolls as one column.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: Tokens.Space.m) {
                                HerdMark(size: 60, mood: .working)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Herdwick")
                                        .font(.largeTitle.bold())
                                    Text("Your coding agents, in your pocket.")
                                        .font(.subheadline)
                                        .foregroundStyle(Tokens.secondaryText)
                                }
                            }
                            SampleAsk()
                                .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Tokens.Space.s)
                        Spacer(minLength: 0)
                        VStack(spacing: Tokens.Space.m) {
                            NavigationLink {
                                connectionSetup
                            } label: {
                                Text("Connect a Computer")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryAction()
                            .controlSize(.large)
                            Button { model.startDemo() } label: {
                                Text("Explore a Demo Host").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            Text("Herdwick connects to herdr over SSH and installs nothing.")
                                .font(.footnote)
                                .foregroundStyle(Tokens.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                    .frame(minHeight: proxy.size.height)
                }
            }
            .navigationDestination(for: HostChoices.Choice.self) { choice in
                switch choice {
                case .tailscale: TailscaleSetupView()
                case .direct: DirectHostForm()
                }
            }
        }
        .sheet(item: $setupURL) { url in SafariView(url: url).ignoresSafeArea() }
        .onChange(of: demo?.launch?.scene, initial: true) { _, scene in if scene == .tailscale { path = [.tailscale] } }
    }

    private var connectionSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect the computer that runs herdr")
                    .font(.headline)
                step(1, "Install herdr on your Mac or Linux machine.", detail: "It keeps your Claude Code, Codex and omp agents in terminal tabs.")
                Button("How to Set Up herdr") { setupURL = URL(string: "https://herdr.dev") }
                    .inlineAction()
                    .padding(.leading, 34)
                step(2, "Connect to it here.", detail: "Over SSH, running only herdr's own commands. Herdwick installs nothing.")
                HostChoices()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A numbered step: its number in a tinted circle, what to do, then why in secondary text.
    private func step(_ number: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.18), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Tokens.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(number): \(title) \(detail)")
        }
    }
}

/// What Herdwick is for, shown rather than listed (round 7: three generic symbol-and-text
/// bullets): an agent asking to run a command, as an inbox row says it, with the thread's
/// Approve and Deny. They work on the sample: the receipt replaces them and the agent goes back
/// to work, then after a beat it asks again. Under it the rest of a small herd, one at work and
/// one done, as the inbox lists them (round 50: sa#14, opus#12: one card under an empty band
/// didn't say the app watches many agents).
private struct SampleAsk: View {
    @Environment(Settings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answer: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let status: AgentStatus = answer == nil ? .blocked : .working
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            // Labelled, so the sample doesn't read as a real agent asking (round 8).
            Label("Try it · a sample inbox", systemImage: "hand.tap")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tokens.secondaryText)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.25), isActive: answer != nil && !reduceMotion)
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Fix flaky retry test").font(.body.weight(.semibold))
                        Spacer(minLength: 4)
                        Text("now").font(.footnote).foregroundStyle(Tokens.secondaryText)
                    }
                    Text("\(status.label) · studio").font(.subheadline).foregroundStyle(Tokens.secondaryText)
                        .contentTransition(.interpolate)
                    Text("Allow bash?").font(.subheadline)
                    PendingCommand(command: "bun test src/retry.test.ts", mayBeCut: false)
                }
            }
            .accessibilityElement(children: .combine)
            if let answer {
                Label(answer == "Approved" ? "Approved · it's running the tests" : "Denied · it'll find another way",
                      systemImage: answer == "Approved" ? "checkmark.shield" : "xmark.shield")
                    .font(.footnote)
                    .foregroundStyle(Tokens.secondaryText)
                    .frame(minHeight: Tokens.minTap)
                    .transition(.opacity)
            } else {
                HStack(spacing: Tokens.Space.s) {
                    Button { choose("Approved") } label: {
                        Text("Approve").frame(maxWidth: .infinity, minHeight: Tokens.minTap)
                    }
                    .primaryAction(.roundedRectangle(radius: Tokens.Radius.choice))
                    Button { choose("Denied") } label: {
                        Text("Deny").frame(maxWidth: .infinity, minHeight: Tokens.minTap)
                    }
                    .choiceButton()
                    // Its own width beside Approve, as the inbox and thread size it (round 60: opus#6).
                    .frame(minWidth: 96)
                    .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
                }
                .font(.body.weight(.medium))
                .transition(.opacity)
            }
            // The rest of the herd; at accessibility sizes the ask alone, kept above the fold.
            if !typeSize.isAccessibilitySize {
                Divider()
                herdRow(.working, title: "Token-bucket rate limiter", detail: "Working · api", age: "for 2m",
                        spoken: "Token-bucket rate limiter, api, Working, working since 2 minutes ago")
                Divider()
                herdRow(.done, title: "Review PR #412", detail: "No blocking findings in PR #412.", age: "45m ago",
                        spoken: "Review PR #412, Done, last turn 45 minutes ago, No blocking findings in PR #412.")
            }
        }
        .padding(Tokens.Space.l)
        .background(Tokens.Surface.raised, in: .rect(cornerRadius: Tokens.Radius.card))
        .sensoryFeedback(.success, trigger: answer) { _, new in new != nil && settings.haptics }
        .task(id: answer) {
            guard answer != nil else { return }
            // As long as the inbox's Undo with VoiceOver or at accessibility sizes (round 42:
            // sb#15, 3 s for everyone, so the receipt went before it was read).
            let long = UIAccessibility.isVoiceOverRunning || typeSize.isAccessibilitySize
            try? await Task.sleep(for: .seconds(long ? 12 : 3))
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth) { answer = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample inbox, try it")
    }

    private func choose(_ verdict: String) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) { answer = verdict }
        AccessibilityNotification.Announcement(verdict).post()
    }

    /// One of the sample's other agents, as an inbox row: glyph, title and age, then a grey line;
    /// heard as the inbox's rows are, status and age in words (round 51: sb#8, "45m" and no Done).
    private func herdRow(_ status: AgentStatus, title: String, detail: String, age: String, spoken: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.25), isActive: status == .working && !reduceMotion)
                .frame(minWidth: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.body)
                    Spacer(minLength: 4)
                    Text(age).font(.footnote).foregroundStyle(Tokens.secondaryText)
                }
                Text(detail).font(.subheadline).foregroundStyle(Tokens.secondaryText).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// Adding another host later, from the host menu.
struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { HostChoices().padding() }
                .navigationTitle("Add Host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                }
                .navigationDestination(for: HostChoices.Choice.self) { choice in
                    switch choice {
                    case .tailscale: TailscaleSetupView(onDone: { dismiss() })
                    case .direct: DirectHostForm(onDone: { dismiss() })
                    }
                }
        }
    }
}

struct HostChoices: View {
    enum Choice: Hashable { case tailscale, direct }

    var body: some View {
        VStack(spacing: 14) {
            NavigationLink(value: Choice.tailscale) {
                ChoiceCard(
                    symbol: "point.3.filled.connected.trianglepath.dotted",
                    title: "Tailscale",
                    detail: "Sign in once and pick a machine. Works anywhere, with no VPN to switch on.",
                    badge: "Recommended"
                )
            }
            NavigationLink(value: Choice.direct) {
                ChoiceCard(
                    symbol: "network",
                    title: "Address",
                    detail: "An IP, hostname or URL this iPhone can already reach.",
                    badge: nil
                )
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    let badge: String?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.raised, in: .rect(cornerRadius: Tokens.Radius.card))
        .contentShape(.rect)
    }
}

// MARK: Direct address

struct DirectHostForm: View {
    @Environment(AppModel.self) private var model
    var onDone: (() -> Void)?

    @State private var address = ""
    @State private var username = ""
    @State private var name = ""
    @State private var auth: HostProfile.Auth = .password
    @State private var password = ""
    @State private var keySetup = KeySetup()

    private var parsed: HostAddress? { HostAddress.parse(address) }

    var body: some View {
        Form {
            Section {
                TextField("mac.local, 100.64.0.2, ssh://me@box:2222", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: address) {
                        if let user = parsed?.user, username.isEmpty { username = user }
                    }
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Computer running herdr")
            } footer: {
                if !address.isEmpty, parsed == nil {
                    Text("That isn't a hostname, IP or URL Herdwick can use.").foregroundStyle(.red)
                } else if let port = parsed?.port {
                    Text("SSH port \(String(port)).")
                }
            }

            Section {
                Picker("Method", selection: $auth) {
                    Text(HostProfile.Auth.password.label).tag(HostProfile.Auth.password)
                    Text(HostProfile.Auth.deviceKey.label).tag(HostProfile.Auth.deviceKey)
                }
                .pickerStyle(.segmented)
                if auth == .password {
                    SecureField("Password", text: $password)
                }
            } header: {
                Text("Sign in with")
            } footer: {
                Text(auth == .password
                     ? "Recommended: sign in once, then install this iPhone's key without saving the password."
                     : "Copy this iPhone's key to the computer manually.")
            }
            if auth == .deviceKey {
                AuthorizedKeySection()
            }

            Section {
                TextField("Name (optional)", text: $name)
            }
        }
        .navigationTitle("Address")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect", action: save)
                    .disabled(parsed == nil || username.isEmpty || (auth == .password && password.isEmpty))
            }
        }
        .sheet(isPresented: Binding(get: { keySetup.isPresented }, set: { if !$0 { keySetup.dismiss() } })) {
            KeySetupSheet(setup: keySetup) { profile in
                model.add(profile)
                onDone?()
            }
        }
    }

    private func save() {
        guard let parsed else { return }
        let profile = HostProfile(
            name: name.isEmpty ? parsed.host : name,
            route: .direct(host: parsed.host, port: parsed.port ?? 22),
            username: username,
            auth: auth
        )
        if auth == .password {
            keySetup.begin(profile: profile, password: password, tailnet: model.tailnet)
            // KeySetup holds it now. A filled secure field that disappears makes iOS offer to
            // save it in Passwords; this path promises nothing keeps it.
            password = ""
        } else {
            model.add(profile)
            onDone?()
        }
    }
}

/// The public key to authorise, with a ready-to-run command.
struct AuthorizedKeySection: View {
    @State private var copied = false
    @State private var publicKey: String?
    @State private var keyError: String?

    var body: some View {
        Section {
            if let publicKey {
                Text(publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button(copied ? "Copied" : "Copy Setup Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = "mkdir -p ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys"
                    copied = true
                }
                ShareLink(item: publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
            } else if let keyError {
                Text(keyError).foregroundStyle(.secondary)
                Button("Try Again", action: loadKey)
            } else {
                ProgressView()
            }
        } header: {
            Text("This iPhone's key")
        } footer: {
            Text("Run the setup command once on the computer. The private key never leaves this iPhone.")
        }
        .task { loadKey() }
    }

    private func loadKey() {
        do { publicKey = try DeviceKey.authorizedKeysLine; keyError = nil }
        catch { keyError = error.localizedDescription }
    }
}

// MARK: Tailscale

struct TailscaleSetupView: View {
    @Environment(Tailnet.self) private var tailnet
    var onDone: (() -> Void)?

    @State private var loginURL: URL?
    @State private var search = ""

    var body: some View {
        Group {
            switch tailnet.state {
            case .off:
                intro
            case .starting:
                ContentUnavailableView { ProgressView() } description: { Text("Starting Tailscale…") }
            case .needsLogin(let url):
                ContentUnavailableView {
                    Label("Approve this iPhone", systemImage: "person.badge.key")
                } description: {
                    Text("Sign in to your tailnet in the browser. Herdwick joins it as its own device.")
                } actions: {
                    if let url {
                        Button("Continue in Browser") { loginURL = url }.primaryAction()
                    } else {
                        ProgressView()
                    }
                }
                .onChange(of: url, initial: true) { _, url in if loginURL == nil { loginURL = url } }
            case .running:
                peers
            case .failed(let message):
                ContentUnavailableView {
                    Label("Tailscale didn't start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { tailnet.start() }.primaryAction()
                }
            }
        }
        .navigationTitle("Tailscale")
        .sheet(item: $loginURL) { url in SafariView(url: url).ignoresSafeArea() }
        .onChange(of: tailnet.state) { _, state in if state == .running { loginURL = nil } }
        .onAppear { if tailnet.state != .off { tailnet.refreshSoon() } }
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Connect with Tailscale", systemImage: "point.3.filled.connected.trianglepath.dotted")
        } description: {
            Text("Herdwick has Tailscale built in. It reaches your machines directly, even when the Tailscale app is off or not installed.")
        } actions: {
            Button("Sign In with Tailscale") { tailnet.start() }.primaryAction()
        }
    }

    private var peers: some View {
        List {
            if let name = tailnet.tailnetName {
                Section { LabeledContent("Tailnet", value: name) }
            }
            Section("Machines") {
                ForEach(filtered) { peer in
                    NavigationLink {
                        PeerForm(peer: peer, onDone: onDone)
                    } label: {
                        HStack {
                            Circle().fill(peer.online ? .green : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(peer.name)
                                Text(peer.dnsName.isEmpty ? peer.address : peer.dnsName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !peer.sshHostKeys.isEmpty {
                                Image(systemName: "lock.shield").foregroundStyle(.secondary).accessibilityLabel("Tailscale SSH available")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Machines")
        .refreshable { tailnet.refreshSoon() }
    }

    private var filtered: [Tailnet.Peer] {
        search.isEmpty ? tailnet.peers : tailnet.peers.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.dnsName.localizedCaseInsensitiveContains(search) }
    }
}

private struct PeerForm: View {
    @Environment(AppModel.self) private var model
    let peer: Tailnet.Peer
    var onDone: (() -> Void)?
    @State private var username = ""
    @State private var password = ""
    @State private var auth: HostProfile.Auth
    @State private var keySetup = KeySetup()

    init(peer: Tailnet.Peer, onDone: (() -> Void)? = nil) {
        self.peer = peer
        self.onDone = onDone
        _auth = State(initialValue: peer.sshHostKeys.isEmpty ? .password : .tailscaleSSH)
    }

    var body: some View {
        Form {
            Section {
                TextField("Username on \(peer.name)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if auth == .password {
                    SecureField("Password", text: $password)
                }
            } footer: {
                Text("The account that runs herdr on \(peer.name).")
            }
            Section {
                Picker("Sign in with", selection: $auth) {
                    // Short labels: three segments don't fit the long ones.
                    if !peer.sshHostKeys.isEmpty {
                        Text("Tailscale").tag(HostProfile.Auth.tailscaleSSH)
                    }
                    Text("Password").tag(HostProfile.Auth.password)
                    Text("Key").tag(HostProfile.Auth.deviceKey)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(footer)
            }
            if auth == .deviceKey { AuthorizedKeySection() }
        }
        .navigationTitle(peer.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect", action: save).disabled(username.isEmpty || (auth == .password && password.isEmpty))
            }
        }
        .sheet(isPresented: Binding(get: { keySetup.isPresented }, set: { if !$0 { keySetup.dismiss() } })) {
            KeySetupSheet(setup: keySetup) { profile in
                model.add(profile)
                onDone?()
            }
        }
        .onChange(of: peer.sshHostKeys) { _, keys in
            if keys.isEmpty, auth == .tailscaleSSH { auth = .password }
        }
    }

    private var footer: String {
        switch auth {
        case .tailscaleSSH: "Uses Tailscale SSH; it is enabled on this machine."
        case .password: "Recommended: sign in once, then install this iPhone's key without saving the password."
        case .deviceKey: "Copy this iPhone's key to the computer manually."
        }
    }

    private func save() {
        let profile = HostProfile(
            name: peer.name,
            route: .tailnet(nodeID: peer.id, name: peer.dnsName.isEmpty ? peer.name : peer.dnsName, address: peer.address),
            username: username,
            auth: auth
        )
        if auth == .password {
            keySetup.begin(profile: profile, password: password, tailnet: model.tailnet)
            password = ""
        } else {
            model.add(profile)
            onDone?()
        }
    }
}

private struct KeySetupSheet: View {
    let setup: KeySetup
    let onDone: (HostProfile) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch setup.state {
                case .idle, .connecting:
                    ProgressView("Checking the server…")
                case .confirming(let confirmation):
                    confirmationView(confirmation)
                case .signingIn:
                    ProgressView("Signing in…")
                case .installing:
                    ProgressView("Installing this iPhone's key…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Setup failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { setup.retry() }.primaryAction()
                    }
                case .finished:
                    // Nothing left to decide: add the host and let the inbox take over.
                    ProgressView("Connecting…")
                        .onAppear { if let profile = setup.result { onDone(profile) } }
                }
            }
            .padding()
            .navigationTitle("Secure sign-in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { setup.dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(setup.isInstalling)
    }

    private func confirmationView(_ confirmation: KeySetup.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trust this server?").font(.title2.bold())
            Text(confirmation.address).font(.headline)
            Text("Host key fingerprint").font(.subheadline).foregroundStyle(.secondary)
            Text(confirmation.fingerprint).font(.body.monospaced()).textSelection(.enabled)
            Text(confirmation.advertised
                 ? "Your tailnet vouches for this key. Your password is sent only after you continue."
                 : "Compare it with the server's own (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). Your password is sent only after you continue.")
                .foregroundStyle(.secondary)
            Text("Install this iPhone's key so future connections do not need the password.")
            VStack(spacing: 8) {
                Button { setup.install() } label: {
                    Text("Install This iPhone's Key").frame(maxWidth: .infinity)
                }
                .primaryAction()
                Button { setup.keepPassword() } label: {
                    Text("Keep Using Password").frame(maxWidth: .infinity)
                }
                .floatingControl()
            }
            .controlSize(.large)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
