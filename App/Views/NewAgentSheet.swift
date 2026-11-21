import HerdrAPI
import SwiftUI

/// Where a new agent or terminal opens: a new tab in an existing workspace (herdr gives it
/// the workspace's folder), or a folder that gets a workspace of its own. `nil` is the home folder.
enum NewAgentPlace: Hashable {
    case workspace(String)
    case folder(String?)
}

struct NewAgentTarget: Hashable {
    let host: SessionAddress
    let place: NewAgentPlace
}

/// "+" → Start: the agent opens in its conversation. The workspace defaults to the last one
/// started in, the agent to the last one started; either is one tap to change, and any
/// folder on the host is a few taps away without typing.
struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let links: [HostConnection]
    let onOpen: (Route) -> Void
    let resume: EndedAgent?

    @State private var target: NewAgentTarget?
    @State private var kind: String
    @State private var presetID: LaunchPreset.ID?
    @State private var pages: [Page] = []
    @State private var firstMessage = ""
    /// Up on open, as Mail's compose is: what to work on is what the sheet is for (round 21:
    /// the field waited for a tap under a form with a dead gap above Start).
    @FocusState private var messageFocused: Bool
    /// Start & Send, or Start Without Sending, whichever started the agent.
    @State private var sendsFirstMessage = true
    @State private var showsOptions = false
    @State private var opening: Opening?
    /// The agent or terminal opened and the sheet is leaving: it stays busy through its exit
    /// (round 60: "Start & Send" came back enabled as the sheet slid away).
    @State private var opened = false
    @State private var error: String?
    /// The pane made by a Start whose agent then failed; the next Start reuses it.
    @State private var created: (target: NewAgentTarget, pane: String)?
    @State private var startFlow = AgentStartFlow()
    @State private var newWorktree = false
    @State private var branch = ""
    @State private var originalResumeDestination = true

    enum Page: Hashable {
        case places
        case folders(SessionAddress, String?)
    }

    private enum Opening { case agent, terminal }

    private enum Failure: LocalizedError {
        case workspaceGone, sessionChanged
        var errorDescription: String? {
            switch self {
            case .workspaceGone: "That workspace was closed. Choose another."
            case .sessionChanged: "The host switched herdr sessions, so nothing was opened."
            }
        }
    }

    /// `workspace` preselects a workspace on `preferred`, for "New Agent Here".
    init(links: [HostConnection], preferred: HostConnection?, workspace: String? = nil, resume: EndedAgent? = nil, onOpen: @escaping (Route) -> Void) {
        self.links = links
        self.onOpen = onOpen
        self.resume = resume
        let link = resume.flatMap { item in links.first { $0.profile.id == item.hostID && $0.activeSession == item.session } }
            ?? Self.defaultLink(links, preferred: preferred, contextual: workspace != nil)
        _target = State(initialValue: link.flatMap { link in
            if let resume {
                // Same id and label: herdr reuses ids after a restart. The tab opens in the agent's own
                // folder, which needn't be the workspace's.
                guard link.snapshot?.workspaces.contains(where: {
                    $0.id == resume.workspaceID && $0.label == resume.workspaceLabel
                }) == true else { return nil }
                return NewAgentTarget(host: link.identity, place: .workspace(resume.workspaceID))
            }
            return NewAgentTarget(host: link.identity, place: workspace.map { .workspace($0) } ?? Self.defaultPlace(link))
        })
        _kind = State(initialValue: resume?.harness ?? link?.lastAgentKind ?? "omp")
    }

    private var link: HostConnection? { target.flatMap { target in links.first { $0.identity == target.host } } }
    private var busy: Bool { opening != nil || startFlow.running || opened }
    private var unavailable: Bool {
        busy || link?.isLive != true ||
        (newWorktree && branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack(path: $pages) {
            form
        }
        .presentationDetents([.large])
        .modifier(AgentStartFeedback(flow: startFlow, onStarted: finish))
    }

    @ViewBuilder private var form: some View {
        Form {
            if resume == nil {
                // The message leads, ahead of where and which agent (round 40: sa#10, the place
                // rows and a floating Start left the editor one line above the keyboard).
                Section {
                    // The secondary grey, not the system's placeholder grey (round 19: in the
                    // dark it blended into its field).
                    TextField("First message", text: $firstMessage,
                              prompt: Text("What should it work on?").foregroundStyle(Tokens.secondaryText), axis: .vertical)
                        .lineLimit(4...6)
                        .focused($messageFocused)
                        .onAppear { messageFocused = true }
                    // Under the message it keeps (round 65: sa#10, a detached row two sections
                    // down, apart from the words it qualifies).
                    if hasMessage { startWithoutSending }
                } header: {
                    Text("First Message")
                } footer: {
                    // What happens to it, not which button does what (round 23: the footer
                    // repeated both buttons' labels).
                    Text(hasMessage ? "Sent when the agent is ready; Start Without Sending keeps it as a draft." : "Optional. Sent when the agent is ready.")
                }
            }
            Section {
                if model.demo != nil {
                    demoHostRow
                    placeRow
                } else {
                    NavigationLink(value: Page.places) { placeRow }
                }
                if let resume {
                    LabeledContent("Resume", value: resume.title)
                } else {
                    Picker(selection: $kind) {
                        ForEach(startableAgentKinds, id: \.self) { Text(agentKindLabel($0)).tag($0) }
                    } label: {
                        Label("Agent", systemImage: "sparkles")
                    }
                    .onChange(of: kind) { if preset?.kind != kind { presetID = nil } }
                }
            } footer: {
                Text(footer)
            }
            if resume == nil, model.demo == nil {
                Section { openTerminal }
            }
            if resume == nil {
                Section {
                    DisclosureGroup("Options", isExpanded: $showsOptions) {
                        if !settings.launchPresets.isEmpty {
                            Picker(selection: $presetID) {
                                Text("None").tag(LaunchPreset.ID?.none)
                                ForEach(settings.launchPresets) { Text($0.name).tag(Optional($0.id)) }
                            } label: {
                                Label("Preset", systemImage: "slider.horizontal.3")
                            }
                            .onChange(of: presetID) { if let preset { kind = preset.kind } }
                        }
                        if model.demo == nil, case .workspace = target?.place {
                            Toggle("New Worktree", isOn: $newWorktree)
                                .onChange(of: newWorktree) { created = nil }
                            if newWorktree {
                                TextField("New branch (base: HEAD)", text: $branch)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .onChange(of: branch) { created = nil }
                            }
                        }
                    }
                }
            }
            if model.demo == nil, let link { Section { IntegrationOffer(connection: link, harness: kind) } }
            if let link, !link.isLive {
                Section {
                    Button("Reconnect", systemImage: "arrow.clockwise") { Task { await link.refreshSessions(explicit: true) } }
                } footer: {
                    Text(link.statusText ?? "Not connected")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        // A drag down the form puts the keyboard away, so every row stays reachable.
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(resume == nil ? "New Agent" : "Resume Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(for: Page.self) { page in
            switch page {
            case .places:
                NewAgentPlaces(links: resume.map { item in links.filter { $0.profile.id == item.hostID && $0.activeSession == item.session } } ?? links, selection: target) { choose($0) }
            case .folders(let host, let path):
                if let link = links.first(where: { $0.identity == host }) {
                    FolderBrowser(connection: link, start: path) { choose(NewAgentTarget(host: host, place: link.place(forFolder: $0))) }
                }
            }
        }
    }

    /// Start in the sheet's confirmation slot, as Mail's Send is (round 40: sa#10, a floating
    /// full-width band over the keyboard cut the message editor to one line). "Start & Send"
    /// once there's a message, since it also sends it (round 41: sa#6, sb#5, opus#7, a bare
    /// Start hid that); the agent is in its spoken label.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .confirmationAction) {
            Button { start(sending: true) } label: {
                if busy && opening != .terminal && sendsFirstMessage { ProgressView() } else { Text(hasMessage ? "Start & Send" : "Start") }
            }
            .buttonStyle(.glassProminent)
            // ⌘Return starts from the keyboard, as ⌘N opened the sheet (round 30: the
            // keyboard loop ended at the sheet).
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(unavailable)
            .accessibilityLabel(hasMessage ? "Start \(startTitle) and Send" : "Start \(startTitle)")
        }
    }

    /// A plain shell in the same place.
    private var openTerminal: some View {
        Button { Task { await open(.terminal) } } label: {
            HStack {
                if opening == .terminal { ProgressView() } else { Image(systemName: "apple.terminal") }
                Text("Open Terminal")
            }
        }
        .disabled(unavailable || resume != nil)
    }

    private var startWithoutSending: some View {
        Button { start(sending: false) } label: {
            HStack {
                if (opening == .agent || startFlow.running) && !sendsFirstMessage { ProgressView() }
                Text("Start Without Sending")
            }
        }
        .disabled(unavailable)
    }

    private var hasMessage: Bool {
        resume == nil && !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start(sending: Bool) {
        sendsFirstMessage = sending
        Task { await open(.agent) }
    }

    private var placeRow: some View {
        LabeledContent {
            if let target, let link {
                VStack(alignment: .trailing) {
                    Text(link.title(for: target.place))
                    if let detail = link.detail(for: target.place, showHost: links.count > 1) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Choose")
            }
        } label: {
            Label("Workspace", systemImage: "folder")
        }
    }

    /// The demo's host, named, with connecting a real one under it (round 24: Connect a Host
    /// stood mid-form as a step of starting the agent, and nothing said which host it ran on).
    private var demoHostRow: some View {
        LabeledContent {
            Menu {
                Button("Connect a Host…", systemImage: "plus") {
                    dismiss()
                    model.endDemo()
                }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    Text(link?.profile.name ?? "Demo")
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .foregroundStyle(.secondary)
            }
            // The Agent picker's grey, not the tint's: in green, dimmed, a valid host read as
            // disabled (round 65: sa#9).
            .tint(.primary)
        } label: {
            Label("Host", systemImage: "desktopcomputer")
        }
    }

    private var preset: LaunchPreset? { settings.launchPresets.first { $0.id == presetID } }
    private var startTitle: String { preset?.name ?? agentKindLabel(kind) }

    private var footer: String {
        guard let target, let link else { return resume == nil ? "Choose where it works." : "The original workspace is unavailable or changed. Choose a destination on the original host and session." }
        // Said beside the workspace it would run in (round 23: a footnote under Connect a Host,
        // far from the place and the Start button).
        if model.demo != nil { return "Demo host: agents here are scripted samples." }
        if newWorktree { return "Creates a new branch from the repository's default base in a new worktree, without moving desktop focus." }
        let shell = " Open Terminal starts a plain shell there instead."
        switch target.place {
        case .workspace: return "Opens in a new tab of \(link.title(for: target.place)).\(shell)"
        case .folder: return "Creates a workspace for this folder.\(shell)"
        }
    }

    private func choose(_ next: NewAgentTarget) {
        target = next
        originalResumeDestination = false
        created = nil
        newWorktree = false
        error = nil
        pages = []
    }

    @MainActor private func open(_ what: Opening) async {
        guard !busy, let target, let link, let client = link.client, let session = link.activeSession,
              link.identity == target.host else { return }
        opening = what
        error = nil
        defer { opening = nil }
        do {
            let pane: String
            if let created, created.target == target, link.snapshot?.panes.contains(where: { $0.id == created.pane }) == true,
               link.snapshot?.agents.contains(where: { $0.paneID == created.pane }) == false {
                pane = created.pane
            } else {
                let workspace: Workspace
                switch target.place {
                case .workspace(let id):
                    guard let known = link.snapshot?.workspaces.first(where: { $0.id == id }) else { throw Failure.workspaceGone }
                    if newWorktree {
                        let result = try await client.createWorktree(workspaceID: id, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines), session: session)
                        workspace = result.workspace
                        pane = result.rootPane.id
                    } else {
                        workspace = known
                        // Always a folder: without one herdr starts the tab where the workspace's focused
                        // process is, and an agent that changed directory takes that anywhere.
                        let cwd = (originalResumeDestination ? resume?.cwd : nil) ?? link.folder(ofWorkspace: id)
                        pane = try await client.createTab(workspaceID: id, label: nil, cwd: cwd, session: session).rootPane.id
                    }
                case .folder(let path):
                    // herdr puts a workspace without a folder beside its focused one, not in home.
                    let cwd = if let path { path } else { try await client.folders(in: nil).path }
                    let result = try await client.createWorkspace(label: nil, cwd: cwd, session: session)
                    pane = result.rootPane.id
                    workspace = result.workspace
                }
                created = (target, pane)
                // Remembered even if the agent then fails: the workspace now exists.
                Self.remember(workspace, on: target.host)
                await link.awaitPane(pane)
            }
            guard link.identity == target.host, link.activeSession == session else { throw Failure.sessionChanged }
            let address = PaneAddress(hostID: target.host.hostID, session: session, paneID: pane)
            if what == .terminal {
                onOpen(.terminal(address))
                opened = true
                dismiss()
                return
            }
            let request = AgentStartFlow.Request(connection: link, address: address, kind: kind,
                                                 arguments: resume?.arguments ?? preset?.arguments.filter { !$0.isEmpty } ?? [], freshPane: true)
            await startFlow.start(request, onStarted: finish)
        } catch {
            self.error = error.localizedDescription
        }
    }
    /// Integrations that report a transcript open as a conversation, as does a Neon, whose comes
    /// with its first message; the rest, or a host without herdr's integration for the agent,
    /// open in the terminal, the message unsent.
    private func finish(_ agent: Agent, _ address: PaneAddress) {
        if hasMessage {
            if let draftID = DraftStore.id(host: SessionAddress(hostID: address.hostID, session: address.session), agent: agent) {
                DraftStore.save(firstMessage, for: draftID)
            }
            scene.firstMessage = .init(address: address, text: firstMessage, send: sendsFirstMessage && agent.opensAsConversation, agentName: agent.name)
        }
        onOpen(agent.opensAsConversation ? .conversation(address) : .terminal(address))
        opened = true
        dismiss()
    }

    // MARK: Defaults

    private static let lastHostKey = "newAgent.lastHost"
    private static func workspaceKey(_ host: SessionAddress) -> String { "newAgent.workspace.\(host.hostID.uuidString).\(host.session)" }

    private static func remember(_ workspace: Workspace, on host: SessionAddress) {
        UserDefaults.standard.set([workspace.id, workspace.label], forKey: workspaceKey(host))
        UserDefaults.standard.set([host.hostID.uuidString, host.session], forKey: lastHostKey)
    }

    /// The link started on last, else the one on screen, else the first connected.
    private static func defaultLink(_ links: [HostConnection], preferred: HostConnection?, contextual: Bool) -> HostConnection? {
        if contextual, let preferred { return preferred }
        if links.count > 1, let last = UserDefaults.standard.stringArray(forKey: lastHostKey), last.count == 2,
           let link = links.first(where: { $0.identity.hostID.uuidString == last[0] && $0.identity.session == last[1] && $0.snapshot != nil }) {
            return link
        }
        if let preferred, links.contains(where: { $0 === preferred }) { return preferred }
        return links.first { $0.snapshot != nil } ?? links.first
    }

    /// The workspace started in last (same id and label, as herdr reuses ids after a restart),
    /// else herdr's focused workspace, else the first; with none, the home folder.
    private static func defaultPlace(_ link: HostConnection) -> NewAgentPlace {
        let workspaces = (link.snapshot?.workspaces ?? []).sorted { $0.number < $1.number }
        if let last = UserDefaults.standard.stringArray(forKey: workspaceKey(link.identity)), last.count == 2,
           workspaces.contains(where: { $0.id == last[0] && $0.label == last[1] }) {
            return .workspace(last[0])
        }
        if let workspace = workspaces.first(where: \.focused) ?? workspaces.first { return .workspace(workspace.id) }
        return .folder(nil)
    }
}

extension HostConnection {
    /// A workspace's folder: its worktree checkout, else its first tab's (herdr keeps no folder per
    /// workspace, and names it after the one it was made in). Later tabs can be anywhere, since
    /// herdr starts an unplaced tab where the focused process is.
    func folder(ofWorkspace id: String) -> String? {
        guard let snapshot else { return nil }
        if let checkout = snapshot.workspaces.first(where: { $0.id == id })?.worktree?.checkoutPath { return checkout }
        let first = snapshot.tabs.filter { $0.workspaceID == id }.min { $0.number < $1.number }
        return snapshot.panes.first { $0.tabID == first?.id }?.cwd
    }

    /// The workspace already working in `folder`, if exactly one is; else a new one for it.
    func place(forFolder folder: String) -> NewAgentPlace {
        let matches = snapshot?.workspaces.filter { self.folder(ofWorkspace: $0.id) == folder } ?? []
        return matches.count == 1 ? .workspace(matches[0].id) : .folder(folder)
    }

    func title(for place: NewAgentPlace) -> String {
        switch place {
        case .workspace(let id): snapshot?.workspaces.first { $0.id == id }?.displayLabel ?? "Workspace"
        case .folder(let path?): (path as NSString).lastPathComponent
        case .folder(nil): "Home"
        }
    }

    func detail(for place: NewAgentPlace, showHost: Bool) -> String? {
        let folder: String? = switch place {
        case .workspace(let id):
            self.folder(ofWorkspace: id).map(homeRelative)
        case .folder(let path?): "New workspace · " + homeRelative(path)
        case .folder(nil): "New workspace · ~"
        }
        let host = showHost ? "\(profile.name) · \(identity.session)" : nil
        let parts = [host, folder].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Every workspace on the hosts in view, then any folder.
private struct NewAgentPlaces: View {
    let links: [HostConnection]
    let selection: NewAgentTarget?
    let choose: (NewAgentTarget) -> Void

    var body: some View {
        List {
            ForEach(links, id: \.identity) { link in
                Section {
                    let workspaces = (link.snapshot?.workspaces ?? []).sorted { $0.number < $1.number }
                    ForEach(workspaces) { workspace in
                        row(link, .workspace(workspace.id))
                    }
                    if workspaces.isEmpty { row(link, .folder(nil)) }
                    NavigationLink(value: NewAgentSheet.Page.folders(link.identity, startFolder(link))) {
                        Label("Choose Folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(!link.isLive)
                } header: {
                    if links.count > 1 { Text("\(link.profile.name) · \(link.identity.session)") }
                }
            }
        }
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ link: HostConnection, _ place: NewAgentPlace) -> some View {
        let target = NewAgentTarget(host: link.identity, place: place)
        return Button { choose(target) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(link.title(for: place)).foregroundStyle(.primary)
                    if let detail = link.detail(for: place, showHost: false) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if target == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    /// Next to the selected workspace's folder, where sibling repositories usually are.
    private func startFolder(_ link: HostConnection) -> String? {
        guard let selection, selection.host == link.identity else { return nil }
        switch selection.place {
        case .workspace(let id): return link.folder(ofWorkspace: id).map { ($0 as NSString).deletingLastPathComponent }
        case .folder(let path): return path.map { ($0 as NSString).deletingLastPathComponent }
        }
    }
}

/// One folder on the host at a time: tap to go in, Use to pick. Repositories can be picked
/// straight from their parent. Typing a path is there, but never needed.
private struct FolderBrowser: View {
    let connection: HostConnection
    let pick: (String) -> Void
    @State private var path: String?
    @State private var listing: FolderListing?
    @State private var failure: String?
    /// The listing on screen is for a folder being left; nothing in it can be picked.
    @State private var loading = true
    @State private var typing = false
    @State private var typed = ""

    init(connection: HostConnection, start: String?, pick: @escaping (String) -> Void) {
        self.connection = connection
        self.pick = pick
        _path = State(initialValue: start)
    }

    var body: some View {
        List {
            if let listing {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if listing.folders.isEmpty {
                    Text("No folders here").foregroundStyle(.secondary)
                }
                ForEach(listing.folders, id: \.name) { folder in
                    let child = (listing.path as NSString).appendingPathComponent(folder.name)
                    HStack {
                        Button { path = child } label: {
                            Label(folder.name, systemImage: folder.isRepository ? "arrow.triangle.branch" : "folder")
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        if folder.isRepository {
                            Button("Use") { pick(child) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    }
                }
            } else if let failure {
                ContentUnavailableView("Can't open folder", systemImage: "folder.badge.questionmark", description: Text(failure))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .disabled(loading && listing != nil)
        .buttonStyle(.borderless)
        .navigationTitle(listing.map { homeRelative($0.path) } ?? "Folders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Enclosing Folder", systemImage: "arrow.up") {
                    if let listing { path = (listing.path as NSString).deletingLastPathComponent }
                }
                .disabled(listing == nil || listing?.path == "/")
                Menu("More", systemImage: "ellipsis") {
                    Button("Home", systemImage: "house") { path = nil }
                    Button("Go to Path…", systemImage: "text.cursor") { typed = listing?.path ?? ""; typing = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { if let listing { pick(listing.path) } } label: {
                Text(listing.map { "Use \(($0.path as NSString).lastPathComponent)" } ?? "Use This Folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .primaryAction()
            .controlSize(.large)
            .disabled(listing == nil || loading)
            .padding()
        }
        .alert("Go to Path", isPresented: $typing) {
            TextField("/path or ~/path", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Go") { path = typed.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: FolderKey(liveID: connection.liveID, path: path)) { await load() }
    }

    private struct FolderKey: Hashable { let liveID: Int; let path: String? }

    private func load() async {
        loading = true
        guard let client = connection.client else {
            failure = "Not connected"
            loading = false
            return
        }
        do {
            let next = try await client.folders(in: path)
            guard !Task.isCancelled else { return }
            listing = next
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            // The last good listing stays, usable again; the failure shows above it.
            failure = error.localizedDescription
        }
        loading = false
    }
}
