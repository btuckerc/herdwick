import HerdrAPI
import SafariServices
import SwiftUI

/// First run: pick how to reach the computer running herdr.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    @State private var path: [HostChoices.Choice] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(.tint)
                            .padding(22)
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                        Text("Herdwick")
                            .font(.largeTitle.bold())
                        Text("Your herdr agents, from anywhere.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                    HostChoices()
                    Button("No machine handy? Explore a demo host") { model.startDemo() }
                        .font(.subheadline.weight(.medium))
                    Text("Herdwick runs herdr's own commands over SSH. Nothing is installed on your computer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationDestination(for: HostChoices.Choice.self) { choice in
                switch choice {
                case .tailscale: TailscaleSetupView()
                case .direct: DirectHostForm()
                }
            }
        }
        .onChange(of: demo?.launch?.scene, initial: true) { _, scene in if scene == .tailscale { path = [.tailscale] } }
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
        GlassEffectContainer(spacing: 14) {
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
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
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
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
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

    var body: some View {
        Section {
            Text(DeviceKey.authorizedKeysLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
            Button(copied ? "Copied" : "Copy Setup Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = "mkdir -p ~/.ssh && echo '\(DeviceKey.authorizedKeysLine)' >> ~/.ssh/authorized_keys"
                copied = true
            }
            ShareLink(item: DeviceKey.authorizedKeysLine) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
        } header: {
            Text("This iPhone's key")
        } footer: {
            Text("Run the setup command once on the computer, e.g. over SSH or in a terminal there. The private key never leaves this iPhone.")
        }
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
                        Button("Continue in Browser") { loginURL = url }.buttonStyle(.glassProminent)
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
                    Button("Try Again") { tailnet.start() }.buttonStyle(.glassProminent)
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
            Button("Sign In with Tailscale") { tailnet.start() }.buttonStyle(.glassProminent)
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
                    ProgressView("Signing in…")
                case .confirming(let confirmation):
                    confirmationView(confirmation)
                case .installing:
                    ProgressView("Installing this iPhone's key…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Setup failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { setup.retry() }.buttonStyle(.glassProminent)
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
            Text("The password worked. Install this iPhone's key so future connections do not need the password.")
            Button("Install this iPhone's key") { setup.install() }
                .buttonStyle(.glassProminent)
            Button("Keep using password") {
                setup.keepPassword()
            }
            .buttonStyle(.glass)
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
