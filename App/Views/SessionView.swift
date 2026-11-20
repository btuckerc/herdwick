import HerdrAPI
import SwiftUI

/// The inbox: agents that need you first, with shells and older work folded below.
/// Host chips switch between machines; the title opens host and session management.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    /// The inbox rotors' rows (`accessibilityRotor`).
    @Namespace private var rotor
    @Environment(DecisionLog.self) private var decisionLog
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let connection: HostConnection
    /// The split view's sidebar, where the open thread's row stays highlighted.
    var sidebar = false

    @State private var sheet: Sheet?
    // Folded parts of the inbox, each opened from a `FoldRow` inside its card.
    @State private var showsTerminals = false
    @State private var showsHidden = false
    @State private var showsEnded = false
    /// Sections whose idle agents are shown.
    @State private var openIdle: Set<String> = []
    @State private var closing: CloseRequest?
    @State private var renaming: Thread?
    @State private var newName = ""
    /// A lasting grant from a row's context menu, waiting on its confirmation.
    @State private var granting: GrantRequest?
    @State private var failure: Failure?
    /// Select mode: the chosen agents, by address (pane IDs repeat across hosts and sessions).
    @State private var selectionMode = false
    @State private var selection = Set<PaneAddress>()
    /// The agent each selected address held when it was selected.
    @State private var selectedStamps: [PaneAddress: AgentStamp] = [:]
    /// What the open bulk Close alert will close, taken as it opened.
    @State private var bulkTargets: [PaneAddress: AgentStamp] = [:]
    @State private var bulkConfirmation = false
    @State private var bulkRunning = false
    @State private var bulkSuccessCount = 0
    /// What was hidden when Select began: rows keep their section while selected.
    @State private var heldHidden: [PaneAddress: Bool]?
    /// Ranks the inbox holds while the user scrolls, reads below the top or selects, so rows
    /// don't move under them; nil while it follows live activity.
    @State private var heldRanks: [PaneAddress: InboxRank]?
    /// The last Hide or Mark Read, offered back for a few seconds.
    @State private var undo: InboxUndo?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The last waiting agent answered while its row still shows the receipt: the all-clear
    /// waits for the row to move, so the inbox clears in one moment, not several.
    @State private var caughtUpPending = false
    /// The moment the inbox cleared: the Needs You capsule reads "All Caught Up" for a beat
    /// before it leaves, and the all-clear's sheep hops.
    @State private var caughtUp = false
    /// The all-clear tally's glyph column, so its wrapped counts line up.
    @ScaledMetric(relativeTo: .subheadline) private var tallyGlyph = 20.0
    /// Whether the all-clear card is on screen, where it says what the bar's middle otherwise would.
    @State private var allClearInView = false
    /// Bumped with each all-clear: the sheep's hop.
    @State private var caughtUpHops = 0
    /// The row a thread was just closed back to, and a count of returns so an earlier return's
    /// timer doesn't clear a later one (`ReturnFill`).
    @State private var returnedFrom: PaneAddress?
    @State private var returns = 0
    /// Inline answers under way or just confirmed, by agent, shared with the Overview. The row
    /// keeps its place and its prompt until the receipt has shown in it, then moves.
    private var inlineAnswers: InlineAnswers { scene.inlineAnswers }
    /// The toasts' height, kept clear at the bottom of the list while they show.
    @State private var toastHeight: CGFloat = 0
    @State private var atTop = true
    @State private var scrollIdle = true
    /// Set by New Activity: scroll to the first row once the new order has been laid out.
    @State private var scrollToFirst = false
    @State private var hostSelection = 0
    @State private var startFlow = AgentStartFlow()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Retained for scripted demo navigation.
    enum Mode: String, CaseIterable, Identifiable {
        case agents = "Agents", workspaces = "Workspaces"
        var id: Self { self }
    }

    enum Sheet: Identifiable {
        case settings, hosts, addHost, editHost(HostProfile), panes
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
            case .panes: "panes"
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
                if let next { settings.inboxGrouping = next == .workspaces ? .workspace : .status }
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
            .onChange(of: demo?.showsPanes, initial: true) { _, shows in if shows == true { sheet = .panes } }
            .onChange(of: scene.showNewAgent) { _, show in
                if show { sheet = .newAgent(nil, workspace: nil); scene.showNewAgent = false }
            }
    }

    /// Split from `body`, whose single modifier chain overran the type-checker's time limit.
    private var presented: some View {
        alerts(for: unalertedContent)
    }

    private var unalertedContent: some View {
        observedContent
            .onAppear {
                settleOrder()
                for link in links { link.refreshActivity() }
            }
    }

    private var observedContent: some View {
        selectionObservedContent
            .onChange(of: selection) { recordSelectedAgents() }
            .onChange(of: authoritativeAgents) { _, current in pruneSelection(using: current) }
    }

    private var selectionObservedContent: some View {
        hostObservedContent
            .onChange(of: settings.inboxSort) { settleOrder(); endSelection() }
            .onChange(of: settings.inboxGrouping) { settleOrder(); endSelection() }
            .onChange(of: query) { endSelection() }
            .onChange(of: connection.profile.id) { endSelection() }
            .onChange(of: showsHidden) { endSelection() }
            .onChange(of: showsTerminals) { endSelection() }
            .onChange(of: showsEnded) { endSelection() }
            .onChange(of: scene.searchPresented) { endSelection() }
            .onChange(of: settings.collapseIdle) { endSelection() }
            .onChange(of: settings.allHosts) { endSelection() }
            .onChange(of: scene.needsYouOnly) { endSelection() }
    }

    private var hostObservedContent: some View {
        content
            .id(connection.profile.id)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.24), value: connection.profile.id)
            .navigationTitle(allHosts ? "All Hosts" : connection.profile.name)
            .navigationBarTitleDisplayMode(.inline)
            // The sidebar's first row names the host, large, with its address (round 54: opus#6,
            // sb#13, the bar's title named it again above it).
            .toolbar(removing: sidebar ? .title : nil)
            .toolbar { toolbar }
            .sheet(item: $sheet, content: sheetContent)
            .onChange(of: scene.selectedRoute) { old, route in
                if let route, case .terminal = route, sheet?.id == "panes" { sheet = nil }
                if !sidebar, route == nil, let old { showReturn(to: old.address) }
            }
            .modifier(AgentStartFeedback(flow: startFlow, onStarted: didStart))
            .sensoryFeedback(.warning, trigger: blockedCount) { old, new in settings.haptics && new > old }
            .sensoryFeedback(.selection, trigger: hostSelection) { _, _ in settings.haptics }
            .sensoryFeedback(.success, trigger: bulkSuccessCount) { _, _ in settings.haptics }
            .sensoryFeedback(trigger: inlineAnswers.feedback) { _, new in
                guard settings.haptics, let new else { return nil }
                return new.denied ? .impact(weight: .light) : .success
            }
            .sensoryFeedback(.error, trigger: failure?.title) { _, new in settings.haptics && new != nil }
            .onChange(of: BlockedTally(scope: allHosts ? nil : connection.profile.id, waiting: blockedAddresses), noteCaughtUp)
            .onChange(of: inlineAnswers.isEmpty) { _, released in
                if released, caughtUpPending { celebrateCaughtUp() }
            }
            // Answers given here or in the Overview fail into the inbox's one alert.
            .onChange(of: inlineAnswers.failure) { _, new in
                guard let new else { return }
                failure = Failure(title: new.title, message: new.message, open: new.open)
                inlineAnswers.failure = nil
            }
            // A Hide from a thread's menu: Undo here, as for one from the row.
            .onChange(of: scene.hiddenFromThread, initial: true) { _, address in
                guard let address else { return }
                scene.hiddenFromThread = nil
                offerUndo(.hide, [address])
            }
    }

    private func alerts<V: View>(for view: V) -> some View {
        view
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
            ), presenting: failure) { failure in
                if let route = failure.open { Button("Open Thread") { self.failure = nil; scene.open(route) } }
                Button("OK", role: .cancel) { self.failure = nil }
            } message: {
                Text($0.message)
            }
            .alert("Close \(closing?.thread.agent.conversationTitle ?? "Agent")?", isPresented: .init(
                get: { closing != nil }, set: { if !$0 { closing = nil } }
            ), presenting: closing) { request in
                Button("Close", role: .destructive) { close(request) }
                Button("Cancel", role: .cancel) { closing = nil }
            } message: { _ in
                Text("This ends the agent and its terminal.")
            }
            .alert(bulkTargets.count == 1 ? "Close 1 agent?" : "Close \(bulkTargets.count) agents?",
                   isPresented: $bulkConfirmation) {
                Button(bulkTargets.count == 1 ? "Close Agent" : "Close \(bulkTargets.count) Agents", role: .destructive) {
                    runBulk(.close, targets: bulkTargets)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(bulkCloseMessage) This cannot be undone.")
            }
            .grantConfirmation($granting, label: \.label) { answer($0.label, prompt: $0.prompt, ask: nil, in: $0.thread) }
    }

    struct Failure {
        let title: String
        let message: String
        /// Where to finish what failed (an inline approval's thread).
        var open: Route? = nil
    }

    /// A single Close the user is confirming: the agent as it was when they asked.
    struct CloseRequest {
        let thread: Thread
        let stamp: AgentStamp
    }

    struct GrantRequest {
        let thread: Thread
        let prompt: ScreenPrompt
        let label: String
    }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .settings: SettingsView()
        case .hosts: hostList
        case .addHost: AddHostView()
        case .editHost(let profile): NavigationStack { HostEditor(profile: profile) }
        case .panes:
            NavigationStack {
                PanesView()
                    .navigationTitle("Panes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Not `.confirmationAction`: that tints it as if closing committed something.
                        ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { self.sheet = nil } }
                    }
            }
        case .newAgent(let link, let workspace):
            NewAgentSheet(links: links, preferred: link ?? model.connection(in: scene), workspace: workspace) { route in scene.navigationPath.append(route) }
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
            } newAgent: { id in self.sheet = .shareNewAgent(id) }
        case .shareNewAgent(let id):
            NewAgentSheet(links: links, preferred: model.connection(in: scene)) { route in
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

    /// A rotor entry names the place as its row does, so like-named agents stay apart while
    /// choosing one (round 52: sb#2, entries were titles alone). In Needs You a question leads,
    /// as its row's words do; an approval keeps its title first, as its row does (round 77:
    /// sb#8, the rotor said "Deploy to staging" where the row said what it asked).
    private func rotorTitle(_ thread: Thread, asking: Bool = false) -> String {
        let place = AgentDock.accessibilityTitle(title: thread.agent.conversationTitle,
                                                 host: thread.connection === connection ? nil : thread.connection.profile.name,
                                                 workspace: thread.workspace?.displayLabel)
        guard asking else { return place }
        let wait = thread.connection.wait(thread.agent)
        let screen = wait?.console == nil ? wait?.prompt : nil
        guard screen?.subject == nil, let question = screen?.title ?? wait?.summary else { return place }
        return "\(question), \(place)"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selectionMode {
                let eligible = eligibleAddresses
                let all = !eligible.isEmpty && eligible.isSubset(of: selection)
                Button(all ? "Deselect All" : "Select All") {
                    if all { selection.subtract(eligible) } else { selection.formUnion(eligible) }
                }
                .keyboardShortcut("a")
                .disabled(eligible.isEmpty || bulkRunning)
            } else {
                Button(scene.searchPresented ? "Close Search" : "Search",
                       systemImage: scene.searchPresented ? "xmark" : "magnifyingglass") {
                    if scene.searchPresented { query = "" }
                    scene.searchPresented.toggle()
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if selectionMode {
                Text("\(selection.count) Selected").contentTransition(.numericText())
            } else if !sidebar {
                // Not in the iPad sidebar, whose first row is the host's large title and address
                // (round 53: opus#6, sb#13, "Inbox · studio" over "studio" named it twice).
                HostTitle(title: allHosts ? "All Hosts" : connection.profile.name) { sheet = .hosts }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selectionMode {
                Button("Cancel") { endSelection() }
                    .keyboardShortcut(.cancelAction)
            } else {
                // Mail's keys where Mail has them (⇧⌘U, ⌃⌘A); ⌘E to start (round 7: no triage
                // from a hardware keyboard past ⌘J).
                Button("Select") { beginSelection() }
                    .keyboardShortcut("e")
                    .disabled(threads.isEmpty)
            }
        }
        if !selectionMode {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { sheet = .settings }
            }
        }
        if selectionMode {
            ToolbarItem(placement: .bottomBar) {
                // Each with how many it acts on, as Close says it (round 74: sb#7, only Close
                // gave the scope of a bulk action).
                Button(counted("Mark Read", selectedThreads.count { $0.connection.isUnread($0.agent) })) { runBulk(.markRead) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    // Only with something unread chosen (round 30: on a read selection it did nothing).
                    .disabled(bulkRunning || onlyHiddenSelected || !selectedThreads.contains { $0.connection.isUnread($0.agent) })
            }
            ToolbarItem(placement: .bottomBar) {
                Button(counted(onlyHiddenSelected ? "Unhide" : "Hide", selectedThreads.count { onlyHiddenSelected || $0.connection.hidden[$0.agent.paneID] == nil })) {
                    runBulk(onlyHiddenSelected ? .unhide : .hide)
                }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                    .disabled(selection.isEmpty || bulkRunning)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { bulkCloseButton }
        } else {
            ToolbarItem(placement: .bottomBar) { viewMenu }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            if scene.needsYouOnly || blockedCount > 0 || caughtUpPending || caughtUp {
                ToolbarItem(placement: .bottomBar) { needsYouCapsule }
                if fleetBesideCount, let summary = fleetSummary {
                    ToolbarItem(placement: .bottomBar) { fleetStatus(summary) }
                        .sharedBackgroundVisibility(.hidden)
                }
            } else if !allClearInView, let summary = fleetSummary {
                ToolbarItem(placement: .bottomBar) { fleetStatus(summary) }
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Agent", systemImage: "plus") { sheet = .newAgent(nil, workspace: nil) }
            }
        }
    }

    /// The bottom bar's Needs You count, which toggles Needs You Only. While an answered row
    /// still shows its receipt it reads "Answered" in neutral (round 7: an orange "Needs You"
    /// with nothing waiting); when that row moves it turns "All Answered" for a beat before it
    /// leaves.
    private var needsYouCapsule: some View {
        // Counted as the Needs You header counts: an answer whose receipt shows no longer waits
        // (round 12: the header said 1 while this still said 2 until the host caught up).
        let waiting = waitingCount
        let cleared = caughtUp && blockedCount == 0 && !scene.needsYouOnly
        let answered = waiting == 0 && (caughtUpPending || blockedCount > 0) && !cleared && !scene.needsYouOnly
        // Beside the fleet's glyphs, its own glyph and count, as theirs are.
        let title = cleared ? caughtUpTitle : answered ? "Answered" : fleetBesideCount ? "\(waiting)" : waiting > 0 ? "Needs You \(waiting)" : "Needs You"
        return Button {
            if !cleared && !answered { scene.needsYouOnly.toggle() }
        } label: {
            HStack(spacing: 6) {
                if scene.needsYouOnly {
                    Text("Needs You Only")
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: cleared ? "checkmark.circle.fill" : answered ? "checkmark.circle" : AgentStatus.blocked.symbol)
                        .foregroundStyle(cleared ? Tokens.Tint.settled : answered ? Tokens.secondaryText : AgentStatus.blocked.tint)
                        .contentTransition(.symbolEffect(.replace))
                        // The check lands with the all-answered sheep's hop (round 17: the moment passed without notice).
                        .symbolEffect(.bounce, options: .nonRepeating, value: cleared && !reduceMotion)
                    Text(title)
                        .monospacedDigit()
                        .contentTransition(.interpolate)
                }
            }
            // On the bar's own glass alone, as its neighbours are (round 65: sa#6, a raised
            // capsule inside the glass one gave it nested edges).
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Lit green for the all-clear's beat only, the moment the app celebrates (round 74:
            // opus#1, the capsule's words changed but it read as the same grey control).
            .background(Tokens.Tint.settled.opacity(cleared ? 0.24 : 0), in: .capsule)
            .animation(reduceMotion ? nil : .snappy, value: title)
        }
        .accessibilityLabel(scene.needsYouOnly ? "Needs You Only" : cleared || answered ? title : "Needs You, \(waiting)")
        // The rest of the fleet, which the bar says when nothing waits: at accessibility sizes one
        // decision fills the screen (round 91: sb#2). Not when its glyphs stand beside, which say it.
        .accessibilityValue(scene.needsYouOnly || cleared || answered || fleetBesideCount ? "" : fleetSummary ?? "")
        .accessibilityHint(scene.needsYouOnly ? "Shows every agent" : cleared || answered ? "" : "Shows only agents that need you")
        // Answered and All Answered are status for their beat, not a control (round 75: sb#6,
        // a button that did nothing).
        .allowsHitTesting(!cleared && !answered)
        .accessibilityRemoveTraits(cleared || answered ? .isButton : [])
        .accessibilityAddTraits(cleared || answered ? .isStaticText : [])
    }

    /// One title for the whole moment (round 9: "All Caught Up" turned to "All Answered" a beat
    /// later, when the answered agent's result landed; round 7: "caught up" over an unread result).
    private let caughtUpTitle = "All Answered"

    /// At accessibility sizes, with something waiting, the fleet's glyphs beside the Needs You
    /// count, which turns glyph and number as they are (round 95: sb#4, opus#15, one question
    /// filled the screen and the bar said only "Needs You 1", the work and results out of sight).
    private var fleetBesideCount: Bool {
        dynamicTypeSize.isAccessibilitySize && !scene.needsYouOnly && waitingCount > 0
    }

    /// The all-clear card's counts, its words exactly ("1 done · 2 working (1 no update)"), for
    /// the bar and the Needs You count's spoken value; nil when there are none.
    private var fleetSummary: String? {
        let parts = tallyItems.filter { $0.id != "decided" }.map(\.words)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// With nothing waiting on you and the all-clear card scrolled away, the bar's middle keeps
    /// its counts, as Mail's says when it last checked, plain text on the bar rather than a
    /// capsule, so it doesn't read as a control (round 91: opus#7, the filter and New Agent stood
    /// apart around an empty middle; round 92: opus#4, sb#2, sb#4, under the card it repeated
    /// the card in other words, "2 Working · 1 Done" beside "1 done · 2 working (1 no update)",
    /// and counted an answered agent apart from the rest of the window).
    /// At accessibility sizes, where the words can't fit between the bar's buttons, the counts
    /// as glyphs, the hourglass apart, as the Overview's Fleet falls back (round 93: sb#3, one
    /// line cut "(1 no update)" first), and the read ones after them, as the Overview's legend
    /// ends (round 95: sb#1, sa#9, three read agents below the fold were missing from the bar).
    /// VoiceOver hears the words either way, and a long press shows them, as the bar's buttons do
    /// (round 95: opus#5, a lone hourglass and number didn't say what they counted).
    private func fleetStatus(_ summary: String) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let read = large ? count(.idle) : 0
        let spoken = read > 0 ? "\(summary) · \(read) read" : summary
        return Group {
            if large {
                HStack(spacing: fleetBesideCount ? Tokens.Space.s : Tokens.Space.m) {
                    ForEach(fleetGlyphs + (read > 0 ? [(symbol: AgentStatus.idle.symbol, tint: Tokens.secondaryText, count: read)] : []), id: \.symbol) { glyph in
                        Label { Text("\(glyph.count)") } icon: { Image(systemName: glyph.symbol).foregroundStyle(glyph.tint) }
                            .labelStyle(.titleAndIcon)
                    }
                }
                // Beside the count, at the bar's own largest size, so all of them fit.
                .dynamicTypeSize(...(fleetBesideCount ? DynamicTypeSize.xxLarge : .accessibility5))
                .fixedSize()
            } else {
                Text(summary).lineLimit(1)
            }
        }
        .font(.footnote.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(Tokens.secondaryText)
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .snappy, value: spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityShowsLargeContentViewer { Text(spoken) }
    }

    /// `fleetSummary` as glyphs: done, live work, and work gone still under the hourglass.
    private var fleetGlyphs: [(symbol: String, tint: Color, count: Int)] {
        let still = stillCount
        return [(AgentStatus.done.symbol, AgentStatus.done.tint, count(.done)),
                (AgentStatus.working.symbol, AgentStatus.working.tint, count(.working) - still),
                (AgentStatus.stillSymbol, Tokens.secondaryText, still)].filter { $0.count > 0 }
    }

    /// What Select All takes: the agents on screen, offscreen rows included, folded idle and
    /// Hidden only when opened. Never shells or ended agents.
    private var eligibleAddresses: Set<PaneAddress> {
        let shown = sections(held: heldRanks != nil)
        var rows = shown.needsYou + shown.sections.flatMap { section in
            section.threads + (openIdle.contains(section.id) ? section.idle : [])
        }
        if showsHidden { rows += shown.hidden }
        return Set(rows.map(\.address))
    }

    private var selectedThreads: [Thread] {
        model.threads.filter { selection.contains($0.address) }
    }

    /// Hide and Unhide don't mix: a selection of only hidden agents offers Unhide.
    private var onlyHiddenSelected: Bool {
        !selectedThreads.isEmpty && selectedThreads.allSatisfy { $0.connection.hidden[$0.agent.paneID] != nil }
    }

    private func beginSelection() {
        closing = nil
        if heldRanks == nil { heldRanks = liveRanks }
        heldHidden = Dictionary(threads.map { ($0.address, $0.connection.hidden[$0.agent.paneID] != nil) },
                                uniquingKeysWith: { first, _ in first })
        selection = []
        // Quick, as the system's own Select is (round 84: opus#3, the default snappy settled in 850 ms).
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { selectionMode = true }
        scene.inboxSelecting = true
    }

    private func endSelection() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            selectionMode = false
            selection = []
            heldHidden = nil
        }
        scene.inboxSelecting = false
        if atTop && scrollIdle { heldRanks = nil }
    }

    /// The selection's addresses with the agent each held when picked.
    private func selectionTargets() -> [PaneAddress: AgentStamp] {
        recordSelectedAgents()
        return selectedStamps.filter { selection.contains($0.key) }
    }

    /// Runs on `targets` (by default the selection as it stands now); what succeeds leaves the
    /// selection, failures stay selected.
    private func runBulk(_ operation: BulkTriage.Operation, targets: [PaneAddress: AgentStamp]? = nil) {
        let targets = targets ?? selectionTargets()
        // Undo restores only what this changed: unread marks on those that had them.
        let unread = Set(model.threads.filter { targets[$0.address] != nil && $0.connection.isUnread($0.agent) }.map(\.address))
        bulkRunning = true
        Task {
            let result = await BulkTriage.perform(operation, targets: targets, model: model)
            bulkRunning = false
            if !result.succeeded.isEmpty { bulkSuccessCount += 1 }
            switch operation {
            case .hide: offerUndo(.hide, Array(result.succeeded))
            case .markRead: offerUndo(.markRead, Array(result.succeeded.intersection(unread)))
            default: break
            }
            if result.failures.isEmpty {
                if selectionMode { endSelection() }
            } else {
                if selectionMode { selection = Set(result.failures.map(\.address)) }
                failure = Failure(title: result.failures.count == 1 ? "Couldn't Update 1 Agent" : "Couldn't Update \(result.failures.count) Agents",
                                  message: result.failures.map { "\($0.title): \($0.message)" }.joined(separator: "\n"))
            }
        }
    }

    /// A bulk action's title with the number it would act on, when there are any.
    private func counted(_ verb: String, _ count: Int) -> String {
        count == 0 ? verb : "\(verb) (\(count))"
    }

    private var bulkCloseButton: some View {
        Button(counted("Close", selection.count), role: .destructive) {
            closing = nil
            bulkTargets = selectionTargets()
            bulkConfirmation = !bulkTargets.isEmpty
        }
        .tint(.red)
        .disabled(selection.isEmpty || bulkRunning)
    }

    /// Offers the last Hide or Mark Read back. One that comes while an Undo still shows joins it,
    /// so Undo restores both (round 42: sb#14, each new one replaced the last, and a quick second
    /// slip lost the first's recovery). Each agent's stamp is kept, so Undo never touches another
    /// agent that has since taken its pane.
    private func offerUndo(_ kind: InboxUndo.Kind, _ addresses: [PaneAddress]) {
        guard !addresses.isEmpty else { return }
        let wanted = Set(addresses)
        let stamps = Dictionary(model.threads.compactMap { thread in
            wanted.contains(thread.address) ? thread.stamp.map { (thread.address, $0) } : nil
        }, uniquingKeysWith: { first, _ in first })
        var changes = undo?.changes ?? []
        changes.append(InboxUndo.Change(kind: kind, addresses: addresses, stamps: stamps))
        let next = InboxUndo(changes: changes, message: undoMessage(changes))
        undo = next
        AccessibilityNotification.Announcement("\(next.message). Undo available.").post()
    }

    /// "Hid “Fix flaky retry test”", "Hid 2 agents", or both kinds: "Hid 1 · Marked 2 read".
    private func undoMessage(_ changes: [InboxUndo.Change]) -> String {
        func agents(_ kind: InboxUndo.Kind) -> [PaneAddress] { changes.filter { $0.kind == kind }.flatMap(\.addresses) }
        let hidden = agents(.hide), read = agents(.markRead)
        let all = hidden + read
        let one = all.count == 1
            ? model.threads.first { $0.address == all[0] }.map { "\u{201C}\($0.agent.conversationTitle)\u{201D}" }
            : nil
        if read.isEmpty { return "Hid \(one ?? "\(hidden.count) agents")" }
        if hidden.isEmpty { return "Marked \(one ?? "\(read.count)") read" }
        return "Hid \(hidden.count) · Marked \(read.count) read"
    }

    /// Looks each agent up again: it may have ended, or another may have taken its pane (round
    /// 10: Undo went by pane alone and could mark a newcomer unread). Newest first.
    private func performUndo() {
        guard let undo else { return }
        self.undo = nil
        for change in undo.changes.reversed() {
            for (address, stamp) in change.stamps {
                guard let link = model.connection(for: address),
                      let agent = link.snapshot?.agents.first(where: { $0.paneID == address.paneID }),
                      link.stamp(of: agent) == stamp else { continue }
                switch change.kind {
                case .hide: link.unhide(agent)
                case .markRead: link.markUnread(agent)
                }
            }
        }
    }

    /// Opaque capsules over the bottom bar, so the row under them doesn't show through. Undo:
    /// what happened, and Undo (⌘Z), gone after 5 s (12 s with VoiceOver, which also hears it
    /// announced, or at accessibility sizes; round 10: those readers had 5 s too), counted
    /// again from the newest triage it holds.
    private var toast: some View {
        VStack(spacing: Tokens.Space.s) {
            if let undo {
                toastCapsule {
                    Text(undo.message).font(.subheadline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Button("Undo", action: performUndo).font(.subheadline.weight(.semibold))
                        .keyboardShortcut("z", modifiers: .command)
                }
                .task(id: undo.id) {
                    let long = UIAccessibility.isVoiceOverRunning || dynamicTypeSize.isAccessibilitySize
                    try? await Task.sleep(for: .seconds(long ? 12 : 5))
                    if !Task.isCancelled, self.undo?.id == undo.id { self.undo = nil }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.bottom, Tokens.Space.s)
        .frame(maxWidth: .infinity)
        // The page fades in behind it, the bottom edge's fade grown to its top, so rows don't
        // show cut off on both sides of it (round 7).
        .background(alignment: .bottom) {
            if undo != nil && !sidebar {
                LinearGradient(stops: [.init(color: Tokens.Surface.base.opacity(0), location: 0),
                                       .init(color: Tokens.Surface.base, location: 0.5)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -Tokens.Space.xl)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private func toastCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Tokens.Space.m) { content() }
            .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 10)
            .frame(minHeight: Tokens.minTap)
            .background(Tokens.Surface.raised, in: .capsule)
            // The shadow is lost on a dark page; a hairline keeps the edge.
            .overlay { Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    /// The last waiting agent answered (not filtered away, not a host switch). With a row still
    /// holding its receipt, the moment waits for it to move (round 6: a toast, the capsule
    /// leaving, the row moving and the all-clear came as four separate updates).
    private func noteCaughtUp(_ old: BlockedTally, _ new: BlockedTally) {
        guard old.scope == new.scope, new.count == 0 else {
            caughtUpPending = false
            return
        }
        guard old.count > 0, links.allSatisfy(\.isLive) else { return }
        // Answered, not put away: one hidden or being closed left the count with no answer given
        // (round 65: sb#1, hiding the last waiting agent played the all-clear).
        let listed = Set(model.dockThreads(in: scene).map(\.address))
        guard old.waiting.contains(where: listed.contains) else { return }
        if inlineAnswers.isEmpty { celebrateCaughtUp() } else { caughtUpPending = true }
    }

    /// One moment: the all-clear lights up with today's tally for a beat, its sheep signs off
    /// with a check and hops once, and the Needs You capsule turns to "All Answered", then the
    /// light settles back (round 7: the beat was a 34 pt sheep in a plain list row). What's still at work
    /// is the all-clear row's, which stays current; a count frozen in the capsule would
    /// disagree with it once an agent finished.
    private func celebrateCaughtUp() {
        caughtUpPending = false
        guard blockedCount == 0 else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth) { caughtUp = true }
        // The all-clear row's tally in its own words, the working count always (round 31: the
        // announcement said results to read and nothing of two agents still at work; round 68:
        // opus#9, sb#4, it said "1 result to read" under a row that said "1 done").
        let tally = tallyItems.map(\.words)
        AccessibilityNotification.Announcement((["All answered"] + (tally.isEmpty ? [] : [tally.joined(separator: ", ")]))
            .joined(separator: ". ")).post()
        Task {
            // The all-clear row is inserted in this same update and fades in over the receipt it
            // replaces; the hop and its burst wait until it's whole (round 71: opus#1, at 250 ms
            // the burst played over the half-faded row).
            try? await Task.sleep(for: .milliseconds(450))
            if !reduceMotion { caughtUpHops += 1 }
            try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 4 : 2))
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth) { caughtUp = false }
        }
    }

    private var bulkCloseMessage: String {
        let count = bulkTargets.count
        let hosts = Set(bulkTargets.keys.map(\.hostID)).count
        let needsYou = model.threads.filter {
            bulkTargets[$0.address] != nil && $0.connection.presentedStatus($0.agent) == .blocked
        }.count
        var parts = [count == 1 ? "Ends 1 agent and its terminal." : "Ends \(count) agents and their terminals."]
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 of them needs you." : "\(needsYou) of them need you.") }
        if hosts > 1 { parts.append("On \(hosts) hosts.") }
        return parts.joined(separator: " ")
    }

    private var enabledHostCount: Int { model.profiles.filter(\.isEnabled).count }

    /// One chip per host that's on, and All: switching is a tap, never a hidden gesture.
    private var hostChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    hostChip("All", selected: allHosts, live: model.connections.contains(where: \.isLive),
                             connecting: model.connections.contains(where: \.isConnecting)) {
                        settings.allHosts = true
                        hostSelection += 1
                    }
                    ForEach(model.profiles.filter(\.isEnabled)) { profile in
                        let link = model.connections.first { $0.profile.id == profile.id }
                        hostChip(profile.name, selected: !allHosts && profile.id == connection.profile.id,
                                 live: link?.isLive == true, connecting: link?.isConnecting == true,
                                 failed: link?.isFailed == true) {
                            settings.allHosts = false
                            model.select(profile.id, in: scene)
                            hostSelection += 1
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.l)
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func hostChip(_ title: String, selected: Bool, live: Bool, connecting: Bool = false,
                          failed: Bool = false, action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 6) {
            Circle().fill(live ? Color.green : connecting ? Color.blue : failed ? Color.red : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
        if selected {
            Button(action: action) { label }
                .primaryAction()
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action) { label }
                .floatingControl()
        }
    }

    /// The agents each live link's snapshot has, by host and session (a host can have a link per
    /// session in All Hosts) and pane, stamped: an address whose agent was replaced is no longer
    /// the one selected.
    private var authoritativeAgents: [SessionAddress: [PaneAddress: AgentStamp]] {
        Dictionary(links.filter(\.isLive).map { link in
            (link.identity, Dictionary((link.snapshot?.agents ?? []).compactMap { agent in
                link.stamp(of: agent).map { (link.address(paneID: agent.paneID), $0) }
            }, uniquingKeysWith: { first, _ in first }))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func pruneSelection(using snapshots: [SessionAddress: [PaneAddress: AgentStamp]]) {
        let kept = selection.filter { address in
            guard let current = snapshots[SessionAddress(hostID: address.hostID, session: address.session)],
                  let stamp = selectedStamps[address] else { return true }
            return current[address] == stamp
        }
        if kept != selection { selection = kept }
    }

    /// Remembers which agent each newly selected address held, so a bulk action never reaches
    /// an agent that replaced it in the same pane.
    private func recordSelectedAgents() {
        selectedStamps = selectedStamps.filter { selection.contains($0.key) }
        for address in selection where selectedStamps[address] == nil {
            guard let stamp = model.threads.first(where: { $0.address == address })?.stamp else { continue }
            selectedStamps[address] = stamp
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
            // The newest message matches with previews off too: hiding the line is for density.
            // So do the harness and status words and a working agent's step, as the row shows
            // them (round 27: "Codex" found nothing; round 28: nor did the command a row ran).
            [thread.agent.conversationTitle, thread.workspace?.label, thread.agent.workingDirectory, thread.connection.profile.name,
             thread.connection.wait(thread.agent)?.summary, thread.connection.preview(thread.agent), thread.connection.step(thread.agent),
             thread.agent.agent.map(agentKindLabel), scene.shownStatus(thread).label]
                .contains { $0?.localizedStandardContains(query) == true }
        }
    }
    private var liveRanks: [PaneAddress: InboxRank] {
        Dictionary(threads.map { ($0.address, inboxRank($0)) }) { first, _ in first }
    }

    /// Follows live activity at the top of a resting list; anywhere else holds the order it has.
    private func holdIfBrowsing() {
        guard !selectionMode else { return }
        if atTop && scrollIdle { heldRanks = nil } else if heldRanks == nil { heldRanks = liveRanks }
    }

    /// Shows the current order: on return to the inbox, a sort or grouping change, or on request.
    private func settleOrder() {
        heldRanks = atTop && scrollIdle ? nil : liveRanks
    }

    /// Held, rows keep their rank, section and Hidden membership; while selecting, an agent that
    /// arrives goes to the end rather than between held rows. A row answered inline keeps its
    /// place either way until its receipt has shown. `of` lays out other threads the same way
    /// (the Needs You Only card's unfiltered working agents).
    private func sections(held: Bool, of list: [Thread]? = nil) -> (needsYou: [Thread], sections: [InboxSection], hidden: [Thread]) {
        let ranks = held ? heldRanks : nil
        let arrival = InboxRank(priority: Int.max, lastTurnAt: .distantPast)
        return inboxSections(
            list ?? threads,
            grouping: settings.inboxGrouping,
            sort: settings.inboxSort,
            collapseIdle: settings.collapseIdle,
            allHosts: allHosts,
            heldStatus: { thread in
                guard let priority = (inlineAnswers[thread.address]?.rank ?? ranks?[thread.address])?.priority else {
                    return thread.connection.presentedStatus(thread.agent)
                }
                return status(for: priority)
            },
            rank: { thread in
                inlineAnswers[thread.address]?.rank ?? ranks?[thread.address]
                    ?? (held && selectionMode ? arrival : inboxRank(thread))
            },
            hidden: { thread in
                heldHidden?[thread.address] ?? (thread.connection.hidden[thread.agent.paneID] != nil)
            }
        )
    }

    /// The status a held rank stands for (see `inboxRank`).
    private func status(for priority: Int) -> AgentStatus {
        switch priority {
        case 0: .blocked
        case 1: .done
        case 2: .working
        case 3: .idle
        default: .unknown
        }
    }

    private static func order(_ result: (needsYou: [Thread], sections: [InboxSection], hidden: [Thread])) -> [PaneAddress] {
        (result.needsYou + result.sections.flatMap { $0.threads + $0.idle } + result.hidden).map(\.address)
    }

    /// Off the list at once, the rows below closing the gap, while herdr ends it; back with an
    /// alert if herdr refuses. Only the agent the user asked about: if it has since left its
    /// pane, nothing is sent (and if another took its place, they're told).
    private func close(_ request: CloseRequest) {
        closing = nil
        let connection = request.thread.connection
        guard let task = withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), { connection.close(request.stamp) }) else {
            if connection.snapshot?.agents.contains(where: { $0.paneID == request.stamp.paneID }) == true {
                failure = Failure(title: "Nothing Closed",
                                  message: "\(request.thread.agent.conversationTitle) ended, and another agent is running in its place.")
            }
            return
        }
        Task {
            if case .failure(let error) = await task.result {
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
                    .primaryAction()
            }
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
                .floatingControl()
        }
    }

    // MARK: Inbox

    private var inboxList: some View {
        let (shown, order, newActivity) = RenderTrace.measure("inbox.project") {
            let shown = sections(held: heldRanks != nil)
            let order = Self.order(shown)
            return (shown, order, heldRanks != nil && Self.order(sections(held: false)) != order)
        }
        return ScrollViewReader { proxy in
            // No list selection: rows open their route themselves (`opener`).
            List {
                // The sidebar's bar has no room for the title between its buttons: it heads the list.
                if sidebar {
                    sidebarTitle
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    Button {
                        scene.selectedRoute = nil
                    } label: {
                        Label("Overview", systemImage: "square.grid.2x2")
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .background {
                                // Inset 8 pt, as a selected agent row's fill is (round 55:
                                // opus#7, flush to the sidebar's edge the two selections disagreed).
                                if scene.selectedRoute == nil {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.selectionFill)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Overview")
                    .accessibilityAddTraits(scene.selectedRoute == nil ? .isSelected : [])
                    .disabled(selectionMode)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
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
                inbox(shown)
            }
            .listStyle(.plain)
            .accessibilityRotor("Needs You") {
                ForEach(shown.needsYou.filter { scene.shownStatus($0) == .blocked }) { thread in
                    AccessibilityRotorEntry(Text(rotorTitle(thread, asking: true)), id: thread.address, in: rotor)
                }
            }
            .accessibilityRotor("Working") {
                // Under Needs You Only, the filter card's named rows (round 40: sb#5, the rotor
                // was empty while the card listed agents at work).
                ForEach(scene.needsYouOnly ? Array(workingAgents.prefix(3))
                        : shown.sections.flatMap(\.threads).filter { scene.shownStatus($0) == .working }) { thread in
                    AccessibilityRotorEntry(Text(rotorTitle(thread)), id: thread.address, in: rotor)
                }
            }
            .accessibilityRotor("Unread Results") {
                ForEach(shown.sections.flatMap(\.threads).filter {
                    scene.shownStatus($0) == .done && $0.connection.isUnread($0.agent)
                }) { thread in
                    AccessibilityRotorEntry(Text(rotorTitle(thread)), id: thread.address, in: rotor)
                }
            }
            // space (round 7: ~40 pt from a section's last rule to the next header).
            .listSectionSpacing(0)
            // Headers no taller than their line, so more rows sit above the fold (round 6).
            .environment(\.defaultMinListHeaderHeight, 0)
            // Needs You starts just under the bar, not under a band of the list's own top
            // margin (round 21: ~50 pt of nothing between the title and the first section).
            .contentMargins(.top, 0, for: .scrollContent)
            .edgeFade(.top, enabled: !sidebar)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    if enabledHostCount > 1 { hostChips }
                    if scene.searchPresented { searchBar }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Room for a toast, so the last rows can scroll out from under it.
                // Extra scroll room keeps the expanded Needs You answer clear of the toolbar fade (round 39: opus#15, sa#4, sb#6).
                Color.clear.frame(height: 28 + (undo != nil ? toastHeight : 0) + (!sidebar && dynamicTypeSize.isAccessibilitySize ? 160 : 0))
            }
            // Solid under the bar and the toast, fading only over the last 12 pt of the room
            // above the bar, so rows aren't erased while they could still be read.
            .edgeFade(.bottom, within: 12, enabled: !sidebar)
            .overlay(alignment: .bottom) {
                toast.onGeometryChange(for: CGFloat.self, of: \.size.height) { toastHeight = $0 }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy, value: undo?.id)
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
                    if newActivity && !selectionMode {
                        // Floats over the list rather than inserting a row, so nothing shifts.
                        Button("New Activity", systemImage: "arrow.up") {
                            // Shows the new order but stays held: scrollTo stops at the first row with the
                            // header under the bar, short of the top where live reordering is visible.
                            heldRanks = liveRanks
                            scrollToFirst = true
                        }
                        .floatingControl()
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: newActivity)
            }
        }
    }

    /// The host as the sidebar's large title, as Mail's sidebar names its account; a tap opens
    /// the Hosts sheet, as the phone's title does. Selecting says how many instead.
    private var sidebarTitle: some View {
        Button { sheet = .hosts } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(selectionMode ? "\(selection.count) Selected" : allHosts ? "All Hosts" : connection.profile.name)
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    if !selectionMode {
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !subtitle.isEmpty, !selectionMode {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(selectionMode)
        .padding(.horizontal, 20)
        .accessibilityHint(selectionMode ? "" : "Shows hosts and sessions")
    }

    /// Opened from the toolbar's magnifying glass (or ⌘F), which becomes ✕ to close and clear it.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // Short, as Mail's is; what it matches is in the hint (round 12: the four fields
            // crowded the field like a form's label; round 14: "and messages" promised a search of
            // conversations when only the latest line is matched).
            TextField("Search agents", text: $query)
                .accessibilityHint("Matches agent names, workspaces, folders, hosts, agent types, statuses, pending questions, current steps and the latest message.")
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
        if !result.needsYou.isEmpty {
            // A row held for its receipt keeps its place but no longer needs you; with only
            // receipts left the lane says "Answered" (round 9: "Needs You" over a Working row).
            let waiting = result.needsYou.count { inlineAnswers[$0.address]?.receipt == nil }
            Section { rows(result.needsYou, attention: true) } header: {
                sectionHeader(waiting > 0 ? "Needs You" : "Answered", count: waiting > 0 ? waiting : nil)
            }
        } else if !result.sections.isEmpty, query.isEmpty, links.allSatisfy(\.isLive) {
            // Said only when every host shown has answered: an all-clear with one away isn't.
            Section { allClear }
        }
        ForEach(result.sections) { section in
            Section {
                rows(section.threads)
                if !section.idle.isEmpty {
                    FoldRow(title: "\(section.idle.count) Read", systemImage: AgentStatus.idle.symbol, open: Binding {
                        openIdle.contains(section.id)
                    } set: { open in
                        if open { openIdle.insert(section.id) } else { openIdle.remove(section.id) }
                    })
                    if openIdle.contains(section.id) { rows(section.idle) }
                }
            // Every section counts its rows, as Needs You does (round 6: the all-clear dropped its
            // working count on the strength of a header that didn't have one); a working section
            // says how many of them have gone still, as Overview's legend does (round 76: sb#5,
            // opus#9, "Working 2" here beside Overview's "2 working (1 no update)").
            } header: { sectionHeader(section.title, count: section.threads.count + section.idle.count, still: stillCount(section)) }
        }
        if result.needsYou.isEmpty && result.sections.isEmpty && result.hidden.isEmpty && !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if result.needsYou.isEmpty && result.sections.isEmpty && result.hidden.isEmpty {
            // "No agents" only from a host that answered; while the first attempts run the
            // status lines above say so, and once every host is down, offer the way back.
            if links.contains(where: \.isLive) {
                VStack(spacing: Tokens.Space.s) {
                    HerdMark(size: 64, mood: scene.needsYouOnly ? .quiet : .idle)
                        .padding(.bottom, Tokens.Space.s)
                    Text(scene.needsYouOnly ? "All quiet" : "No agents yet").font(.title3.weight(.semibold))
                    Text(scene.needsYouOnly ? "Nothing needs you right now." : "Start one and it shows up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !scene.needsYouOnly {
                        Button("New Agent", systemImage: "plus") { sheet = .newAgent(nil, workspace: nil) }
                            .primaryAction()
                            .padding(.top, Tokens.Space.s)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .listRowBackground(Color.clear)
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
        if scene.needsYouOnly, query.isEmpty { filteredOut }
        // Needs You Only is a triage view: shells and ended agents never need you.
        ForEach(links, id: \.identity) { link in
            if query.isEmpty, !scene.needsYouOnly, let snapshot = link.snapshot {
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
        if !ended.isEmpty, !scene.needsYouOnly {
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

    /// Sentence-case headline, as in Reminders' lists, not tiny caps. `Color.primary`: the
    /// hierarchical `.primary` is relative to the header's own secondary style and came out grey.
    /// Spaced from the section above, close to its own rows (round 6: the plain list's header
    /// padding left ~45 pt between a header and its first row).
    private func sectionHeader(_ title: String, count: Int? = nil, still: Int = 0) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Color.primary)
            if let count {
                let note = still > 0 ? Text(" (\(still) no update)").font(.subheadline) : Text("")
                Text("\(count)\(note)").foregroundStyle(Color.secondary).monospacedDigit()
            }
        }
        .font(.headline)
        // Grows to the first accessibility size, no further: the rows under it carry the words
        // (round 29: at Accessibility XL the header and the card left Other Answer in the fade).
        // Closer under the bar there, the card's room before the first screen ends (round 77:
        // sa#3, sb#3, opus#7, Other Answer sat in the bottom fade again).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: dynamicTypeSize.isAccessibilitySize ? Tokens.Space.xs : Tokens.Space.l,
                                  leading: 20, bottom: Tokens.Space.xs, trailing: 20))
    }

    /// How many of a working section's agents have gone still; none for a section that isn't all
    /// working (grouped by workspace or host, a count in brackets would read as that group's).
    private func stillCount(_ section: InboxSection) -> Int {
        guard !section.threads.isEmpty, section.idle.isEmpty,
              section.threads.allSatisfy({ scene.shownStatus($0) == .working }) else { return 0 }
        return section.threads.count { $0.connection.quiet($0.agent) != nil && inlineAnswers[$0.address] == nil }
    }

    /// Where Needs You would be, when nobody does: the herd at rest, what's left to read and
    /// what's still working, in one row under no header (round 7: a Needs You header over
    /// nothing pushed the unread result down); the working count even where the Working header
    /// says it, as VoiceOver hears it (round 32: the row said less than its announcement). The
    /// moment the last wait clears it lights up green as "All answered"
    /// with today's tally for a beat (`caughtUp`), then settles back, at one height throughout
    /// (round 8: growing into a card and back moved every section below it twice). Once
    /// anything was decided today it stays "All answered" (round 10: it turned to "Nothing
    /// needs you" a beat after the moment, a second title for one state).
    private var allClear: some View {
        let items = tallyItems, parts = items.map(\.words)
        let decided = decisionLog.decidedToday(in: links.map(\.identity))
        let title = caughtUp || decided > 0 ? "All answered" : "Nothing needs you"
        let detail = parts.isEmpty ? "You're all caught up" : parts.joined(separator: " · ")
        return HStack(spacing: Tokens.Space.m) {
            // Clearing the last wait is the app's one celebration: the sheep signs off with the
            // Done card's check, then hops once (round 15: graders found no
            // signature moment; the swell and double hop shared nothing with the Done card).
            Group {
                if title == "All answered" { HerdSeal(size: 44, play: caughtUp, ring: Tokens.Surface.raised) } else { HerdMark(size: 44, mood: .done) }
            }
            .keyframeAnimator(initialValue: Hop(), trigger: caughtUpHops) { mark, hop in
                mark.offset(y: hop.lift).rotationEffect(.degrees(hop.tilt), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.lift) {
                    SpringKeyframe(-8, duration: 0.14)
                    SpringKeyframe(0, duration: 0.18)
                }
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(-5, duration: 0.14)
                    CubicKeyframe(0, duration: 0.18)
                }
            }
            // A ring and a scatter of the Done card's green off the sheep as it hops, Things'
            // check burst at the herd's scale (round 70: opus#2, the moment was a tint and a
            // hop, too static for the app's one celebration). Not under Reduce Motion, where it
            // doesn't hop.
            .background { CaughtUpBurst(trigger: caughtUpHops).allowsHitTesting(false).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .contentTransition(.interpolate)
                if parts.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(Tokens.secondaryText)
                } else {
                    tally(parts: items)
                }
            }
            Spacer(minLength: 0)
        }
        // The bar's middle repeats these counts only once this card is out of sight (round 92:
        // opus#4). On the row's content: after the row's background they took its plate (round 93:
        // opus#5, sa#2, sb#2).
        .onScrollVisibilityChange(threshold: 0.3) { allClearInView = $0 }
        .onDisappear { allClearInView = false }
        .padding(.vertical, Tokens.Space.m)
        // The Needs You card's plate, at rest too, the slot the last card left (round 63: sa#15,
        // opus#3, at rest it read as one more list row, the moment's wash the only trace of it).
        .listRowBackground(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Surface.raised)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Color.green.opacity(caughtUp ? 0.14 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        )
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: caughtUpHops) { _, _ in settings.haptics }
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        // The row's tally, the working count included (round 23: VoiceOver heard "All answered,
        // 1 decided today" and nothing of two at work).
        .accessibilityLabel(([title] + (parts.isEmpty ? [detail] : parts)).joined(separator: ", "))
    }

    /// The all-clear's counts in the Overview legend's words and glyphs ("1 done", "2 working (1
    /// no update)"), wrapping between counts and never inside one (round 65: opus#3, sa#4, one
    /// grey sentence wrapped mid-count); decisions in grey, a reply arrow, not a second green
    /// check; the glyphs in one width, so wrapped counts line up (round 66: opus#5, sa#5). The
    /// still agents inside the working count, as the legend has them (round 67: opus#3, sa#4,
    /// sb#5, "2 working" beside "1 with no update" read as three agents, and the iPad said it
    /// another way). The row, its label and the announcement say these same words.
    private var tallyItems: [(id: String, symbol: String, tint: Color, words: String)] {
        let decided = decisionLog.decidedToday(in: links.map(\.identity))
        let done = count(.done), working = count(.working), still = stillCount
        var items: [(id: String, symbol: String, tint: Color, words: String)] = []
        if decided > 0 { items.append(("decided", "arrowshape.turn.up.left", Tokens.secondaryText, "\(decided) decided today")) }
        if done > 0 { items.append(("done", AgentStatus.done.symbol, AgentStatus.done.tint, "\(done) done")) }
        if working > 0 {
            items.append(("working", AgentStatus.working.symbol, AgentStatus.working.tint,
                          "\(working) working" + (still > 0 ? " (\(still) no update)" : "")))
        }
        return items
    }

    private func tally(parts items: [(id: String, symbol: String, tint: Color, words: String)]) -> some View {
        Flow(spacing: Tokens.Space.m, lineSpacing: Tokens.Space.xs) {
            ForEach(items, id: \.id) { item in
                Label {
                    Text(item.words)
                } icon: {
                    Image(systemName: item.symbol).foregroundStyle(item.tint).frame(width: tallyGlyph)
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Tokens.secondaryText)
    }

    /// Working agents gone still ("no update 6m") across the hosts shown, said apart in the
    /// tallies as the iPad Overview says them (round 49: sb#8, "2 working" there, "2 working (1
    /// with no update)" beside it).
    private var stillCount: Int {
        links.reduce(0) { count, link in
            count + Self.listed(link).count { link.presentedStatus($0) == .working && link.quiet($0) != nil }
        }
    }

    /// Agents shown as `status` across the hosts shown, as the lanes, the dock and the Overview
    /// count them (round 64: sb#1, a hidden agent still counted here).
    private func count(_ status: AgentStatus) -> Int {
        links.reduce(0) { count, link in count + Self.listed(link).count { link.presentedStatus($0) == status } }
    }

    /// A host's agents the lanes list: hidden ones not, nor one being closed (round 65: sb#3,
    /// the tally still counted an agent whose row the close had already taken).
    private static func listed(_ link: HostConnection) -> [Agent] {
        (link.snapshot?.agents ?? []).filter { link.hidden[$0.paneID] == nil && !link.closing.contains($0.paneID) }
    }

    /// Under Needs You Only: what the filter leaves out, and the way back to it (round 12: one
    /// card over an empty screen gave no sign that anything else existed), counted by the
    /// inbox's own lanes (round 33: "3 done" for agents its unfiltered lane calls Read). The work
    /// under way shows by name with its step, a line each, as a card (round 36: a footnote over
    /// 60 % of an empty screen).
    @ViewBuilder private var filteredOut: some View {
        let working = workingAgents
        let named = working.prefix(3)
        // What the card names isn't counted again as left out (round 38: "2 working · 3 read not
        // shown" under the two working agents it had just listed).
        let more = working.count - named.count
        let parts = (more > 0 ? ["\(more) more working"] : []) + [AgentStatus.done, .idle].compactMap { status in
            let n = count(status)
            return n > 0 ? "\(n) \(status.section.lowercased())" : nil
        }
        if !parts.isEmpty || !named.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(Array(named.enumerated()), id: \.offset) { _, item in
                        filteredWorkingRow(item)
                    }
                    if !parts.isEmpty {
                        Text("\(parts.joined(separator: " · ")) not shown")
                            .font(.footnote).foregroundStyle(Tokens.secondaryText)
                    }
                    Button("Show All Agents") { scene.needsYouOnly = false }
                        .inlineAction()
                        .frame(minHeight: Tokens.minTap)
                }
                .padding(.top, Tokens.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The Needs You card's plate, edge for edge (round 38: an inset plate of its own
                // sat 15 pt narrower than the card above it).
                .listRowBackground(
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Tokens.Surface.raised)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                )
                .listRowSeparator(.hidden)
            }
        }
    }

    /// The agents at work, in the unfiltered Working lane's order and with its workspace names
    /// (round 39: sb#8, sb#4, snapshot order and the folder's name disagreed with the inbox).
    private var workingAgents: [Thread] {
        sections(held: false, of: model.scopedThreads(in: scene)).sections.flatMap(\.threads)
            .filter { $0.connection.presentedStatus($0.agent) == .working }
    }

    /// A working agent in the filter's card opens its transcript or terminal (round 38: named
    /// work must be actionable); its place disambiguates the title.
    private func filteredWorkingRow(_ thread: Thread) -> some View {
        let link = thread.connection
        let agent = thread.agent
        let still = link.stillSince(agent).flatMap { AgentRow.quiet(since: $0, at: .now) }
        // How long it's been at it, as the Working lane's row ends it (round 90: sb#4).
        let age = still == nil ? link.workingSince(agent, status: .working).flatMap { AgentRow.working(since: $0, at: .now) } : nil
        let step = link.rowLine(agent, status: .working, previews: settings.inboxPreviews)
        let place = [thread.workspace?.displayLabel ?? "Workspace", agent.agent.map(agentKindLabel)]
            .compactMap { $0 }.joined(separator: " · ")
        let hosts = Set(workingAgents.map { $0.connection.profile.id })
        let location = hosts.count > 1 ? "\(link.profile.name) · \(place)" : place
        return Button {
            let address = link.address(paneID: agent.paneID)
            scene.open(agent.hasTranscript ? .conversation(address) : .terminal(address))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                Image(systemName: still != nil ? AgentStatus.stillSymbol : AgentStatus.working.symbol)
                    .foregroundStyle(still != nil ? Tokens.secondaryText : AgentStatus.working.tint)
                    .font(.subheadline)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.conversationTitle).font(.subheadline)
                    Text([location, still ?? step].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Tokens.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                Spacer(minLength: Tokens.Space.s)
                if let age {
                    Text(age).font(.footnote).monospacedDigit().foregroundStyle(Tokens.secondaryText).fixedSize()
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        // Working said, and its quiet in the inbox's spoken words, not the literal "no update
        // 6m" (round 49: sb#7); else its step and for how long, as the row says it.
        .accessibilityLabel([agent.conversationTitle, location, "Working",
                             link.stillSince(agent).flatMap { still == nil ? nil : AgentRow.spokenQuiet(since: $0) } ?? step,
                             still == nil ? link.spokenAge(agent, status: .working) : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityRotorEntry(id: thread.address, in: rotor)
    }

    /// Selecting, a row toggles its mark instead of opening; it is never a NavigationLink then.
    @ViewBuilder private func rowContent(_ thread: Thread, hidden: Bool) -> some View {
        if selectionMode {
            // Short of accessibility sizes the mark takes the status glyph's place, so the words
            // keep their width and nothing rewraps as Select begins (round 73: sa#3, sb#1, the
            // question went from two lines to three, moving every row under it); at accessibility
            // sizes, where the glyph is beside the status words, it goes before the row.
            let inPlace = !dynamicTypeSize.isAccessibilitySize
            Button {
                toggleSelection(thread.address)
            } label: {
                HStack(spacing: 12) {
                    if !inPlace {
                        selectionMark(thread.address)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    agentRow(thread, hidden: hidden, selected: inPlace ? selection.contains(thread.address) : nil)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectionLabel(thread))
            .accessibilityAddTraits(selection.contains(thread.address) ? .isSelected : [])
        } else {
            opener(route(thread)) { agentRow(thread, hidden: hidden) }
        }
    }

    /// Opens `route` as the root of the path, which a split view shows in its detail column.
    /// A button, not a selection-bound link: the list's selection painted a full-bleed slab and
    /// turned the row's words white; the open row draws its own fill (`openRowFill`).
    private func opener<Label: View>(_ route: Route, @ViewBuilder label: () -> Label) -> some View {
        Button { scene.selectedRoute = route } label: { label().foregroundStyle(Color.primary) }
            .accessibilityAddTraits(scene.selectedRoute?.address == route.address ? .isSelected : [])
    }

    private func route(_ thread: Thread) -> Route {
        thread.agent.hasTranscript ? .conversation(thread.address) : .terminal(thread.address)
    }

    private func answer(_ label: String, prompt: ScreenPrompt?, ask: AskActivity?, in thread: Thread) {
        inlineAnswers.answer(label, prompt: prompt, ask: ask, in: thread, decisionLog: decisionLog, saved: model.demo == nil)
    }

    private func toggleSelection(_ address: PaneAddress) {
        if selection.contains(address) { selection.remove(address) } else { selection.insert(address) }
    }

    /// `attention`: Needs You's rows, each with its answer, on one inset rounded attention surface,
    /// its receipt too (round 8: the waiting block wasn't set apart from the rows under
    /// it; round 9: a full-bleed wash read as a highlighted table region, not an item). The iPad
    /// sidebar never carries the answers: the Overview's cards do, and with a thread open the
    /// sidebar is a navigator whose rows keep their height (round 11: both columns showed the
    /// same card; round 14: opening a thread grew the waiting row into a full answer card).
    private func rows(_ threads: [Thread], hidden: Bool = false, attention: Bool = false) -> some View {
        // Only the leading unanswered Needs You card owns ⌘-number, so several rows never
        // register the same command (round 19: inline inbox decisions lacked numbered shortcuts).
        let shortcutAddress = attention && !selectionMode
            ? threads.first { inlineAnswers.choices(for: $0) != nil && inlineAnswers[$0.address]?.receipt == nil }?.address
            : nil
        // `sidebar` is only ever the regular-width split view's; inside its column the size
        // class reads compact.
        let compactSidebar = sidebar
        return ForEach(threads) { thread in
            let inline = inlineAnswers.choices(for: thread)
            let prompt = inline?.prompt
            let choices = compactSidebar ? nil : inline?.choices
            // The plate stays under the receipt: the card answered becomes the all-clear card in
            // the same slot, plate to plate (round 64: opus#1, the plate dropped at the receipt,
            // then a card came back for the all-clear, the lane reflowing twice).
            let washed = attention
            rowContent(thread, hidden: hidden)
                // At accessibility sizes the answer tile sits up under whose it is, into the row's
                // own bottom margin (round 77: sa#3, sb#3, opus#7, 26 pt between them pushed Other
                // Answer into the bottom fade); the words keep their size and every line.
                .padding(.bottom, choices != nil && dynamicTypeSize.isAccessibilitySize ? -Tokens.Space.s : 0)
                // On the phone, the open row and the row a thread was closed back to (`showReturn`).
                .background {
                    if !sidebar {
                        ReturnFill(selected: scene.selectedRoute?.address == thread.address,
                                   returned: returnedFrom == thread.address)
                    }
                }
                .accessibilityRotorEntry(id: thread.address, in: rotor)
                // Only a stale host's rows dim; its failure card above stays at full strength.
                .opacity(thread.connection.isLive ? 1 : 0.6)
                .listRowBackground(openRowFill(route(thread), attention: washed ? (choices == nil ? .whole : .top) : nil))
                // The approval under it is the same item; a washed item is set apart by its shape.
                .listRowSeparator(choices == nil && !washed ? .automatic : .hidden, edges: .bottom)
                .listRowSeparator(washed ? .hidden : .automatic, edges: .top)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !selectionMode {
                        readToggle(thread)
                        hideToggle(thread, hidden: hidden)
                    }
                }
                .contextMenu {
                    if !selectionMode { rowMenu(thread, prompt: prompt, hidden: hidden) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !selectionMode {
                        // Closing ends an agent; it isn't deleting a document, so not a bin.
                        Button("Close", systemImage: "xmark.circle") { requestClose(thread) }
                            .tint(.red)
                    }
                }
            if let choices {
                // The answer block spans the card's inner width, from the status glyph (round 39:
                // sa#3, the title's gutter indented it).
                InlineApproval(choices: choices, title: thread.agent.conversationTitle, answer: inlineAnswers[thread.address],
                               indent: 0, numberedShortcuts: thread.address == shortcutAddress) { label in
                    answer(label, prompt: prompt, ask: inline?.ask, in: thread)
                } open: {
                    scene.open(route(thread))
                } openTerminal: {
                    scene.open(.terminal(thread.address))
                } writeAnswer: {
                    scene.writeAnswer = thread.address
                    scene.open(route(thread))
                }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(washed ? .hidden : .automatic, edges: .bottom)
                .listRowBackground(openRowFill(nil, attention: washed ? .bottom : nil))
                // Selecting, the answer stays, inert and grey, under its row's words, so rows
                // don't jump as the marks slide in (round 25: the card collapsed, moving every
                // row under it about 100 pt). Disabled, not dimmed further: its words keep a
                // readable grey (`ChoiceStyle`; rounds 43–44: sa#13, sb#11, opus#8,
                // sa#3, sb#3, at 0.4 over the style's own fade they sank near the background).
                .disabled(selectionMode)
                .saturation(selectionMode ? 0 : 1)
                .accessibilityHidden(selectionMode)
                // A tap anywhere on the card selects it, its answer half too (round 72: sb#2,
                // only the row above it took the tap).
                .overlay {
                    if selectionMode {
                        Color.clear.contentShape(.rect).onTapGesture { toggleSelection(thread.address) }
                    }
                }
                // Tight under the row it answers; the list's margins at the sides. Not pushed
                // over by Select's marks: the tile keeps its width and wrap (round 72: sa#2,
                // opus#9, indented it rewrapped and the card grew as Select began).
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: Tokens.Space.m, trailing: 20))
            }
        }
    }

    /// Mark as Read where there's something unread; Mark as Unread on an idle agent.
    @ViewBuilder private func readToggle(_ thread: Thread) -> some View {
        if thread.connection.isUnread(thread.agent) {
            Button("Mark as Read", systemImage: "envelope.open") {
                thread.connection.markSeen(thread.agent)
                offerUndo(.markRead, [thread.address])
            }
            .tint(.accentColor)
        } else if thread.connection.presentedStatus(thread.agent) == .idle {
            Button("Mark as Unread", systemImage: "envelope.badge") { thread.connection.markUnread(thread.agent) }
                .tint(.accentColor)
        }
    }

    @ViewBuilder private func hideToggle(_ thread: Thread, hidden: Bool) -> some View {
        if hidden {
            Button("Unhide", systemImage: "eye") { thread.connection.unhide(thread.agent) }
                .tint(.gray)
        } else {
            Button("Hide", systemImage: "eye.slash") {
                thread.connection.hide(thread.agent)
                offerUndo(.hide, [thread.address])
            }
            .tint(.gray)
        }
    }

    /// Everything the swipes offer and more, for a long press or a secondary click: the
    /// approval's options first, while one waits.
    @ViewBuilder private func rowMenu(_ thread: Thread, prompt: ScreenPrompt?, hidden: Bool) -> some View {
        if let prompt {
            Section(prompt.title) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                    Button(option.label) {
                        if PromptOptionKind(label: option.label) == .scope {
                            granting = GrantRequest(thread: thread, prompt: prompt, label: option.label)
                        } else {
                            answer(option.label, prompt: prompt, ask: nil, in: thread)
                        }
                    }
                }
            }
        }
        Section {
            readToggle(thread)
            hideToggle(thread, hidden: hidden)
            Button("Open Terminal", systemImage: "apple.terminal") { scene.open(.terminal(thread.address)) }
        }
        Section {
            Button("Rename…", systemImage: "pencil") {
                newName = thread.agent.conversationTitle
                renaming = thread
            }
            Button("New Agent Here", systemImage: "plus") {
                sheet = .newAgent(thread.connection, workspace: thread.agent.workspaceID)
            }
        }
        Button("Close…", systemImage: "xmark.circle", role: .destructive) { requestClose(thread) }
    }

    private func requestClose(_ thread: Thread) {
        closing = thread.stamp.map { CloseRequest(thread: thread, stamp: $0) }
    }

    private func agentRow(_ thread: Thread, hidden: Bool, selected: Bool? = nil) -> some View {
        let status = thread.connection.presentedStatus(thread.agent)
        let wait = thread.connection.wait(thread.agent)
        let unread = thread.connection.isUnread(thread.agent)
        // A screen approval says its question, then what it would run, apart.
        let screen = wait?.console == nil ? wait?.prompt : nil
        return AgentRow(
            agent: thread.agent,
            status: status,
            workspace: thread.workspace?.displayLabel,
            unread: unread,
            host: allHosts ? "\(thread.connection.profile.name) · \(thread.address.session)" : nil,
            kind: mixedKinds ? thread.agent.agent.map(agentKindLabel) : nil,
            subagents: thread.connection.workingSubagents[thread.agent.paneID] ?? 0,
            // A result already read keeps its verdict line (round 24: title and place alone,
            // which round 17 chose to fit more read agents above the fold, couldn't tell "No
            // blocking findings" from a failure without opening it).
            preview: thread.connection.rowLine(thread.agent, status: status, previews: settings.inboxPreviews),
            caution: thread.connection.caution(thread.agent, status: status, previews: settings.inboxPreviews),
            pendingQuestion: screen?.title ?? wait?.summary,
            pendingCommand: screen?.subject?.split(whereSeparator: \.isNewline).joined(separator: " "),
            commandMayBeCut: screen?.contextMayBeTruncated == true,
            lastTurnAt: thread.connection.ageDate(thread.agent, status: status),
            // Not while its answer's receipt shows: it was answered just now.
            quietSince: status == .working && inlineAnswers[thread.address] == nil ? thread.connection.stillSince(thread.agent) : nil,
            workingSince: thread.connection.workingSince(thread.agent, status: status),
            // Grouped by status, the section header already names it; Hidden mixes them.
            showsStatus: settings.inboxGrouping != .status || hidden,
            questionFirst: true,
            selected: selected
        ).equatable()
    }

    /// Whether the agents in the inbox run under more than one harness; only then do rows say
    /// which (round 8: nothing told an omp agent from a Claude Code one).
    private var mixedKinds: Bool {
        Set(model.threads.compactMap(\.agent.agent)).count > 1
    }

    /// Which part of a Needs You item's attention surface a list row draws: the agent's row and
    /// its answer under it are two list rows sharing one rounded shape.
    enum AttentionPart { case whole, top, bottom }

    /// The open row: an inset rounded fill under words that keep their colours, as Settings'
    /// sidebar draws it. Elsewhere on the phone the page's own colour, so a swiped row slides as
    /// an opaque cell instead of its words sliding over nothing; under a wait, a faint attention
    /// tint on an inset rounded shape over it.
    @ViewBuilder private func openRowFill(_ route: Route?, attention: AttentionPart? = nil) -> some View {
        // Either view of the agent, its chat or its terminal, marks its row (round 16: the
        // terminal of an agent with a transcript left the sidebar with nothing selected).
        if let route, sidebar, scene.selectedRoute?.address == route.address {
            selectionShape
        } else {
            ZStack {
                if let attention {
                    let top: CGFloat = attention == .bottom ? 0 : Tokens.Radius.card
                    let bottom: CGFloat = attention == .top ? 0 : Tokens.Radius.card
                    if !sidebar { Tokens.Surface.base }
                    UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
                        .fill(Tokens.Tint.attentionWash)
                        .padding(.horizontal, 8)
                        .padding(.top, attention == .bottom ? 0 : 3)
                        .padding(.bottom, attention == .top ? 0 : 3)
                } else if !sidebar {
                    Tokens.Surface.base
                }
            }
        }
    }

    private var selectionShape: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Tokens.selectionFill)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    /// Marks the row a thread was just closed back to (round 42: sb#8, the return left no mark of
    /// the row just reviewed).
    private func showReturn(to address: PaneAddress) {
        returnedFrom = address
        returns += 1
        // Faded as the pop runs, as UIKit lists deselect on return (`ReturnFill`): a short mark,
        // not a second animation after the pop (round 84: opus#3, at 750 ms and a 450 ms fade,
        // Back kept moving for two seconds; round 85: opus#8, sb#9, at 550 ms and 0.3 s it still
        // faded after the inbox was usable).
        let count = returns
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if returns == count { withAnimation(.easeOut(duration: 0.35)) { returnedFrom = nil } }
        }
    }

    /// Title, unread, status, then where it runs, so two agents with one title stay apart, and
    /// the last turn's age (round 10: unread and the age, reasons to pick a row, went unsaid),
    /// then the harness and what the row says: the pending question, with its caveat when the
    /// command may be cut short, else its verdict or step (round 26: VoiceOver lost what sighted
    /// users still read while selecting; round 27: the caveat too), a result's caution before
    /// its verdict (round 48: sb#4, "No blocking findings" was heard before "apply 0042 first").
    /// A question without a command leads, as the row shows it (round 73: sb#4, Select's label
    /// still began with the title the row had moved below the question).
    private func selectionLabel(_ thread: Thread) -> String {
        let link = thread.connection
        let status = scene.shownStatus(thread)
        let wait = status == .blocked ? link.wait(thread.agent) : nil
        let asks = wait.flatMap { $0.console != nil || $0.prompt?.subject == nil ? $0.summary : nil }
        let says = asks == nil ? wait?.summary ?? link.rowLine(thread.agent, status: status, previews: settings.inboxPreviews) : nil
        let caveat = wait?.prompt?.contextMayBeTruncated == true ? "Command read from the screen, may be incomplete" : nil
        return ([asks, thread.agent.conversationTitle, link.isUnread(thread.agent) ? "Unread" : nil,
                 status.label, thread.workspace?.displayLabel,
                 allHosts ? link.profile.name : nil, link.spokenAge(thread.agent, status: status),
                 thread.agent.agent.map(agentKindLabel),
                 link.caution(thread.agent, status: status, previews: settings.inboxPreviews).map(AgentRow.spokenCaution), says, caveat] as [String?])
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func selectionMark(_ address: PaneAddress) -> some View {
        AgentRow.selectionMark(selection.contains(address))
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
                            let route = Route.terminal(link.address(paneID: pane.id))
                            opener(route) {
                                VStack(alignment: .leading) {
                                    TerminalRow(pane: pane)
                                    if noAgent { Text("No agent yet").font(.caption).foregroundStyle(.secondary) }
                                    if allHosts {
                                        Text("\(link.profile.name) · \(link.activeSession ?? "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .listRowBackground(openRowFill(route))
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

    /// Under the sidebar's host name: where it points and which session.
    private var subtitle: String {
        if allHosts { return model.enabledHostsLabel }
        if let link = connection.statusText { return link }
        guard let session = connection.activeSession, connection.sessions.filter(\.running).count > 1 else {
            return connection.profile.address
        }
        return "\(connection.profile.address) · \(session)"
    }

    /// Host-reported Needs You, receipts included: the caught-up moment waits for the host.
    /// Hidden agents not, as the dock and the Overview count them (round 65: sb#1).
    private var blockedCount: Int { blockedAddresses.count }

    private var blockedAddresses: Set<PaneAddress> {
        Set(model.dockThreads(in: scene).filter { $0.connection.presentedStatus($0.agent) == .blocked }.map(\.address))
    }

    /// Needs You less the agents whose inline answer is in and showing its receipt.
    private var waitingCount: Int { model.dockThreads(in: scene).count(where: scene.needsUser) }

    private var filterActive: Bool {
        scene.needsYouOnly || settings.inboxGrouping != .status || settings.inboxSort != .recent
    }

    /// How the inbox is arranged; where it points is the title's job.
    private var viewMenu: some View {
        @Bindable var settings = settings
        @Bindable var scene = scene
        return Menu {
            Section {
                Toggle("Needs You Only", systemImage: AgentStatus.blocked.symbol, isOn: $scene.needsYouOnly)
            }
            choices("Group", $settings.inboxGrouping, InboxGrouping.allCases, label: \.label)
            choices("Sort", $settings.inboxSort, InboxSort.allCases, label: \.label)
            Toggle("Collapse Read", isOn: $settings.collapseIdle)
            Button("Panes…", systemImage: "square.grid.3x3") { sheet = .panes }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .symbolVariant(filterActive ? .fill : .none)
                .foregroundStyle(filterActive ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel("View Options")
        // What it's set to, heard without opening it (round 74: sb#10).
        .accessibilityValue(([scene.needsYouOnly ? "Needs You Only" : nil, settings.inboxGrouping == .none ? "Not grouped" : "Grouped by \(settings.inboxGrouping.label)",
                              "\(settings.inboxSort.label) first", settings.collapseIdle ? "Read collapsed" : nil] as [String?])
            .compactMap { $0 }.joined(separator: ", "))
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

/// An inbox row: unread dot, title and when its last turn was, status and where it runs, then
/// the pending question or (with previews on) a line of the newest message.
struct AgentRow: View, Equatable {
    let agent: Agent
    /// What the row shows, which may differ from the host's state: see `HostConnection.presentedStatus`.
    let status: AgentStatus
    let workspace: String?
    let unread: Bool
    var host: String? = nil
    /// The harness ("Claude", "Codex", "OMP"), when the inbox mixes them.
    var kind: String? = nil
    /// Subagents last seen working in this agent's open conversation; shown only while it works.
    var subagents = 0
    /// A line of the newest message, when previews are on.
    var preview: String? = nil
    /// A finished result's closing warning, under its verdict (`HostConnection.caution`).
    var caution: String? = nil
    /// What a waiting agent asks, when its prompt has been read.
    var pendingQuestion: String? = nil
    /// What a screen approval would run, shown apart from its question.
    var pendingCommand: String? = nil
    /// The command was read off the screen and may be cut short; the terminal has all of it.
    var commandMayBeCut = false
    var lastTurnAt: Date? = nil
    /// A working agent's newest transcript record, for a row gone quiet (`AgentRow.quiet`).
    var quietSince: Date? = nil
    /// When a working agent's current run began (`HostConnection.workingSince`), for its
    /// trailing "for 12m" while it isn't quiet.
    var workingSince: Date? = nil
    /// The status word before the place; off where a section header already says it.
    var showsStatus = true
    /// The workspace or folder; off where the row sits under its workspace's own header.
    var showsPlace = true
    /// A waiting row leads with its question, whose it is under it (the inbox and the iPad
    /// sidebar; round 72: opus#2, the sidebar and AX sizes led with the title while the phone
    /// and the switcher led with the question). Panes lists agents by their place.
    var questionFirst = false
    /// Under Select, short of accessibility sizes: whether it's selected, its mark drawn in the
    /// status glyph's place (`SessionView.rowContent`); nil otherwise.
    var selected: Bool? = nil

    var body: some View { AgentRowLayout(row: self) }

    /// Neutral, as Mail's and Files' marks are (round 12: the green filled check was the unread
    /// Done glyph beside it, in the same colour).
    static func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(selected ? .palette : .monochrome)
            .foregroundStyle(selected ? Tokens.Surface.base : Color.secondary, Color.primary)
            .accessibilityHidden(true)
    }

    /// "now", "5m", "3h", a weekday within the week, then the date, with its year once it isn't
    /// this one (round 94: sb#4, last year's record read as this year's, as the transcript's times
    /// did before round 92). In whole clock minutes, so two clocks ticking a few seconds apart
    /// (sidebar, Overview) agree, as do the times shown.
    static func age(of date: Date, at now: Date) -> String {
        func minute(_ date: Date) -> Double { (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 }
        let elapsed = max(0, minute(now) - minute(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        if elapsed < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// `age` for a finished turn where it stands beside "waiting 4m" and "for 1m": "45m ago",
    /// "3h ago"; "now", a weekday or a date as they are (round 56: opus#5, sb#13, a bare "45m"
    /// had to be read to learn what it measured; round 57: sb#6, the dock's too).
    static func ago(of date: Date, at now: Date) -> String {
        let age = age(of: date, at: now)
        return age.wholeMatch(of: /\d+[mhd]/) != nil ? "\(age) ago" : age
    }

    /// `age` on a row that needs the user, where a bare "46m" read as when it started, its last
    /// message or how long it had waited (round 15): "waiting 46m", "waiting 3h", "waiting since
    /// Tue", "just asked". `date` is when it asked (`HostConnection.ageDate`).
    static func waiting(since date: Date, at now: Date) -> String {
        let age = age(of: date, at: now)
        if age == "now" { return "just asked" }
        return age.last?.isNumber == false && age.dropLast().allSatisfy(\.isNumber) ? "waiting \(age)" : "waiting since \(age)"
    }

    /// `waiting` as VoiceOver says it.
    static func spokenWaiting(since date: Date) -> String {
        "asked \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// How long a working agent has been at it, in the trailing slot where a result has its age
    /// and a wait "waiting 4m": "for 12m", "for 1h 5m"; nil under a minute (round 44: sa#5, sb#4,
    /// opus#5, a two-minute run and a two-hour one looked the same).
    static func working(since date: Date, at now: Date) -> String? {
        func minute(_ date: Date) -> Double { (date.timeIntervalSinceReferenceDate / 60).rounded(.down) }
        let minutes = Int(max(0, minute(now) - minute(date)))
        guard minutes >= 1 else { return nil }
        return "for " + (minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m")
    }

    /// `working` as VoiceOver says it.
    static func spokenWorking(since date: Date) -> String {
        "working since \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// How long a working agent's transcript has been still, once that's long enough to matter:
    /// "no update 6m", "no update since Mon"; nil under 5 minutes (round 20: "Working" alone looked
    /// the same for an agent streaming and one stalled for 19 minutes; round 22: "quiet 7m" didn't
    /// say what had gone quiet). Says nothing of the terminal: a long command writes there, not to
    /// the transcript.
    static func quiet(since date: Date, at now: Date) -> String? {
        guard now.timeIntervalSince(date) >= 5 * 60 else { return nil }
        let age = age(of: date, at: now)
        return age.last?.isNumber == false && age.dropLast().allSatisfy(\.isNumber) ? "no update \(age)" : "no update since \(age)"
    }

    /// `quiet` as VoiceOver says it, naming what went still (round 43: sb#5, "no update" alone
    /// could be heard as the host's link).
    static func spokenQuiet(since date: Date) -> String {
        "no transcript update, last one \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// `age` as VoiceOver says it: "5m" alone could be read as how long it has waited.
    static func spokenAge(of date: Date) -> String {
        "last turn \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// "**Before deploying:** apply 0042 first": a short lead before a colon set in semibold, in
    /// primary over the grey rest, the thing to do read before the reassurance around it
    /// (round 51: sa#6, all grey it sat under the verdict's weight).
    static func cautionText(_ caution: String) -> Text {
        guard let colon = caution.firstIndex(of: ":"), caution.distance(from: caution.startIndex, to: colon) <= 32 else {
            return Text(caution)
        }
        let lead = caution[...colon], rest = caution[caution.index(after: colon)...]
        return Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(.primary))\(Text(rest))")
    }

    /// A caution as VoiceOver hears it wherever it's shown, its warning said, as the triangle
    /// shows it (round 58: sb#4, only the inbox's regular row said "Warning").
    static func spokenCaution(_ caution: String) -> String { "Warning: \(caution)" }
}

/// `AgentRow`'s drawing, apart so the row stays a plain `Equatable` value: a status glyph in
/// the leading column, the words beside it. At accessibility sizes nothing truncates and the
/// place gets its own line.
private struct AgentRowLayout: View {
    let row: AgentRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dotSize = 9.0
    /// The status glyph's column in `regular` (`glyph`'s 22 pt minimum, as the type grows).
    @ScaledMetric(relativeTo: .body) private var glyphColumn = 22.0

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { large } else { regular }
        }
        .padding(.vertical, 3)
    }

    /// At accessibility sizes a decision leads with its state, then whose it is, then the
    /// question (round 20: the place and choice buried the answer action; round 21: with the
    /// place after the buttons, an answer could be given before seeing which workspace asked).
    /// Whose it is, a size down from the question (round 22: as large as the question, it pushed
    /// Write Your Own Answer under the bar). A question that leads (`askedFirst`) comes before
    /// whose it is, as at regular sizes, the title joining its place a size down (round 72:
    /// opus#2, AX led with "Deploy to staging" where every other size led with what it asked).
    private var large: some View {
        let deciding = row.pendingQuestion != nil || row.pendingCommand != nil
        let origin = place.map { [$0, row.kind].compactMap { $0 }.joined(separator: " · ") }
        return VStack(alignment: .leading, spacing: 3) {
            if deciding { largeStatus }
            if let question = askedFirst {
                Text(question).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                // Whose it is, a size down: the title, where it runs and (in a mixed fleet) the
                // harness (round 76: sb#1, without the title a sighted reader couldn't tell whose
                // decision it was; round 75: opus#6, it cost Working its place on the first screen,
                // the lesser loss). Hyphens don't break, so "web-dashboard" stays one word (opus#6).
                Text(([row.agent.conversationTitle] + [origin].compactMap { $0 }).joined(separator: " · ").replacingOccurrences(of: "-", with: "\u{2011}"))
                    .font(.footnote).foregroundStyle(Tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(([row.agent.conversationTitle, row.status.label] + [origin].compactMap { $0 }).joined(separator: ", "))
            } else {
                title.fixedSize(horizontal: false, vertical: true)
            }
            if deciding, askedFirst == nil {
                if let origin {
                    Text(origin).font(.footnote).foregroundStyle(Tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let question = row.pendingQuestion {
                    Text(question).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                command
            } else if !deciding {
                largeStatus
                if let origin { Text(origin).font(.subheadline).foregroundStyle(Tokens.secondaryText) }
                // The caution before the verdict, as the thread's card sets it (round 48: sa#1, sb#4).
                cautionLine().fixedSize(horizontal: false, vertical: true)
                if let preview = row.preview {
                    Text(preview).font(.subheadline)
                        .foregroundStyle(reportsNow ? Color.primary : Tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The dot, glyph and status words on one line, the age after them while it fits and else
    /// flush under them (round 18: under "Needs you" it hung at the words' indent).
    private var largeStatus: some View {
        let lead = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.unread { unreadDot }
            glyph(.subheadline)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                lead
                meta(large: true).fixedSize()
                Spacer(minLength: 8)
                age().fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { lead; meta(large: true) }
                age()
            }
        }
    }

    private var regular: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            unreadDot
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                glyph(.body)
                    .opacity(row.selected == nil ? 1 : 0)
                    .overlay {
                        if let selected = row.selected {
                            AgentRow.selectionMark(selected)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let question = askedFirst {
                            Text(question).font(.body.weight(.semibold)).lineLimit(3)
                        } else {
                            // Two lines before it cuts: the name is what tells two agents apart
                            // (round 45: sa#6, sb#10, "Token-bucket rate lim…" in the iPad sidebar).
                            title.lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        age(quiet: false)
                    }
                    meta(large: false, quiet: true)
                    // A result's caution before its verdict, as the thread's card sets it (round
                    // 48: sa#1, sb#4, "No blocking findings" read first, then "apply 0042 first").
                    // Three lines where the column is narrower than a phone's (round 52: sb#11,
                    // sa#10, the iPad sidebar cut it at "working tree u…").
                    if row.pendingQuestion == nil { cautionLine(hanging: true).lineLimit(3) }
                    // One line of a result says its verdict, not the verdict and a bullet's first
                    // word (round 28: "No blocking findings in PR #412. · Move: the…"). A read
                    // result with a caution keeps the caution alone, as the dock's row does
                    // (round 65: opus#4, sa#2, a read row stood as tall as the one asking).
                    if askedFirst == nil, let text = row.pendingQuestion ?? (settledWithCaution ? nil : row.preview.map(TranscriptActivity.verdict)) {
                        // What a live agent is doing now in primary, over its grey place: it
                        // answers the row's question (round 52: sa#7, it sat level with "api ·
                        // OMP"); a quiet one's "Last reported:" stays grey, as old news, on two
                        // lines as the dock gives it, so the command survives the prefix.
                        let quietStep = row.status == .working && !reportsNow
                        Text(text).font(.subheadline)
                            .foregroundStyle(row.pendingQuestion != nil || reportsNow ? Color.primary : Tokens.secondaryText)
                            .lineLimit(row.pendingQuestion != nil || quietStep ? 2 : 1)
                    }
                    command
                }
            }
        }
    }

    /// A waiting row's question, when it leads the row (`AgentRow.questionFirst`): what's asked
    /// in the title's place, whose it is ahead of the place under it (round 70: sa#2, raised
    /// twice, the phone's Needs You row read "Deploy to staging" before the question it asked,
    /// where Overview's card and Mail's subject line lead with what's asked). Not an approval:
    /// its "Allow bash?" says less than the task it's for, and it belongs beside its command
    /// (round 71: sb#7, opus#4, a generic "Allow bash?" led every approving row, the meta line
    /// between it and what it would run).
    private var askedFirst: String? { row.questionFirst && row.pendingCommand == nil ? row.pendingQuestion : nil }

    /// Read, with a closing warning that says what's left to do.
    private var settledWithCaution: Bool { row.status == .idle && !row.unread && row.caution != nil }

    /// At work and not gone quiet, so its preview is what it's doing now (round 52: sa#7).
    private var reportsNow: Bool {
        row.status == .working && row.quietSince.flatMap { AgentRow.quiet(since: $0, at: .now) } == nil
    }

    /// A result's closing warning before its verdict, so "No blocking findings" doesn't read as
    /// all clear when it ends "Before deploying: apply 0042 first" (round 41: sa#1, sb#1, opus#2;
    /// round 48: sa#1, sb#4, under it, it still came second); two lines, its lead in semibold
    /// (round 42: sa#2, sb#4, opus#5: one grey line cut it at "existing rows…"); at the verdict's
    /// size (round 53: opus#7, sa#2, sb#2: in footnote under it, the thing to do read as fine print).
    /// `hanging`: its triangle in the status glyph's column, so its lines share the title's and
    /// the verdict's edge (round 57: opus#9, wrapped under its icon it left the row's left edge
    /// ragged).
    @ViewBuilder private func cautionLine(hanging: Bool = false) -> some View {
        if let caution = row.caution {
            let icon = Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Tint.caution)
            if hanging {
                AgentRow.cautionText(caution).foregroundStyle(Tokens.secondaryText)
                    .font(.subheadline)
                    .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        // Centred on the column `regular` gives the glyph, 10 pt before the words.
                        icon.imageScale(.small).font(.subheadline)
                            .alignmentGuide(.leading) { $0.width / 2 + 10 + glyphColumn / 2 }
                            .accessibilityHidden(true)
                    }
                    // A read result's verdict, no longer drawn under it (`settledWithCaution`), still said.
                    .accessibilityLabel([AgentRow.spokenCaution(caution), settledWithCaution ? row.preview.map(TranscriptActivity.verdict) : nil]
                        .compactMap { $0 }.joined(separator: ". "))
            } else {
                Label { AgentRow.cautionText(caution).foregroundStyle(Tokens.secondaryText) } icon: { icon }
                    .labelStyle(.caveat)
                    .font(.subheadline)
                    .accessibilityLabel(AgentRow.spokenCaution(caution))
            }
        }
    }

    /// What an approval would run, under its question, in the thread card's monospace.
    @ViewBuilder private var command: some View {
        if let command = row.pendingCommand {
            PendingCommand(command: command, mayBeCut: row.commandMayBeCut)
        }
    }

    /// In its own gutter before the status, inside the row, as Mail's unread dot is, and in
    /// Mail's blue (round 27: in the accent green it sat beside Approve, Recommended, links and
    /// Done, and a green dot led an orange waiting glyph).
    private var unreadDot: some View {
        Circle()
            .fill(Tokens.Tint.unread)
            .frame(width: dotSize, height: dotSize)
            // Sat on the title's baseline, about its lowercase height.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            .opacity(row.unread ? 1 : 0)
            .accessibilityLabel("Unread")
            .accessibilityHidden(!row.unread)
    }

    /// The status in the leading column. At work its dotted ring turns slowly, so a working
    /// row reads as live at a glance; still under Reduce Motion. Gone still ("no update 6m"),
    /// a grey hourglass, so it doesn't pass for one reporting (round 30: the same turning blue
    /// ring beside "no update 6m" overstated it; round 33: a stopped grey ring differed from
    /// the live one by colour alone).
    private func glyph(_ font: Font) -> some View {
        TimelineView(.everyMinute) { context in
            let still = row.status == .working && row.quietSince.flatMap { AgentRow.quiet(since: $0, at: context.date) } != nil
            Image(systemName: still ? AgentStatus.stillSymbol : row.status.symbol)
                .font(font)
                .foregroundStyle(still ? Tokens.secondaryText : row.status.tint)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace, options: .speed(2)))
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.25),
                              isActive: row.status == .working && !still && !reduceMotion)
                // A new image once still: a stopped rotation keeps its angle, and the hourglass
                // stood on its side.
                .id(still)
        }
        .frame(minWidth: 22)
        .accessibilityHidden(true)
    }

    private var place: String? {
        guard row.showsPlace else { return nil }
        return row.workspace ?? row.agent.workingDirectory.map { ($0 as NSString).lastPathComponent }
    }

    /// The trailing age, "for 12m" for a working agent, or "no update 6m" once it has gone still.
    /// `quiet: false` leaves the latter to the meta line (`meta(quiet:)`).
    @ViewBuilder private func age(quiet: Bool = true) -> some View {
        if let lastTurnAt = row.lastTurnAt {
            let waits = row.status == .blocked
            TimelineView(.everyMinute) { context in
                // "45m ago", not a bare "45m", beside "waiting 4m" and "for 1m" (`ago`).
                Text(waits ? AgentRow.waiting(since: lastTurnAt, at: context.date) : AgentRow.ago(of: lastTurnAt, at: context.date))
                    .accessibilityLabel(waits ? AgentRow.spokenWaiting(since: lastTurnAt) : AgentRow.spokenAge(of: lastTurnAt))
            }
            // A step down at accessibility sizes, still scaling (round 79: sb#6, at footnote the
            // age weighed as much as the question it dates).
            .font(dynamicTypeSize.isAccessibilitySize ? .caption : .footnote)
            .foregroundStyle(Tokens.secondaryText)
            .fixedSize()
        } else if row.status == .working, row.quietSince != nil || row.workingSince != nil {
            TimelineView(.everyMinute) { context in
                if let quietSince = row.quietSince, let still = AgentRow.quiet(since: quietSince, at: context.date) {
                    if quiet { Text(still).accessibilityLabel(AgentRow.spokenQuiet(since: quietSince)) }
                } else if let since = row.workingSince, let working = AgentRow.working(since: since, at: context.date) {
                    Text(working).monospacedDigit().accessibilityLabel(AgentRow.spokenWorking(since: since))
                }
            }
            .font(dynamicTypeSize.isAccessibilitySize ? .caption : .footnote)
            .foregroundStyle(Tokens.secondaryText)
            .fixedSize()
        }
    }

    /// At accessibility sizes the status word always shows beside the glyph, which is small
    /// there (round 12: "● ! 5m" said nothing a large-text reader could rely on), except where
    /// "waiting 4m" says it (round 18: "Needs you" under the Needs You header, then the wait).
    private var showsStatus: Bool {
        row.showsStatus || (dynamicTypeSize.isAccessibilitySize && !(row.status == .blocked && row.lastTurnAt != nil))
    }

    /// Without the status word on screen, VoiceOver still hears it after the title.
    private var title: some View {
        Text(row.agent.conversationTitle)
            .font(.body.weight(row.unread || row.status == .blocked ? .semibold : .regular))
            .accessibilityLabel(showsStatus ? row.agent.conversationTitle : "\(row.agent.conversationTitle), \(row.status.label)")
    }

    /// Status, subagents at work, place, harness and host. At accessibility sizes the place and
    /// harness have their own line (round 11: after the glyph the place wrapped as
    /// "web-/dashboard"; round 9: a harness after it wrapped to an orphan "· OMP"). With `quiet`,
    /// a still transcript's "no update 6m" ends it while the whole line fits, else takes a line
    /// of its own (round 23: in the title's age slot it cut the iPad sidebar's "Backfill March
    /// o…" and read as an age; round 25: kept on the line it cut the place to "data-pip…"). Short
    /// of room otherwise, the place gives way before the harness and host after it (round 24:
    /// "data-pipeline · C…"). Gone still, the status word greys with the ring (round 31: Panes
    /// said blue "Working" of an agent six minutes silent).
    @ViewBuilder private func meta(large: Bool, quiet: Bool = false) -> some View {
        if row.status == .working, let quietSince = row.quietSince {
            TimelineView(.everyMinute) { context in
                if let still = AgentRow.quiet(since: quietSince, at: context.date) {
                    if quiet && row.lastTurnAt == nil {
                        let spoken = AgentRow.spokenQuiet(since: quietSince)
                        ViewThatFits(in: .horizontal) {
                            metaLine(large: large, greyed: true, still: still, spoken: spoken)
                            VStack(alignment: .leading, spacing: 3) {
                                metaLine(large: large, greyed: true)
                                Text(still).accessibilityLabel(spoken)
                                    .font(.subheadline).foregroundStyle(Tokens.secondaryText)
                            }
                        }
                    } else {
                        metaLine(large: large, greyed: true)
                    }
                } else {
                    metaLine(large: large)
                }
            }
        } else {
            metaLine(large: large)
        }
    }

    @ViewBuilder private func metaLine(large: Bool, greyed: Bool = false, still: String? = nil, spoken: String? = nil) -> some View {
        // The working ones, said so (round 22: "1 subagent" beside a thread whose header read
        // "2 subagents · 1 working").
        let working = row.status == .working && row.subagents > 0 ? "\(row.subagents) \(row.subagents == 1 ? "subagent" : "subagents") working" : nil
        let shownPlace = large ? nil : place
        let after = [large ? nil : row.kind, row.host].compactMap { $0 }
        // Whose it is, ahead of the rest, under a question that leads the row (`askedFirst`).
        if !large, askedFirst != nil {
            namedLine(place: shownPlace, kind: row.kind, host: row.host)
        } else if showsStatus || working != nil || shownPlace != nil || !after.isEmpty || still != nil {
            let lead = showsStatus || working != nil
            HStack(spacing: 4) {
                if showsStatus { Text(row.status.label).foregroundStyle(greyed ? Tokens.secondaryText : row.status.tint).layoutPriority(1) }
                if let working { Text((showsStatus ? "· " : "") + working).layoutPriority(1) }
                if let shownPlace { Text((lead ? "· " : "") + shownPlace) }
                if !after.isEmpty {
                    Text((lead || shownPlace != nil ? "· " : "") + after.joined(separator: " · ")).layoutPriority(1)
                }
                if let still {
                    Text((lead || shownPlace != nil || !after.isEmpty ? "· " : "") + still)
                        .accessibilityLabel(spoken ?? still)
                        .fixedSize()
                }
            }
            .font(.subheadline)
            .foregroundStyle(Tokens.secondaryText)
            .lineLimit(large ? nil : 1)
        }
    }

    /// Whose a question-first row is: its title in primary, then its status (where no header
    /// says it), place, harness and host, on one line while it all fits, else the title on its
    /// own line over the rest, so neither the task nor where it acts is cut (round 71: sb#1, in
    /// Select mode "Deploy to staging · web-dashb…" lost the workspace the answer acts in) and
    /// the harness stays in a mixed fleet (round 75: sa#8, sb#10, the iPad sidebar's row
    /// dropped "OMP" to keep one line while its neighbours showed theirs).
    private func namedLine(place: String?, kind: String?, host: String?) -> some View {
        let name = row.agent.conversationTitle
        let status = showsStatus ? Text(row.status.label).foregroundStyle(row.status.tint) : nil
        func tail(_ parts: [String?]) -> Text? {
            let rest = parts.compactMap { $0 }.joined(separator: " · ")
            return switch (status, rest.isEmpty) {
            case (let status?, false): Text("\(status) · \(rest)")
            case (let status?, true): status
            case (nil, false): Text(rest)
            case (nil, true): nil
            }
        }
        let title = Text(name).fontWeight(.medium).foregroundStyle(.primary)
        let full = tail([place, kind, host])
        return ViewThatFits(in: .horizontal) {
            if let full { Text("\(title) · \(full)").lineLimit(1) } else { title.lineLimit(1) }
            VStack(alignment: .leading, spacing: 2) {
                title.lineLimit(2)
                if let full { full.lineLimit(2) }
            }
        }
        .font(.subheadline)
        .foregroundStyle(Tokens.secondaryText)
        .accessibilityElement(children: .ignore)
        // Its state heard after the title, once, whether or not a header shows it.
        .accessibilityLabel(([name, row.status.label] + [place, kind, host].compactMap { $0 }).joined(separator: ", "))
    }
}

/// A Needs You row's answer, given without opening the thread. An approval: Approve and Deny
/// as buttons under the title, anything else (a yes that lasts) and the thread under More,
/// short verbs here and the harness's full wording in the thread's card and the row's menu.
/// An ask: its options as buttons, the recommended one tinted, typing an answer in the thread.
/// While the screen takes the answer the chosen button says so ("Approving…"); once it has,
/// the receipt stands where the buttons were until the row moves on. The Overview's Needs You
/// cards hold it too, under their own title.
struct InlineApproval: View {
    let choices: InlineChoices
    let title: String
    let answer: InlineAnswer?
    /// Where the buttons start, under the title; the inbox row's glyph column by default.
    var indent: CGFloat? = nil
    /// Only the first unanswered Needs You card registers numbered hardware-keyboard commands.
    var numberedShortcuts: Bool = false
    let choose: (String) -> Void
    let open: () -> Void
    let openTerminal: () -> Void
    /// Opens the thread with the ask's answer editor out.
    let writeAnswer: () -> Void
    /// The inbox row's unread gutter, scaled with its text.
    @ScaledMetric(relativeTo: .body) private var dotSize = 9.0
    /// The receipt's sheep, scaled with its words.
    @ScaledMetric(relativeTo: .subheadline) private var sealSize = 18.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A lasting grant from the "…" menu, waiting on its confirmation.
    @State private var confirmingGrant: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Off under Select: the card stays readable, in grey, rather than the system's faded tint.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if let receipt = answer?.receipt {
                receiptLine(receipt)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            } else {
                switch choices {
                case .approval(let prompt): approvalButtons(prompt)
                case .ask(let question): askButtons(question)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
        .padding(.leading, leading)
        // The rule under it starts where the row's title does, not at the first button's label
        // (round 6: the list's separators stepped 15 pt in under answerable rows).
        .alignmentGuide(.listRowSeparatorLeading) { _ in leading }
        .padding(.bottom, Tokens.Space.xs)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy, value: answer?.receipt)
        .grantConfirmation($confirmingGrant, label: { $0 }, grant: choose)
    }

    /// Under the row's title: the unread gutter, the glyph column and their spacing; at
    /// accessibility sizes the row's lines start at its edge, and so do these.
    private var leading: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 0 : indent ?? dotSize + 6 + 22 + 10
    }

    /// Side by side in equal halves, one under another at accessibility sizes, in the thread
    /// card's rounded shape at a compact height (round 26: capsules here and halves there drew
    /// one decision two ways; round 9: they kept to one row where the card stacked). Under a
    /// command read off the screen and maybe cut short, Inspect in Terminal (round 25: "Full
    /// Command in Terminal" read as a promise of completeness; round 17: "View Full Command"
    /// promised a view and opened the terminal; round 16: the row hid the way to read it in "…"),
    /// before the answers, as on the thread's card (round 23: under them it invited a decision
    /// before a look).
    private func approvalButtons(_ prompt: ScreenPrompt) -> some View {
        let approve = prompt.options.first { PromptOptionKind(label: $0.label) == .approve }
        let deny = prompt.options.first { PromptOptionKind(label: $0.label) == .deny }
        let others = prompt.options.filter { $0 != approve && $0 != deny }
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Space.s))
            : AnyLayout(HStackLayout(spacing: Tokens.Space.s))
        return VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if prompt.contextMayBeTruncated {
                Button(action: openTerminal) {
                    Text("Inspect in Terminal")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A 44 pt target, the layout kept, as Other Answer's (round 56: sb#1);
                        // grown upward, over the command, short of the Approve button under it.
                        .padding(.top, Tokens.Space.l)
                        .padding(.bottom, Tokens.Space.s)
                        .contentShape(.rect)
                }
                .inlineAction()
                .tint(Tokens.Tint.onAttention)
                .padding(.top, -Tokens.Space.l)
                .padding(.bottom, Tokens.Space.xs - Tokens.Space.s)
                .disabled(answer != nil)
            }
            layout {
                if let approve {
                    // "Approve Once" beside a lasting grant in the "…" menu, as the thread's card
                    // says it (round 57: sb#1, opus#2, sa#4, one approval with two names).
                    let once = others.contains { PromptOptionKind(label: $0.label) == .scope }
                    button(once ? "Approve Once" : "Approve", pending: "Approving…", label: approve.label, shortcutIndex: 0)
                        .primaryAction(.roundedRectangle(radius: Tokens.Radius.choice))
                }
                if let deny {
                    // Neutral: red is for the receipt and the menu's destructive role, not a second
                    // loud button beside the one that matters.
                    button("Deny", pending: "Denying…", label: deny.label, shortcutIndex: approve == nil ? 0 : 1)
                        .choiceButton()
                        // Its own width beside Approve, which takes the rest, so "Approve Once ⌘1"
                        // fits whole with its hint as Deny keeps its (round 59: opus#9, sb#8, the
                        // dropped "⌘1" beside "Deny ⌘2" read as Approve having no key).
                        .frame(minWidth: approve != nil ? 96 : nil)
                        .fixedSize(horizontal: approve != nil && !dynamicTypeSize.isAccessibilitySize, vertical: false)
                }
                more(others.map(\.label))
                if let answer, others.contains(where: { $0.label == answer.label }) {
                    ProgressView().controlSize(.small).accessibilityLabel("Answering")
                }
            }
        }
    }

    /// The thread card's options at a compact size: full-width rounded choices, each saying
    /// "Recommended" over its label when the agent marked it and its explanation under it,
    /// inside the button (round 26: capsules with the explanation after them drew one decision
    /// a second way, and the answer could be tapped before its caveat was read), then Write
    /// Your Own Answer, as on the card (round 6: an answer typed out hid behind an unlabelled
    /// "…" and Open Thread). Uncut at accessibility sizes (round 7).
    private func askButtons(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                askOption(option, index: index, recommended: question.recommended == index)
            }
            // The label leads, wrapped or not (round 8: at accessibility sizes its two lines
            // centred under each other, ragged against the options' edge). "Other Answer…" at
            // every size, the thread's word too (round 23: two lines of "Write Your Own Answer…"
            // ended under the bar at accessibility sizes; round 31: two names for one action).
            Button(action: writeAnswer) {
                // Grey, not faded, while Select holds the card (round 45: sa#8, sb#14, it sank
                // into the card beside the readable recommendation).
                Text("Other Answer…")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isEnabled && answer == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Tokens.secondaryText))
                    // A 44 pt target inside the label, where a Button takes its taps, given
                    // back to the layout outside it so the card keeps its height (round 56:
                    // sb#1, the 28 pt line was the smallest target in the triage loop).
                    .padding(.vertical, Tokens.Space.m)
                    .contentShape(.rect)
            }
            .accessibilityHint("Opens the thread with a field to type an answer instead of choosing one.")
            .inlineAction()
            .tint(Tokens.Tint.onAttention)
            .padding(.vertical, Tokens.Space.xs - Tokens.Space.m)
            .disabled(answer != nil)
        }
    }

    /// Drawn as `choiceButton` draws the thread's: primary words, the recommendation on the inset
    /// surface in an accent hairline under its "Recommended" caption, the rest neutral (round 28:
    /// green on green read muddy; round 29: the grey fill read disabled in the light).
    /// VoiceOver hears the explanation and preview. The
    /// key hint ends the first line, so the lines under it keep the button's width (round 27: as
    /// a column of its own it wrapped the explanation at 60%). At accessibility sizes
    /// "Recommended" leads the explanation rather than taking a line (round 27: the option filled
    /// the screen and pushed Other Answer below it; round 75: opus#5, without the word only the
    /// green edge and arrow said it to a sighted low-vision reader). The explanation is whole at
    /// every size: it states the condition being agreed to (round 74: sa#3, sb#1, opus#3; round
    /// 75: sb#5, at regular sizes two lines could still cut a longer one), as is a preview, under
    /// it in the thread's monospace (round 75: sb#3, only VoiceOver had it here).
    private func askOption(_ option: AskOption, index: Int, recommended: Bool) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let choosing = answer?.label == option.label
        let description = option.description.flatMap { $0.isEmpty ? nil : $0 }
        let spoken = [recommended ? "Recommended" : nil, description, option.preview.map { "Preview: \($0)" }]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ". ")
        let shortcut = numberedShortcuts && answer == nil ? index : nil
        let tag = recommended && !choosing && !large
        // At accessibility sizes the send arrow leads the label inline rather than taking a
        // column from the explanation (round 49: opus#4, sb#6, there it read as a note again).
        let sends = recommended && !choosing && large
        let name = sends
            ? Text("\(Text(Image(systemName: "arrow.up.circle.fill")).foregroundStyle(Tokens.Tint.onAttention)) \(option.label)")
            : Text(choosing ? "Answering…" : option.label)
        let mark = Text("Recommended").fontWeight(.semibold).foregroundStyle(Tokens.Tint.onAttention)
        let note: Text? = choosing ? nil
            : large && recommended ? description.map { Text("\(mark) · \($0)") } ?? mark
            : description.map { Text($0) }
        let preview = choosing ? nil : option.preview.flatMap { $0.isEmpty ? nil : $0 }
        return Button { choose(option.label) } label: {
            HStack(alignment: .center, spacing: Tokens.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if choosing { ProgressView().controlSize(.mini) }
                        if tag {
                            Text("Recommended").font(.footnote.weight(.semibold)).foregroundStyle(Tokens.Tint.onAttention)
                        } else {
                            name.lineLimit(large ? nil : 3)
                        }
                        Spacer(minLength: Tokens.Space.s)
                        if !tag { ShortcutHint(shortcut) }
                    }
                    if tag { name.lineLimit(3) }
                    if let note {
                        note.font(.footnote).fontWeight(.regular)
                            .foregroundStyle(Tokens.secondaryText)
                    }
                    if let preview {
                        Text(preview).font(.footnote.monospaced())
                            .foregroundStyle(Tokens.secondaryText)
                    }
                }
                // The recommendation sends on one tap, and says so with the composer's send
                // arrow in a column of its own (round 48: sa#4, opus#14, outlined, it read as a
                // note rather than the answer's button), its key under it, one cluster for the
                // one action (round 87: round 85's sa#8, ⌘1 alone in the top corner read as a
                // stray label; beside the arrow it widened the column and wrapped the explanation).
                if tag {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Tokens.Tint.onAttention)
                            .accessibilityHidden(true)
                        ShortcutHint(shortcut)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
            // The button style pads it to 44 pt.
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .choiceButton(recommended: recommended)
        // "Sends now" in the label, as the thread's one-tap options say it, so it holds with
        // hints off (round 54: sb#1, here only the hint said a tap answers); never while
        // answering, which says only "Answering…".
        .accessibilityLabel(choosing ? "Answering…"
            : [option.label + " " + title, spoken.isEmpty ? nil : spoken, "Sends now"].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(choosing ? "" : "Answers “\(option.label)” on the agent's screen.")
        .disabled(answer != nil && !choosing)
        .accessibilityRemoveTraits(choosing ? .isButton : [])
        .accessibilityAddTraits(choosing ? .updatesFrequently : [])
        .numberedShortcut(shortcut)
    }

    private func more(_ labels: [String]) -> some View {
        Menu {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Button(label) {
                    if PromptOptionKind(label: label) == .scope { confirmingGrant = label } else { choose(label) }
                }
            }
            Section {
                Button("Open Thread", systemImage: "bubble.left.and.text.bubble.right", action: open)
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 30, minHeight: 30)
        }
        // Deny's plate, a peer of it (round 62: opus#6, `.bordered` grey read as disabled).
        .choiceButton()
        .accessibilityLabel("More Options")
        .disabled(answer != nil)
    }

    /// A yes or an answer is signed by the sheep, as a finished turn's Done card is (`HerdSeal`,
    /// played once as the receipt lands; round 27: Delight was the lowest area, and a decision
    /// ended on an anonymous check); a denial keeps the red cross.
    private func receiptLine(_ receipt: String) -> some View {
        let denied = answer.map { PromptOptionKind(label: $0.label) == .deny } ?? false
        return Label {
            // The answer it confirms in full; wraps rather than cutting it.
            Text(receipt).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
        } icon: {
            if denied {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Tint.danger)
            } else {
                HerdSeal(size: sealSize, play: true, ring: Tokens.Tint.attentionWash)
            }
        }
        .accessibilityLabel("\(receipt) · \(title)")
    }

    /// Approve or Deny: Approve takes the row Deny leaves (`approvalButtons`). `verb`: what the button says; `label`: the
    /// option it picks on the agent's screen.
    private func button(_ verb: String, pending: String, label: String, shortcutIndex: Int) -> some View {
        let choosing = answer?.label == label
        let shortcut = numberedShortcuts && answer == nil ? shortcutIndex : nil
        return Button { choose(label) } label: {
            HStack(spacing: 6) {
                if choosing { ProgressView().controlSize(.mini) }
                let words = Text(choosing ? pending : verb)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                // The verb whole before its key hint: short of room the hint goes, the key still
                // works (round 58: opus#1, sa#1, sb#1, "Approve On… ⌘1" cut the most consequential button).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { words.fixedSize(); ShortcutHint(shortcut) }
                    words
                }
            }
            // The button styles pad it to 44 pt.
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .accessibilityLabel(choosing ? pending : "\(verb) \(title)")
        .accessibilityHint(choosing ? "" : "Answers “\(label)” on the agent's screen.")
        .disabled(answer != nil && !choosing)
        // While it sends, the chosen one is a status, not a second tap (round 77: sb#2).
        .accessibilityRemoveTraits(choosing ? .isButton : [])
        .accessibilityAddTraits(choosing ? .updatesFrequently : [])
        .numberedShortcut(shortcut)
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

/// The inbox's reversible triage while its Undo shows: each Hide, or Mark Read (holding only
/// the agents that were unread, so Undo gives back exactly the marks it took).
struct InboxUndo: Identifiable {
    enum Kind { case hide, markRead }
    struct Change {
        let kind: Kind
        let addresses: [PaneAddress]
        /// The agents it changed, each as it was then.
        let stamps: [PaneAddress: AgentStamp]
    }
    let id = UUID()
    let changes: [Change]
    let message: String
}

/// Who needs you, and where: a count that drops because the shown hosts changed isn't the
/// user catching up, nor is one that drops because a waiting agent was hidden or closed.
struct BlockedTally: Equatable {
    let scope: HostProfile.ID?
    let waiting: Set<PaneAddress>
    var count: Int { waiting.count }
}

/// On the phone, the open row's fill: held while its thread shows, then faded as the pop runs,
/// as UIKit lists deselect on return. Drawn behind the row's content, past
/// its insets: as the list's row background it was never redrawn after the pop.
private struct ReturnFill: View {
    let selected: Bool
    /// Set from the return until `showReturn` clears it.
    let returned: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Tokens.selectionFill)
            .padding(.horizontal, -12)
            .padding(.vertical, -6)
            .opacity(selected || returned ? 1 : 0)
    }
}

/// The all-clear sheep's hop: lift in points, tilt in degrees.
private struct Hop {
    var lift = 0.0
    var tilt = 0.0
}

/// The all-clear's burst behind its 44 pt sheep: a green ring swelling out of the seal and
/// eight dots thrown wide of it, flatter than tall so they stay in the row, all gone in under
/// a second (round 71: opus#2, at 1.45× and 36 pt it read only frame by frame). Drawn only
/// while `trigger`'s animation runs; at rest nothing.
private struct CaughtUpBurst: View {
    let trigger: Int

    var body: some View {
        Color.clear
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, progress in
                content.overlay {
                    if progress > 0, progress < 1 {
                        ZStack {
                            Circle()
                                .stroke(Tokens.Tint.settled.opacity(0.7 * (1 - progress)), lineWidth: 3 * (1 - progress) + 0.5)
                                .frame(width: 44, height: 44)
                                .scaleEffect(1 + 0.8 * progress)
                            ForEach(0..<8, id: \.self) { index in
                                let angle = Angle.degrees(Double(index) * 45 - 22.5)
                                let reach = 26 + 18 * progress
                                Circle()
                                    .fill(Tokens.Tint.settled.opacity(1 - progress * progress))
                                    .frame(width: index.isMultiple(of: 2) ? 6 : 4.5)
                                    .scaleEffect(1 - 0.4 * progress)
                                    .offset(x: cos(angle.radians) * reach, y: sin(angle.radians) * reach * 0.7)
                            }
                        }
                    }
                }
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(1, duration: 0.8)
                }
            }
    }
}

/// What an approval would run, in the thread card's monospace, at the row's text size (round
/// 61: sb#5 r60, in footnote it was quieter than "Allow bash?", the thing to inspect smaller
/// than the generic question). Read off the screen, it may be
/// cut short, and then says so in words, as the thread's card does (round 7: a bare scissors
/// mark didn't say what it meant; round 23: "Command shortened" claimed a cut on a command
/// shown whole); Inspect in Terminal under it opens it.
struct PendingCommand: View {
    let command: String
    let mayBeCut: Bool
    var lines = 2
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command)
                .font(.subheadline.monospaced()).foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : lines)
            if mayBeCut {
                ScreenReadCaveat()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mayBeCut ? "\(command), read from the screen, may be incomplete" : command)
    }
}
