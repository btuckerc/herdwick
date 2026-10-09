import HerdrAPI
import SwiftUI

/// The inbox: every agent on the host as a conversation, what needs you first. Plain
/// shells sit folded at the bottom. The title swipes between hosts and opens the host list.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let connection: HostConnection

    @State private var sheet: Sheet?
    // Folded parts of the inbox, each opened from a `FoldRow` inside its card.
    @State private var showsTerminals = false
    @State private var showsHidden = false
    @State private var showsEnded = false
    /// Sections whose idle agents are shown.
    @State private var openIdle: Set<String> = []
    @State private var closing: Thread?
    @State private var renaming: Thread?
    @State private var newName = ""
    @State private var failure: Failure?
    /// Ranks the inbox holds while the user scrolls or reads below the top, so rows don't move
    /// under them; nil while it follows live activity.
    @State private var heldRanks: [PaneAddress: InboxRank]?
    @State private var atTop = true
    @State private var scrollIdle = true
    /// Set by New Activity: scroll to the first row once the new order has been laid out.
    @State private var scrollToFirst = false
    @State private var hostSelection = 0
    @State private var startFlow = AgentStartFlow()
    @State private var pushEdge: Edge = .trailing
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Retained for scripted demo navigation.
    enum Mode: String, CaseIterable, Identifiable {
        case agents = "Agents", workspaces = "Workspaces"
        var id: Self { self }
    }

    enum Sheet: Identifiable {
        case settings, hosts, addHost, editHost(HostProfile)
        /// A workspace preselects where the agent goes ("New Agent Here").
        case newAgent(HostConnection?, workspace: String?)
        case ended(EndedAgent)
        case resume(EndedAgent)
        case shared
        /// New Agent for a package on the Shared shelf, which then opens in its composer.
        case shareNewAgent(UUID)
        var id: String {
            switch self {
            case .settings: "settings"
            case .hosts: "hosts"
            case .addHost: "add"
            case .editHost(let profile): profile.id.uuidString
            case .newAgent(let link, let workspace): "new-\(link.map { "\(ObjectIdentifier($0))" } ?? "")-\(workspace ?? "")"
            case .ended(let item): "ended-\(item.id)"
            case .resume(let item): "resume-\(item.id)"
            case .shared: "shared"
            case .shareNewAgent(let id): "share-new-\(id)"
            }
        }
    }

    var body: some View {
        presented
            .onChange(of: demo?.mode, initial: true) { _, next in
                if let next { settings.inboxGrouping = next == .workspaces ? .workspace : .none }
            }
            .onChange(of: demo?.paneID, initial: true) { _, next in
                if let demo { scene.navigationPath = next.map { [demo.route(for: $0, connection: connection)] } ?? [] }
            }
            .onChange(of: connection.snapshot == nil) { _, missing in
                if !missing, let demo, let pane = demo.paneID {
                    scene.navigationPath = [demo.route(for: pane, connection: connection)]
                }
            }
            .onChange(of: demo?.showsSettings, initial: true) { _, shows in if shows == true { sheet = .settings } }
            .onChange(of: scene.showNewAgent) { _, show in
                if show { sheet = .newAgent(nil, workspace: nil); scene.showNewAgent = false }
            }
    }

    /// Split from `body`, whose single modifier chain overran the type-checker's time limit.
    private var presented: some View {
        content
            .id(connection.profile.id)
            .transition(reduceMotion ? .opacity : .push(from: pushEdge))
            // Scoped to the host content: select also clears the navigation path, which shouldn't ride along.
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.24), value: connection.profile.id)
            .navigationTitle(allHosts ? "All Hosts" : connection.profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $sheet, content: sheetContent)
            .modifier(AgentStartFeedback(flow: startFlow, onStarted: didStart))
            .sensoryFeedback(.warning, trigger: blockedCount) { old, new in settings.haptics && new > old }
            .sensoryFeedback(.selection, trigger: hostSelection) { _, _ in settings.haptics }
            .onChange(of: settings.inboxSort) { settleOrder() }
            .onChange(of: settings.inboxGrouping) { settleOrder() }
            .onAppear {
                settleOrder()
                for link in links { link.refreshActivity() }
            }
            .alert("Rename Agent", isPresented: .init(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            ), presenting: renaming) { thread in
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") { rename(thread) }
            } message: { _ in
                Text("Shown here and in herdr. Leave it empty for the agent's own title.")
            }
            .alert(failure?.title ?? "", isPresented: .init(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            ), presenting: failure) { _ in Button("OK", role: .cancel) { failure = nil } } message: {
                Text($0.message)
            }
    }

    struct Failure {
        let title: String
        let message: String
    }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .settings: SettingsView()
        case .hosts: hostList
        case .addHost: AddHostView()
        case .editHost(let profile): NavigationStack { HostEditor(profile: profile) }
        case .newAgent(let link, let workspace):
            NewAgentSheet(links: links, preferred: link ?? model.connection(in: scene), workspace: workspace) { route in
                scene.navigationPath.append(route)
            }
        case .resume(let item):
            NewAgentSheet(links: links, preferred: connection, resume: item) { scene.navigationPath.append($0) }
        case .ended(let item):
            if let link = links.first(where: { $0.profile.id == item.hostID && $0.activeSession == item.session }) {
                EndedAgentView(item: item, connection: link) { self.sheet = .resume(item) }
            }
        case .shared:
            SharedShelfView { id, thread in
                stage(id, draftID: DraftStore.id(host: thread.connection.identity, agent: thread.agent), address: nil)
                self.sheet = nil
                model.open(thread.address, in: scene)
            } newAgent: { id in
                self.sheet = .shareNewAgent(id)
            }
        case .shareNewAgent(let id):
            NewAgentSheet(links: links, preferred: model.connection(in: scene)) { route in
                // A start that fell back to the terminal has no composer; the share stays on the shelf.
                if case .conversation(let address) = route { stage(id, draftID: nil, address: address) }
                scene.navigationPath.append(route)
            }
        }
    }

    private func stage(_ id: UUID, draftID: String?, address: PaneAddress?) {
        scene.importPackageID = id
        scene.importDraftID = draftID
        scene.importAddress = address
    }

    private var hostList: some View {
        HostList(connection: connection) { sheet = $0 }
            .presentationDetents([.medium, .large])
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if settings.inboxView == .agents {
            ToolbarItem(placement: .topBarLeading) {
                Button(scene.searchPresented ? "Close Search" : "Search",
                       systemImage: scene.searchPresented ? "xmark" : "magnifyingglass") {
                    if scene.searchPresented { query = "" }
                    scene.searchPresented.toggle()
                }
            }
        }
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
            Button("New Agent", systemImage: "plus") { sheet = .newAgent(nil, workspace: nil) }
        }
    }

    private var allHosts: Bool { settings.allHosts && model.demo == nil }
    /// The shown host is off; under All Hosts, every host is.
    private var hostOff: Bool {
        allHosts ? !model.profiles.contains(where: \.isEnabled) : !connection.profile.isEnabled
    }
    private var links: [HostConnection] { allHosts ? model.connections : [connection] }
    private var threads: [Thread] {
        let scoped = model.inboxThreads(in: scene)
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return scoped }
        return scoped.filter { thread in
            [thread.agent.conversationTitle, thread.workspace?.label, thread.agent.workingDirectory, thread.connection.profile.name,
             settings.inboxPreviews ? thread.connection.preview(thread.agent) : nil]
                .contains { $0?.localizedStandardContains(query) == true }
        }
    }
    private var liveRanks: [PaneAddress: InboxRank] {
        Dictionary(threads.map { ($0.address, inboxRank($0)) }) { first, _ in first }
    }

    /// Follows live activity at the top of a resting list; anywhere else holds the order it has.
    private func holdIfBrowsing() {
        if atTop && scrollIdle { heldRanks = nil } else if heldRanks == nil { heldRanks = liveRanks }
    }

    /// Shows the current order: on return to the inbox, a sort or grouping change, or on request.
    private func settleOrder() {
        heldRanks = atTop && scrollIdle ? nil : liveRanks
    }

    private func sections(held: Bool) -> (needsYou: [Thread], sections: [InboxSection], hidden: [Thread]) {
        let ranks = held ? heldRanks : nil
        return inboxSections(threads, grouping: settings.inboxGrouping, sort: settings.inboxSort,
                             collapseIdle: settings.collapseIdle, allHosts: allHosts,
                             rank: { ranks?[$0.address] ?? inboxRank($0) }) {
            $0.connection.hidden[$0.agent.paneID] != nil
        }
    }

    private static func order(_ result: (needsYou: [Thread], sections: [InboxSection], hidden: [Thread])) -> [PaneAddress] {
        (result.needsYou + result.sections.flatMap { $0.threads + $0.idle } + result.hidden).map(\.address)
    }
    /// The title swipes through the hosts that are on (and the one shown, even if it's off).
    private var ring: [HostProfile] { model.profiles.filter { $0.isEnabled || $0.id == connection.profile.id } }
    private var canSwitchHosts: Bool { !allHosts && ring.count >= 2 }
    private func neighbor(_ offset: Int) -> HostProfile? {
        let ring = ring
        guard canSwitchHosts, let index = ring.firstIndex(where: { $0.id == connection.profile.id }),
              ring.indices.contains(index + offset) else { return nil }
        return ring[index + offset]
    }

    /// Next host enters from the trailing edge, previous from the leading edge.
    private func switchHost(by offset: Int) {
        guard let target = neighbor(offset) else { return }
        pushEdge = offset > 0 ? .trailing : .leading
        model.select(target.id, in: scene)
        hostSelection += 1
    }

    /// Off the list at once, the rows below closing the gap, while herdr ends it; back with an
    /// alert if herdr refuses.
    private func close(_ thread: Thread) {
        closing = nil
        let request = withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            thread.connection.close(paneID: thread.agent.paneID)
        }
        Task {
            if case .failure(let error) = await request.result {
                failure = Failure(title: "Could Not Close Agent", message: error.localizedDescription)
            }
        }
    }

    private func rename(_ thread: Thread) {
        renaming = nil
        let name = newName
        Task {
            do { try await thread.connection.rename(paneID: thread.agent.paneID, to: name) } catch {
                failure = Failure(title: "Could Not Rename Agent", message: error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if hostOff {
            ContentUnavailableView {
                Label("\(connection.profile.name) Is Off", systemImage: "powersleep")
            } description: {
                Text("Herdwick won't connect to it until you turn it on.")
            } actions: {
                Button("Turn On") { model.setEnabled(true, for: connection.profile.id) }
                    .buttonStyle(.glassProminent)
            }
        } else if settings.inboxView == .machines {
            MachinesView()
        } else if !allHosts, case .failed(let failure) = connection.phase, connection.snapshot == nil {
            ScrollView {
                sharedButton
                FailureCard(connection: connection, failure: failure) { sheet = .editHost(connection.profile) }
                    .padding()
            }
            .refreshable { await model.refresh(explicit: true) }
        } else if allHosts || connection.snapshot != nil {
            inboxList
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Connecting to \(connection.profile.address)…")
            } actions: {
                sharedButton
            }
        }
    }

    /// The Shared shelf stays reachable while the host connects or fails; the inbox has its own row.
    @ViewBuilder private var sharedButton: some View {
        if !SharedInbox.shared.packages.isEmpty {
            Button("Shared · \(SharedInbox.shared.packages.count)", systemImage: "square.and.arrow.down") { sheet = .shared }
                .buttonStyle(.glass)
        }
    }

    // MARK: Inbox

    private var inboxList: some View {
        let shown = sections(held: heldRanks != nil)
        @Bindable var scene = scene
        let order = Self.order(shown)
        let newActivity = heldRanks != nil && Self.order(sections(held: false)) != order
        return ScrollViewReader { proxy in
            List(selection: $scene.selectedRoute) {
                ForEach(links, id: \.identity) { link in
                    if case .failed(let failure) = link.phase {
                        Section {
                            FailureCard(connection: link, failure: failure) { sheet = .editHost(link.profile) }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        } header: {
                            if allHosts { Text("\(link.profile.name) · \(link.activeSession ?? "Sessions")") }
                        }
                    } else if allHosts, let status = link.statusText {
                        Text("\(link.profile.name) · \(link.activeSession ?? "Sessions") · \(status)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !SharedInbox.shared.packages.isEmpty {
                    Section {
                        Button { sheet = .shared } label: {
                            Label { Text("Shared").foregroundStyle(Color.primary) } icon: { Image(systemName: "square.and.arrow.down") }
                        }
                        .badge(SharedInbox.shared.packages.count)
                    }
                }
                // Only the stale rows dim: the failure card above is the way out and stays at full strength.
                inbox(shown)
                    .opacity(allHosts || connection.isLive ? 1 : 0.6)
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .top) { if scene.searchPresented { searchBar } }
            .onChange(of: scene.searchPresented, initial: true) { _, shown in searchFocused = shown }
            .refreshable { await model.refresh(explicit: true) }
            // No list-wide animation: live status and order changes would slide every row at once.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Strict: a few points down, the list keeps visible rows fixed and inserts above them unseen.
                geometry.contentOffset.y <= -geometry.contentInsets.top + 8
            } action: { _, top in
                atTop = top
                holdIfBrowsing()
            }
            .onScrollPhaseChange { _, phase in
                scrollIdle = phase == .idle
                holdIfBrowsing()
            }
            .onChange(of: order) { _, order in
                // Scrolling in the same update as the reorder would target the old layout.
                guard scrollToFirst, let first = order.first else { return }
                scrollToFirst = false
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { proxy.scrollTo(first, anchor: .top) }
            }
            .overlay(alignment: .top) {
                Group {
                    if newActivity {
                        // Floats over the list rather than inserting a row, so nothing shifts.
                        Button("New Activity", systemImage: "arrow.up") {
                            // Shows the new order but stays held: scrollTo stops at the first row with the
                            // header under the bar, short of the top where live reordering is visible.
                            heldRanks = liveRanks
                            scrollToFirst = true
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: newActivity)
            }
        }
    }

    /// Opened from the toolbar's magnifying glass (or ⌘F), which becomes ✕ to close and clear it.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Title, workspace, folder or message", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func inbox(_ result: (needsYou: [Thread], sections: [InboxSection], hidden: [Thread])) -> some View {
            if !result.needsYou.isEmpty { Section("Needs You") { rows(result.needsYou) } }
            ForEach(result.sections) { section in
                Section(section.title) {
                    rows(section.threads)
                    if !section.idle.isEmpty {
                        FoldRow(title: "\(section.idle.count) Idle", systemImage: AgentStatus.idle.symbol, open: Binding {
                            openIdle.contains(section.id)
                        } set: { open in
                            if open { openIdle.insert(section.id) } else { openIdle.remove(section.id) }
                        })
                        if openIdle.contains(section.id) { rows(section.idle) }
                    }
                }
            }
            if result.needsYou.isEmpty && result.sections.isEmpty && result.hidden.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if result.needsYou.isEmpty && result.sections.isEmpty && result.hidden.isEmpty {
                // "No agents" only from a host that answered; while the first attempts run the
                // status lines above say so, and once every host is down, offer the way back.
                if links.contains(where: \.isLive) {
                    ContentUnavailableView {
                        Label("No agents", systemImage: "sparkles")
                    } description: {
                        Text(links.allSatisfy(\.isLive) ? "Start an agent in any folder on this host." : "No agents on the connected hosts.")
                    } actions: {
                        Button("New Agent", systemImage: "plus") { sheet = .newAgent(nil, workspace: nil) }
                            .labelStyle(.titleAndIcon)
                    }
                } else if links.allSatisfy(\.isDown), !links.allSatisfy(\.isFailed) {
                    // A failed host already shows its card with the fix; this would repeat it.
                    ContentUnavailableView {
                        Label("No hosts connected", systemImage: "network.slash")
                    } description: {
                        Text("Check that the hosts are on and reachable, or add another.")
                    } actions: {
                        Button("Add Host", systemImage: "plus") { sheet = .addHost }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            ForEach(links, id: \.identity) { link in
                if query.isEmpty, let snapshot = link.snapshot {
                    terminals(snapshot.panes.filter { pane in !snapshot.agents.contains { $0.paneID == pane.id } }, link)
                }
            }
            if !result.hidden.isEmpty {
                Section {
                    FoldRow(title: "Hidden (\(result.hidden.count))", open: $showsHidden)
                    if showsHidden { rows(result.hidden, hidden: true) }
                }
            }
            let ended = EndedAgents.shared.entries.filter { item in
                item.ended && links.contains { $0.profile.id == item.hostID && $0.activeSession == item.session }
            }
            if !ended.isEmpty {
                Section {
                    FoldRow(title: "Ended (\(ended.count))", open: $showsEnded)
                    if showsEnded {
                        ForEach(ended) { item in
                            Button { sheet = .ended(item) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text("\(agentKindLabel(item.harness)) · \(item.workspaceLabel) · \(item.session)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Resume", systemImage: "play") { sheet = .resume(item) }
                                Button("Remove from Shelf", role: .destructive) { EndedAgents.shared.remove(item) }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { EndedAgents.shared.remove(item) }
                            }
                        }
                    }
                }
            }
    }

    private func rows(_ threads: [Thread], hidden: Bool = false) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.agent.hasTranscript ? Route.conversation(thread.address) : Route.terminal(thread.address)) {
                AgentRow(
                    agent: thread.agent,
                    status: thread.connection.presentedStatus(thread.agent),
                    workspace: thread.workspace?.displayLabel,
                    unread: thread.connection.isUnread(thread.agent),
                    host: allHosts ? "\(thread.connection.profile.name) · \(thread.address.session)" : nil,
                    subagents: thread.connection.workingSubagents[thread.agent.paneID] ?? 0,
                    preview: settings.inboxPreviews ? thread.connection.preview(thread.agent) : nil
                )
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if thread.connection.isUnread(thread.agent) {
                    Button("Mark as Read", systemImage: "envelope.open") { thread.connection.markSeen(thread.agent) }
                        .tint(.accentColor)
                } else if thread.connection.presentedStatus(thread.agent) == .idle {
                    Button("Mark as Unread", systemImage: "envelope.badge") { thread.connection.markUnread(thread.agent) }
                        .tint(.accentColor)
                }
                if hidden {
                    Button("Unhide", systemImage: "eye") { thread.connection.unhide(thread.agent) }
                        .tint(.gray)
                } else {
                    Button("Hide", systemImage: "eye.slash") { thread.connection.hide(thread.agent) }
                        .tint(.gray)
                }
            }
            .contextMenu {
                Button("Rename…", systemImage: "pencil") {
                    newName = thread.agent.conversationTitle
                    renaming = thread
                }
                Button("New Agent Here", systemImage: "plus") {
                    sheet = .newAgent(thread.connection, workspace: thread.agent.workspaceID)
                }
            }
            // Not `.destructive`: a list takes that as the row already gone and slides it out,
            // then back when the confirmation is still open.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Close", systemImage: "trash") { closing = thread }
                    .tint(.red)
            }
            // On the row, so it points at what it closes. A popover rather than a confirmation
            // dialog: a dialog runs its button only once its dismissal has played (~0.5 s), and
            // this takes the row out as Close is tapped.
            .popover(isPresented: .init(
                get: { closing?.address == thread.address }, set: { if !$0 { closing = nil } }
            ), arrowEdge: .bottom) {
                ClosePrompt(title: thread.agent.conversationTitle) { close(thread) }
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func terminals(_ panes: [Pane], _ link: HostConnection) -> some View {
        if !panes.isEmpty {
            Section {
                FoldRow(title: panes.count == 1 ? "1 Terminal" : "\(panes.count) Terminals", systemImage: "apple.terminal",
                        open: $showsTerminals)
                if showsTerminals {
                    ForEach(Array(Set(panes.map(\.workspaceID))).sorted(), id: \.self) { workspaceID in
                        let workspace = link.snapshot?.workspaces.first { $0.id == workspaceID }
                        let noAgent = !(link.snapshot?.agents.contains { $0.workspaceID == workspaceID } ?? false)
                        Text(workspace?.displayLabel ?? workspaceID)
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
                }
            }
        }
    }

    private func didStart(_ agent: Agent, _ address: PaneAddress) {
        scene.navigationPath.append(agent.hasTranscript ? .conversation(address) : .terminal(address))
    }

    // MARK: Chrome

    private var subtitle: String {
        if allHosts { return model.enabledHostsLabel }
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
        @Bindable var scene = scene
        return Menu {
            choices("View", $settings.inboxView, InboxKind.allCases, label: \.label)
            if settings.inboxView == .agents {
                Toggle("Needs You Only", isOn: $scene.needsYouOnly)
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
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let connection: HostConnection
    let present: (SessionView.Sheet) -> Void

    private var allHosts: Bool { settings.allHosts && model.demo == nil }

    var body: some View {
        NavigationStack {
            List {
                if model.demo == nil, model.profiles.count > 1 {
                    row("All Hosts", detail: model.enabledHostsLabel, selected: allHosts) {
                        settings.allHosts = true
                    }
                }
                Section("Hosts") {
                    ForEach(model.profiles) { profile in
                        row(profile.name, detail: profile.isEnabled ? profile.address : "Off",
                            selected: !allHosts && profile.id == connection.profile.id) {
                            settings.allHosts = false
                            model.select(profile.id, in: scene)
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
                                model.selectSession(session.name, in: scene)
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

/// A folded group's summary row, the rows it opens following it in the same card. They come
/// and go at once; only the chevron turns. An animated insert keeps this row's rounded corners
/// over the arriving rows until it ends (black notches), and a fresh row per state crossfades
/// two rows (a dark flash); iOS clips a custom row background to those corners too.
private struct FoldRow: View {
    let title: String
    var systemImage: String?
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { open.toggle() } label: {
            HStack {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    // Quick and out of the gate, as the rows it opens arrive at once: an ease-in
                    // start sat still for ~80 ms after they had landed, which read as lag.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: open)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

struct AgentRow: View {
    let agent: Agent
    /// What the row shows, which may differ from the host's state: see `HostConnection.presentedStatus`.
    let status: AgentStatus
    let workspace: String?
    let unread: Bool
    var host: String? = nil
    /// Subagents last seen working in this agent's open conversation; shown only while it works.
    var subagents = 0
    /// A line of the newest message, when previews are on.
    var preview: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.conversationTitle)
                    .font(.body.weight(unread ? .semibold : .regular))
                    .lineLimit(1)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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
        let place = workspace ?? agent.workingDirectory.map { ($0 as NSString).lastPathComponent }
        let helpers = status == .working && subagents > 0 ? (subagents == 1 ? "1 subagent" : "\(subagents) subagents") : nil
        return [status.label, helpers, place, host].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TerminalRow: View {
    let pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.label ?? pane.terminalTitle ?? pane.id)
                .lineLimit(1)
            if let cwd = pane.workingDirectory {
                Text(homeRelative(cwd)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

/// The close confirmation, laid out like the system's: a title, what it does, and Close.
/// Tapping outside cancels.
private struct ClosePrompt: View {
    let title: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Close \(title)?")
                .font(.headline)
            Text("This ends the agent and its terminal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: close) {
                Text("Close").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 12)
        }
        .frame(width: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
    }
}
