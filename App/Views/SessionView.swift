import HerdrAPI
import SwiftUI

/// The inbox: every agent on the host as a conversation, what needs you first. Plain
/// shells sit folded at the bottom. The title swipes between hosts and opens the host list.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    let connection: HostConnection

    @State private var sheet: Sheet?
    @State private var showsTerminals = false
    @State private var closing: Thread?
    @State private var closeError: String?
    @State private var lastChange: [PaneAddress: Date] = [:]
    @State private var hostSelection = 0
    @State private var startFlow = AgentStartFlow()
    @State private var pushEdge: Edge = .trailing

    private struct AgentChange: Equatable {
        let address: PaneAddress
        let status: String
        let sequence: Int?
    }

    /// Retained for scripted demo navigation.
    enum Mode: String, CaseIterable, Identifiable {
        case agents = "Agents", workspaces = "Workspaces"
        var id: Self { self }
    }

    enum Sheet: Identifiable {
        case settings, hosts, addHost, editHost(HostProfile)
        case newThread(HostConnection, NewThreadSheet.Kind)
        var id: String {
            switch self {
            case .settings: "settings"
            case .hosts: "hosts"
            case .addHost: "add"
            case .editHost(let profile): profile.id.uuidString
            case .newThread(let link, let kind): "new-\(ObjectIdentifier(link))-\(kind)"
            }
        }
    }

    var body: some View {
        content
            .id(connection.profile.id)
            .transition(.push(from: pushEdge))
            .navigationTitle(allHosts ? "All Hosts" : connection.profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .settings: SettingsView()
                case .hosts: hostList
                case .addHost: AddHostView()
                case .editHost(let profile): NavigationStack { HostEditor(profile: profile) }
                case .newThread(let link, let kind):
                    NewThreadSheet(connection: link, kind: kind, workspaceID: nil) { paneID in
                        model.navigationPath.append(.terminal(link.address(paneID: paneID)))
                    }
                }
            }
            .modifier(AgentStartFeedback(flow: startFlow, onStarted: didStart))
            .sensoryFeedback(.warning, trigger: blockedCount) { old, new in settings.haptics && new > old }
            .sensoryFeedback(.selection, trigger: hostSelection) { _, _ in settings.haptics }
            .onChange(of: agentChanges, initial: true) { old, new in
                let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.address, $0) })
                let now = Date()
                for change in new where previous[change.address] != change {
                    lastChange[change.address] = now
                }
            }
            .confirmationDialog("Close \(closing?.agent.conversationTitle ?? "agent")?", isPresented: .init(
                get: { closing != nil }, set: { if !$0 { closing = nil } }
            ), titleVisibility: .visible, presenting: closing) { thread in
                Button("Close", role: .destructive) { Task { await close(thread) } }
                Button("Cancel", role: .cancel) { closing = nil }
            } message: { _ in
                Text("This ends the agent and its terminal.")
            }
            .alert("Could Not Close Agent", isPresented: .init(
                get: { closeError != nil }, set: { if !$0 { closeError = nil } }
            )) { Button("OK", role: .cancel) { closeError = nil } } message: {
                Text(closeError ?? "")
            }
            .onChange(of: demo?.mode, initial: true) { _, next in
                if let next { settings.inboxGrouping = next == .workspaces ? .workspace : .none }
            }
            .onChange(of: demo?.paneID, initial: true) { _, next in
                if demo != nil { model.navigationPath = next.map { [.terminal(connection.address(paneID: $0))] } ?? [] }
            }
            .onChange(of: demo?.showsSettings, initial: true) { _, shows in if shows == true { sheet = .settings } }
    }

    private var hostList: some View {
        HostList(connection: connection) { sheet = $0 }
            .presentationDetents([.medium, .large])
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            let swipe: ((Int) -> Void)? = canSwitchHosts ? { switchHost(by: $0) } : nil
            HostTitle(title: allHosts ? "All Hosts" : connection.profile.name, subtitle: subtitle,
                      previous: neighbor(-1)?.name, next: neighbor(1)?.name,
                      open: { sheet = .hosts }, switchHost: swipe)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { sheet = .settings }
        }
        ToolbarItem(placement: .bottomBar) { viewMenu }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu { newMenu } label: { Image(systemName: "plus") }
                .accessibilityLabel("New")
        }
    }

    private var allHosts: Bool { settings.allHosts && model.demo == nil }
    private var links: [HostConnection] { allHosts ? model.connections : [connection] }
    private var threads: [Thread] {
        allHosts ? model.threads : model.threads.filter { $0.connection === connection }
    }
    private var agentChanges: [AgentChange] {
        model.threads.map { AgentChange(address: $0.address, status: $0.agent.agentStatus.label, sequence: $0.agent.stateChangeSeq) }
    }
    private var canSwitchHosts: Bool { !allHosts && model.profiles.count >= 2 }
    private var hostIndex: Int? { model.profiles.firstIndex { $0.id == connection.profile.id } }
    private func neighbor(_ offset: Int) -> HostProfile? {
        guard canSwitchHosts, let index = hostIndex, model.profiles.indices.contains(index + offset) else { return nil }
        return model.profiles[index + offset]
    }

    /// Next host enters from the trailing edge, previous from the leading edge.
    private func switchHost(by offset: Int) {
        guard let target = neighbor(offset) else { return }
        pushEdge = offset > 0 ? .trailing : .leading
        withAnimation(.smooth) { model.select(target.id) }
        hostSelection += 1
    }

    private func close(_ thread: Thread) async {
        do {
            guard let client = thread.connection.client else { throw HerdrError.noResponse }
            try await client.closePane(thread.address.paneID, session: thread.address.session)
        } catch { closeError = error.localizedDescription }
        closing = nil
    }

    @ViewBuilder private var newMenu: some View {
        if allHosts {
            ForEach(model.profiles) { profile in
                Menu(profile.name) {
                    ForEach(links.filter { $0.profile.id == profile.id }, id: \.identity) { link in
                        if links.filter({ $0.profile.id == profile.id }).count > 1 {
                            Menu(link.activeSession ?? "Session") { newButtons(link) }
                        } else {
                            newButtons(link)
                        }
                    }
                }
            }
        } else if let link = model.connection {
            newButtons(link)
        }
    }

    @ViewBuilder private func newButtons(_ link: HostConnection) -> some View {
        Button("New Agent…", systemImage: "sparkles") { sheet = .newThread(link, .agent) }
        Button("New Workspace…", systemImage: "square.stack.3d.up") { sheet = .newThread(link, .workspace) }
    }

    @ViewBuilder
    private var content: some View {
        if settings.inboxView == .machines {
            MachinesView()
        } else if !allHosts, case .failed(let failure) = connection.phase, connection.snapshot == nil {
            ScrollView {
                FailureCard(connection: connection, failure: failure) { sheet = .editHost(connection.profile) }
            }
            .refreshable { await model.refresh() }
        } else if allHosts || connection.snapshot != nil {
            List {
                ForEach(links, id: \.identity) { link in
                    if case .failed(let failure) = link.phase {
                        Section {
                            FailureCard(connection: link, failure: failure) { sheet = .editHost(link.profile) }
                                .listRowBackground(Color.clear)
                        } header: {
                            if allHosts { Text("\(link.profile.name) · \(link.activeSession ?? "Sessions")") }
                        }
                    } else if allHosts, let status = link.statusText {
                        Text("\(link.profile.name) · \(link.activeSession ?? "Sessions") · \(status)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                inbox
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh() }
            .opacity(allHosts || connection.isLive ? 1 : 0.6)
            .animation(.smooth, value: blockedCount)
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Connecting to \(connection.profile.address)…")
            }
        }
    }

    // MARK: Inbox

    @ViewBuilder
    private var inbox: some View {
            let result = inboxSections(threads, grouping: settings.inboxGrouping, sort: settings.inboxSort,
                                       collapseIdle: settings.collapseIdle, allHosts: allHosts, lastChange: lastChange) {
                $0.connection.hidden[$0.agent.paneID] != nil
            }
            if !result.needsYou.isEmpty { Section("Needs You") { rows(result.needsYou) } }
            ForEach(result.sections) { section in
                Section(section.title) {
                    rows(section.threads)
                    if !section.idle.isEmpty {
                        DisclosureGroup {
                            rows(section.idle)
                        } label: {
                            Label("\(section.idle.count) Idle", systemImage: "moon.zzz")
                        }
                    }
                }
            }
            if result.needsYou.isEmpty && result.sections.isEmpty && result.hidden.isEmpty {
                ContentUnavailableView {
                    Label("No agents", systemImage: "sparkles")
                } description: {
                    Text("Start an agent or create a workspace.")
                } actions: {
                    Menu { newMenu } label: { Label("New", systemImage: "plus") }
                }
            }
            ForEach(links, id: \.identity) { link in
                if let snapshot = link.snapshot {
                    terminals(snapshot.panes.filter { pane in !snapshot.agents.contains { $0.paneID == pane.id } }, link)
                }
            }
            if !result.hidden.isEmpty {
                Section {
                    DisclosureGroup("Hidden (\(result.hidden.count))") {
                        rows(result.hidden, hidden: true)
                    }
                }
            }
    }

    private func rows(_ threads: [Thread], hidden: Bool = false) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.agent.hasTranscript ? Route.conversation(thread.address) : Route.terminal(thread.address)) {
                AgentRow(
                    agent: thread.agent,
                    workspace: thread.workspace?.label,
                    unread: thread.connection.isUnread(thread.agent),
                    host: allHosts ? "\(thread.connection.profile.name) · \(thread.address.session)" : nil,
                    subagents: thread.connection.workingSubagents[thread.agent.paneID] ?? 0
                )
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if hidden {
                    Button("Unhide", systemImage: "eye") { thread.connection.unhide(thread.agent) }
                        .tint(.gray)
                } else {
                    Button("Hide", systemImage: "eye.slash") { thread.connection.hide(thread.agent) }
                        .tint(.gray)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Close", systemImage: "trash", role: .destructive) { closing = thread }
            }
        }
    }

    @ViewBuilder
    private func terminals(_ panes: [Pane], _ link: HostConnection) -> some View {
        if !panes.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsTerminals) {
                    ForEach(Array(Set(panes.map(\.workspaceID))).sorted(), id: \.self) { workspaceID in
                        let workspace = link.snapshot?.workspaces.first { $0.id == workspaceID }
                        let noAgent = !(link.snapshot?.agents.contains { $0.workspaceID == workspaceID } ?? false)
                        Text(workspace?.label ?? workspaceID)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(panes.filter { $0.workspaceID == workspaceID }) { pane in
                            NavigationLink(value: Route.terminal(link.address(paneID: pane.id))) {
                                VStack(alignment: .leading) {
                                    TerminalRow(pane: pane)
                                    if noAgent { Text("No agent yet").font(.caption).foregroundStyle(.secondary) }
                                    if allHosts {
                                        Text("\(link.profile.name) · \(link.activeSession ?? "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button("Start \(agentKindLabel(link.lastAgentKind))", systemImage: "play.fill") {
                                    let request = AgentStartFlow.Request(connection: link, address: link.address(paneID: pane.id),
                                                                         kind: link.lastAgentKind)
                                    Task { await startFlow.start(request, onStarted: didStart) }
                                }
                                .tint(.accentColor)
                                .disabled(startFlow.running || !link.isLive)
                            }
                        }
                    }
                } label: {
                    Label(panes.count == 1 ? "1 Terminal" : "\(panes.count) Terminals", systemImage: "apple.terminal")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func didStart(_ agent: Agent, _ address: PaneAddress) {
        model.navigationPath.append(agent.hasTranscript ? .conversation(address) : .terminal(address))
    }


    // MARK: Chrome

    private var subtitle: String {
        if allHosts { return "\(model.profiles.count) hosts" }
        if let link = connection.statusText { return link }
        guard let session = connection.activeSession, connection.sessions.filter(\.running).count > 1 else {
            return connection.profile.address
        }
        return "\(connection.profile.address) · \(session)"
    }

    private var blockedCount: Int {
        links.reduce(0) { count, link in
            count + (link.snapshot?.agents.reduce(0) { $0 + ($1.agentStatus == .blocked ? 1 : 0) } ?? 0)
        }
    }

    /// How the inbox is arranged; where it points is the title's job.
    private var viewMenu: some View {
        @Bindable var settings = settings
        return Menu {
            choices("View", $settings.inboxView, InboxKind.allCases, label: \.label)
            if settings.inboxView == .agents {
                choices("Group", $settings.inboxGrouping, InboxGrouping.allCases, label: \.label)
                choices("Sort", $settings.inboxSort, InboxSort.allCases, label: \.label)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("View Options")
    }

    /// A titled menu section of checkmarked choices (an inline `Picker` drops the title).
    private func choices<Value: Hashable>(_ title: String, _ selection: Binding<Value>, _ values: [Value],
                                         label: KeyPath<Value, String>) -> some View {
        Section(title) {
            ForEach(values, id: \.self) { value in
                Toggle(value[keyPath: label], isOn: .init(
                    get: { selection.wrappedValue == value },
                    set: { if $0 { selection.wrappedValue = value } }
                ))
            }
        }
    }
}

/// The title's host list: All Hosts or one host, in the user's order, plus the host's sessions.
private struct HostList: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let connection: HostConnection
    let present: (SessionView.Sheet) -> Void

    private var allHosts: Bool { settings.allHosts && model.demo == nil }

    var body: some View {
        NavigationStack {
            List {
                if model.demo == nil, model.profiles.count > 1 {
                    row("All Hosts", detail: "\(model.profiles.count) hosts", selected: allHosts) {
                        settings.allHosts = true
                    }
                }
                Section("Hosts") {
                    ForEach(model.profiles) { profile in
                        row(profile.name, detail: profile.address, selected: !allHosts && profile.id == connection.profile.id) {
                            settings.allHosts = false
                            model.select(profile.id)
                        }
                    }
                    .onMove { model.moveProfiles(from: $0, to: $1) }
                    if model.demo == nil {
                        Button("Add Host…", systemImage: "plus") { present(.addHost) }
                    }
                }
                let running = connection.sessions.filter(\.running)
                if !allHosts, running.count > 1 {
                    Section("herdr Session") {
                        ForEach(running) { session in
                            row(session.name, selected: session.name == connection.activeSession) {
                                model.selectSession(session.name)
                            }
                        }
                    }
                }
                if model.demo != nil {
                    Button("Leave Demo", systemImage: "xmark.circle") { dismiss(); model.endDemo() }
                } else if !allHosts {
                    Button("Edit \(connection.profile.name)…", systemImage: "pencil") { present(.editHost(connection.profile)) }
                }
            }
            .navigationTitle("Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.profiles.count > 1 { ToolbarItem(placement: .topBarLeading) { EditButton() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum Route: Hashable {
    /// The agent's transcript as chat.
    case conversation(PaneAddress)
    /// The live terminal of a pane.
    case terminal(PaneAddress)
    /// A read-only child transcript. Format is stored as its raw value for Hashable routing.
    case subagent(PaneAddress, String, String, String)

    var address: PaneAddress {
        switch self {
        case .conversation(let address), .terminal(let address), .subagent(let address, _, _, _): address
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    let workspace: String?
    let unread: Bool
    var host: String? = nil
    /// Subagents last seen working in this agent's open conversation; shown only while it works.
    var subagents = 0

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: agent.agentStatus)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.conversationTitle)
                    .font(.body.weight(unread ? .semibold : .regular))
                    .lineLimit(1)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if unread {
                Circle().fill(.tint).frame(width: 9, height: 9).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 2)
    }

    /// Status, then where it runs: "Working · 2 subagents · herdwick".
    private var caption: String {
        let place = workspace ?? agent.cwd.map { ($0 as NSString).lastPathComponent }
        let helpers = agent.agentStatus == .working && subagents > 0 ? (subagents == 1 ? "1 subagent" : "\(subagents) subagents") : nil
        return [agent.agentStatus.label, helpers, place, host].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TerminalRow: View {
    let pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.label ?? pane.terminalTitle ?? pane.id)
                .lineLimit(1)
            if let cwd = pane.cwd {
                Text(homeRelative(cwd)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }
}
