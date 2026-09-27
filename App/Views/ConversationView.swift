import HerdrAPI
import SwiftUI

/// An agent as a conversation: its own transcript as chat, its questions as tappable
/// answers, and a composer. The terminal is one tap away for everything else.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    let connection: HostConnection
    let paneID: String
    /// Pushes the terminal; alerts can't hold navigation links.
    let openTerminal: () -> Void

    @State private var feed = ConversationFeed()
    @State private var location: TranscriptLocation?
    @State private var locatedRef: AgentSessionRef?
    @State private var locateFailure: String?
    @State private var draft = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var sending = false
    @State private var sendError: String?
    @State private var answering = false
    @State private var askFailure: String?
    /// The permission or approval prompt on the agent's screen while it is blocked.
    @State private var screenPrompt: ScreenPrompt?
    @State private var choosing: String?
    /// Messages omp is holding until the agent next takes input; the last can be unsent.
    @State private var queued: [QueuedSend] = []
    @State private var unsending = false
    /// Find's temporary switch to Full for a folded-away match; Done or a chosen level clears it.
    @State private var detailOverride: DetailLevel?
    /// The saved preference, shared with Settings.
    private var detailSelection: Binding<DetailLevel> {
        Binding(get: { settings.detailLevel }, set: { settings.detailLevel = $0; detailOverride = nil })
    }
    @State private var sentCount = 0
    @FocusState private var composerFocused: Bool
    /// The newest content is on screen; only then does a finished agent count as read.
    @State private var atLatest = true
    /// Keep the newest content in view through every layout change (a reply arriving, the
    /// composer shrinking after a send, the keyboard). The reader's own scrolling sets it;
    /// sending turns it back on.
    @State private var followsLatest = true
    @State private var position = ScrollPosition(edge: .bottom)
    /// A finger or momentum is moving the transcript; corrections wait for it to settle.
    @State private var userScrolling = false
    /// Where this conversation's unsent text is kept; nil in the demo and until the agent is known.
    @State private var draftID: String?
    @State private var previewing: ImagePreviewSource?
    @State private var confirmStop = false
    @State private var showsSessionDetails = false
    /// Usage over the whole transcript, totalled on the host as Session Details opens on a
    /// partly loaded conversation; nil when not needed or not counted.
    @State private var wholeUsage: TranscriptUsage?
    @State private var countingWholeUsage = false
    @State private var explanation: String?
    /// The ended agent being resumed from the "Agent exited" state.
    @State private var resuming: EndedAgent?
    /// The shared package already merged into this conversation's draft.
    @State private var importedPackageID: UUID?
    @State private var shareImportTaskID: UUID?
    /// Find in the loaded messages: the query and which match is in view; nil when closed.
    @State private var find: (query: String, index: Int)?
    @FocusState private var findFocused: Bool

    private var agent: Agent? { connection.snapshot?.agents.first { $0.paneID == paneID } }
    private var blocked: Bool { agent?.agentStatus == .blocked }
    /// omp waits on its Plan Review screen while herdr reports it idle, so the transcript says when.
    private var planReview: Bool {
        locatedRef == agent?.agentSession && agent?.agent == "omp" && agent?.agentStatus != .working && feed.conversation.pendingPlanReview != nil
    }

    var body: some View {
        observed
            .sensoryFeedback(.success, trigger: sentCount) { _, _ in settings.haptics }
            .alert("Couldn't send", isPresented: .init(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
            .alert("Answer in the terminal", isPresented: .init(get: { askFailure != nil }, set: { if !$0 { askFailure = nil } })) {
                Button("Open Terminal", action: openTerminal)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(askFailure ?? "")
            }
            .alert("Status", isPresented: .init(get: { explanation != nil }, set: { if !$0 { explanation = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(explanation ?? "")
            }
            .alert(sessionDetails?.title ?? "Session", isPresented: $showsSessionDetails) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sessionDetails?.body ?? "")
            }
            .sheet(item: $resuming) { item in
                NewAgentSheet(links: [connection], preferred: connection, resume: item) { scene.navigationPath.append($0) }
            }
    }

    /// This pane's agent on the ended shelf, once herdr no longer runs it.
    private var endedAgent: EndedAgent? {
        EndedAgents.shared.entries.first {
            $0.ended && $0.hostID == connection.profile.id && $0.session == connection.activeSession && $0.paneID == paneID
        }
    }

    /// Brings a share picked on the Shared shelf into this conversation's composer. Nothing is
    /// sent. The package records this draft as its home (one share per draft), so reopening the
    /// conversation later restores its images; its text joins the draft unless already there.
    private func importSharedDraft() async {
        guard let id = scene.importPackageID, importedPackageID != id, let draftID,
              scene.importDraftID == draftID || scene.importAddress == connection.address(paneID: paneID),
              SharedInbox.shared.package(id) != nil else { return }
        defer {
            if !Task.isCancelled, self.draftID == draftID, scene.importPackageID == id {
                scene.importPackageID = nil
                scene.importDraftID = nil
                scene.importAddress = nil
            }
        }
        do {
            let package = try await SharedInbox.shared.load(id)
            guard !Task.isCancelled, self.draftID == draftID, scene.importPackageID == id else { return }
            let incoming = try await DraftAttachment.prepareImages(package.images)
            guard !Task.isCancelled, self.draftID == draftID, scene.importPackageID == id,
                  SharedInbox.shared.package(id) != nil else { return }
            guard attachments.count + incoming.count <= SharePackage.maximumImages else { throw AttachmentError.tooMany }
            if SharedInbox.shared.packages.contains(where: { $0.staged == draftID && $0.id != id }) {
                throw SharedInbox.Occupied()
            }
            if package.staged != draftID { try SharedInbox.shared.stage(id, in: draftID) }
            while !package.text.isEmpty, !draft.contains(package.text) {
                let previous = draft
                let merged = previous.isEmpty ? package.text : previous + "\n" + package.text
                let saved = await DraftStore.saveChecked(merged, for: draftID)
                guard !Task.isCancelled, self.draftID == draftID, scene.importPackageID == id,
                      SharedInbox.shared.package(id)?.staged == draftID else { return }
                guard saved else { throw CocoaError(.fileWriteUnknown) }
                // A keystroke during persistence belongs to the user; merge into that draft,
                // never replace it with the pre-await snapshot.
                if draft != previous { continue }
                draft = merged
            }
            guard attachments.count + incoming.count <= SharePackage.maximumImages else { throw AttachmentError.tooMany }
            attachments += incoming
            importedPackageID = id
        } catch {
            guard !Task.isCancelled, self.draftID == draftID, scene.importPackageID == id else { return }
            sendError = error.localizedDescription
        }
    }

    /// A conversation opened any way restores the images of the share staged in its draft.
    private func restoreStagedShare() async {
        guard importedPackageID == nil, let draftID,
              let item = SharedInbox.shared.packages.first(where: { $0.staged == draftID }) else { return }
        do {
            let package = try await SharedInbox.shared.load(item.id)
            guard !Task.isCancelled, self.draftID == draftID, importedPackageID == nil else { return }
            let incoming = try await DraftAttachment.prepareImages(package.images)
            guard !Task.isCancelled, self.draftID == draftID, importedPackageID == nil,
                  SharedInbox.shared.package(item.id)?.staged == draftID else { return }
            guard attachments.count + incoming.count <= SharePackage.maximumImages else { throw AttachmentError.tooMany }
            attachments += incoming
            importedPackageID = package.id
        } catch {
            guard !Task.isCancelled, self.draftID == draftID, importedPackageID == nil else { return }
            sendError = error.localizedDescription
        }
    }

    /// After a successful send, the share staged in this draft leaves the shelf.
    private func finishImport(_ id: UUID?) {
        guard let id else { return }
        do {
            try SharedInbox.shared.remove(id)
            if importedPackageID == id { importedPackageID = nil }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Split from `body`, whose single modifier chain overran the type-checker's time limit.
    private var observed: some View {
        scroller
            .toolbar { toolbar }
            .confirmationDialog("Stop this run?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { Task { await press(["esc"], failure: "The agent couldn't be stopped.") } }
            } message: {
                Text("Sends Esc to the agent, as at the desk. Messages it was holding go back to its editor.")
            }
            .task(id: LocateKey(liveID: connection.liveID, ref: agent?.agentSession)) {
                await locateTranscript()
            }
            .task(id: FeedKey(liveID: connection.liveID, location: location, window: feed.window, feedID: ObjectIdentifier(feed))) {
                let feed = feed
                // A kept offline copy paints first, even with no connection.
                if let location { feed.restore(location, host: connection.identity) }
                // A channel can end while the transport lives on (a brief background, a killed
                // `tail`): follow again. A dead transport bumps `liveID`, which restarts this task.
                while !Task.isCancelled, connection.isLive, let client = connection.client, let location {
                    await feed.follow(location, client: client, host: connection.identity)
                    guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                }
            }
            .task(id: PromptKey(liveID: connection.liveID, watching: (blocked || planReview) && pendingAsk == nil, ref: agent?.agentSession)) {
                await watchScreenPrompt()
            }
            .onChange(of: ReadKey(sequence: agent?.stateChangeSeq, visible: showsLatest), initial: true) {
                if showsLatest, let agent { connection.markSeen(agent) }
            }
            .onChange(of: demo?.draft, initial: true) { _, text in if let text { draft = text } }
            // Restored once per conversation; every edit, including a send's clear, is saved.
            .onChange(of: DraftStore.id(host: connection.identity, agent: agent), initial: true) { _, id in
                guard model.demo == nil, let id, id != draftID else { return }
                let previous = draftID
                draftID = id
                draft = DraftStore.adopt(id, replacing: previous, current: draft)
            }
            .onChange(of: draft) { _, text in
                if let draftID { DraftStore.save(text, for: draftID) }
            }
            .onChange(of: demo?.sendCount) { Task { await sendDraft() } }
            .onChange(of: feed.state, initial: true) { _, state in demo?.conversationReady = state == .live }
            .onChange(of: settings.offlineTranscripts) { _, on in if !on { feed.discardOfflineCopy() } }
            .onChange(of: scene.draftRevision) { if let draftID { draft = DraftStore.load(draftID) ?? draft } }
            .task(id: SharedImportKey(importID: scene.importPackageID, draftID: draftID,
                                     stagedID: scene.importPackageID == nil
                                        ? SharedInbox.shared.packages.first(where: { $0.staged == draftID })?.id : nil,
                                     sending: sending)) {
                // A pending import waits for an in-flight delivery, and sends wait for imports.
                guard !Task.isCancelled, !sending else { return }
                let id = UUID()
                shareImportTaskID = id
                defer { if shareImportTaskID == id { shareImportTaskID = nil } }
                await importSharedDraft()
                guard !Task.isCancelled else { return }
                await restoreStagedShare()
            }
    }

    /// Read means seen: the app is in front, this agent's transcript has painted live and its
    /// end is on screen. An error or a still-loading feed is never a read.
    private var showsLatest: Bool {
        locatedRef == agent?.agentSession && scenePhase == .active && feed.state == .live && !feed.isOfflineCopy && locateFailure == nil && atLatest
    }

    private var scroller: some View {
        ScrollView { transcript }
        .scrollPosition($position)
        .environment(\.openSubagent) { activity in
            if let route = subagentRoute(activity) { openSubagent(route) }
        }
        .environment(\.subagentNamed) { id in feed.conversation.subagents.first { $0.id == id } }
        .environment(\.previewImage) { previewing = $0 }
        .environment(\.inlineImages, (detailOverride ?? settings.detailLevel) == .full)
        .environment(\.imageLoader, ImageLoader(connection: connection, transcript: location?.path))
        .environment(\.openURL, OpenURLAction { url in
            guard let path = imageLinkPath(url) else { return .systemAction }
            previewing = .file(path)
            return .handled
        })
        .sheet(item: $previewing) {
            ImagePreview(source: $0, loader: ImageLoader(connection: connection, transcript: location?.path), cwd: agent?.cwd)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: feed.conversation.workingSubagents.count) { _, count in
            connection.workingSubagents[paneID] = count
        }
        .onChange(of: feed.conversation.items.count) { settleQueue() }
        .onChange(of: agent?.agentStatus) { settleQueue() }
        .onScrollGeometryChange(for: TailGeometry.self) { geometry in
            TailGeometry(geometry)
        } action: { old, new in
            atLatest = new.nearBottom
            // The anchor below handles content growth but not the viewport shrinking under
            // the keyboard or composer, nor a message landing after the send returned.
            if followsLatest, !userScrolling, new.layout != old.layout { position.scrollTo(edge: .bottom) }
        }
        .onScrollPhaseChange { old, new, context in
            userScrolling = [.tracking, .interacting, .decelerating].contains(new)
            // Only the reader's own scrolling decides; programmatic scrolls don't track or decelerate.
            guard new == .idle, [.tracking, .interacting, .decelerating].contains(old) else { return }
            followsLatest = TailGeometry(context.geometry).nearBottom
            if followsLatest { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: sentCount) {
            followsLatest = true
            position.scrollTo(edge: .bottom)
        }
        // Not mid-gesture: re-anchoring to the bottom as content streams in would drag a flick back.
        .defaultScrollAnchor(userScrolling ? nil : .bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay { placeholder }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if find != nil { findBar }
                if settings.showWorkingSubagents {
                    WorkingSubagentsTray(activities: feed.conversation.workingSubagents) { activity in
                        if let route = subagentRoute(activity) { openSubagent(route) }
                    }
                    .animation(.smooth, value: feed.conversation.workingSubagents)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(feed.title ?? feed.conversation.title ?? agent?.conversationTitle ?? paneID)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: Route.terminal(connection.address(paneID: paneID))) {
                Label("Terminal", systemImage: "apple.terminal")
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            let address = connection.address(paneID: paneID)
            let watching = model.watchedRun.address == address
            let offersActivity = agent != nil && connection.isLive && !feed.isOfflineCopy
                && (watching || agent?.agentStatus == .working)
            let details = sessionDetails
            ConversationMenu(
                detail: settings.detailLevel, canRetry: canRetry, canStop: canStop,
                liveActivity: offersActivity ? (watching ? .hide : .show) : nil,
                session: details?.title, sessionHasDetails: details?.body.isEmpty == false,
                mute: agent?.agentSession.map { .init(address: address, reference: $0.value) },
                status: agent?.agentStatus.label, act: menuAction
            )
            .equatable()
        }
    }

    private func menuAction(_ action: ConversationMenu.Action) {
        switch action {
        case .sessionDetails: Task { await showSessionDetails() }
        case .detail(let level): detailSelection.wrappedValue = level
        case .find:
            find = (find?.query ?? "", 0)
            findFocused = true
        case .retry: Task { await press(["alt+r"], failure: "The retry wasn't sent.") }
        case .stop: confirmStop = true
        case .liveActivity:
            Task {
                if model.watchedRun.address == connection.address(paneID: paneID) {
                    await model.watchedRun.stop(push: model.push)
                } else if let agent {
                    await model.watchedRun.start(connection: connection, agent: agent, push: model.push)
                    if let error = model.watchedRun.error { sendError = error }
                }
            }
        case .explain: Task { await explainStatus() }
        }
    }

    /// Esc interrupts a running turn in omp, Claude Code and Codex alike.
    private var canStop: Bool {
        guard let agent, !feed.isOfflineCopy, connection.isLive, agent.agentStatus == .working else { return false }
        return ["omp", "claude", "codex"].contains(agent.agent)
    }

    /// omp retries its last failed turn with Alt+R; offered once the turn has ended in an error.
    private var canRetry: Bool {
        guard let agent, agent.agent == "omp", agent.agentStatus != .working, connection.isLive, !feed.isOfflineCopy,
              case .notice(_, _, .error) = feed.conversation.items.last else { return false }
        return true
    }

    /// Messages in the loaded part of the transcript containing the query, oldest first.
    private var findMatches: [String] {
        guard let query = find?.query.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return [] }
        return feed.conversation.items.compactMap { item in
            let text: String? = switch item {
            case .user(_, let text, _), .assistant(_, let text), .notice(_, let text, _), .peerMessage(_, _, let text, _): text
            default: nil
            }
            return text?.localizedStandardContains(query) == true ? item.id : nil
        }
    }

    private var findBar: some View {
        let matches = findMatches
        let index = min(find?.index ?? 0, max(matches.count - 1, 0))
        return HStack(spacing: 10) {
            TextField("Find in loaded messages", text: Binding {
                find?.query ?? ""
            } set: { query in
                find = (query, 0)
                reveal(findMatches.last)
            })
            .focused($findFocused)
            .submitLabel(.search)
            .onSubmit { step(-1) }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Text(matches.isEmpty ? (find?.query.isEmpty == false ? "None" : "") : "\(matches.count - index) of \(matches.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Earlier", systemImage: "chevron.up") { step(-1) }
                .labelStyle(.iconOnly).disabled(matches.isEmpty)
            Button("Later", systemImage: "chevron.down") { step(1) }
                .labelStyle(.iconOnly).disabled(matches.isEmpty)
            Button("Done") { find = nil; findFocused = false; detailOverride = nil }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
    }

    /// Moves through matches counting from the newest: `-1` goes further back.
    private func step(_ direction: Int) {
        let matches = findMatches
        guard !matches.isEmpty, var current = find else { return }
        current.index = (current.index - direction + matches.count) % matches.count
        find = current
        reveal(matches[matches.count - 1 - current.index])
    }

    /// Scrolls to a match, first unfolding the transcript when the current detail hides it.
    private func reveal(_ id: String?) {
        guard let id else { return }
        let detail = detailOverride ?? settings.detailLevel
        if !feed.conversation.items(at: detail).contains(where: { $0.id == id }) { detailOverride = .full }
        followsLatest = false
        Task { @MainActor in position.scrollTo(id: id, anchor: .center) }
    }

    /// Model, thinking level and usage: the whole session's once the host has totalled it,
    /// otherwise what the loaded part of the transcript records.
    private var sessionDetails: (title: String, body: String)? {
        let conversation = feed.conversation
        var lines = [conversation.thinkingLevel.map { "Thinking: \($0)" }].compactMap { $0 }
        let whole = feed.hasEarlier ? wholeUsage : nil
        if let usage = whole ?? conversation.usage {
            lines.append("Tokens: \(usage.inputTokens.formatted()) in, \(usage.outputTokens.formatted()) out")
            if let cost = usage.cost { lines.append("Est. cost: \(cost.formatted(.currency(code: "USD")))") }
            if feed.hasEarlier { lines.append(whole != nil ? "Whole session" : "Loaded messages only") }
        }
        guard conversation.modelID != nil || !lines.isEmpty else { return nil }
        return (conversation.modelID ?? "Session", lines.joined(separator: "\n"))
    }

    /// An alert's text is fixed once shown, so the whole-session total comes first: one remote
    /// command, only when earlier messages aren't loaded. Slow or failed, the loaded totals show.
    private func showSessionDetails() async {
        guard !countingWholeUsage else { return }
        wholeUsage = nil
        if feed.hasEarlier, connection.isLive, let client = connection.client, let location {
            countingWholeUsage = true
            let usage = try? await withTimeout(.seconds(3)) { try await client.sessionUsage(path: location.path, format: location.format) }
            countingWholeUsage = false
            guard location == self.location else { return }
            wholeUsage = usage ?? nil
        }
        showsSessionDetails = true
    }

    private func press(_ keys: [String], failure: String) async {
        do { try await connection.sendKeys(keys, pane: paneID) } catch { sendError = "\(failure) \(error.localizedDescription)" }
    }

    /// herdr's own reasoning for the status, for when it looks wrong. Read-only.
    private func explainStatus() async {
        guard let client = connection.client, let session = connection.activeSession else { return }
        do {
            let lines = try await client.explainAgent(pane: paneID, session: session)
            explanation = lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        } catch {
            explanation = "This host's herdr couldn't explain the status. \(error.localizedDescription)"
        }
    }

    private var transcript: some View {
        let detail = detailOverride ?? settings.detailLevel
        let status = agent?.agentStatus
        // Not lazy: a lazy stack pinned to the bottom estimates the heights of rows it
        // hasn't drawn, and a new message re-anchors onto those estimates, which left the
        // screen blank until the next reply.
        return VStack(alignment: .leading, spacing: 14) {
            if let date = feed.offlineDate {
                Label("Offline copy · \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "icloud.slash")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            if feed.hasEarlier {
                Button("Show Earlier Messages") { feed.showEarlier() }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            if feed.conversation.hasIncompletePrefix {
                Text("This branch continues from messages that aren't loaded; some shown above it may be from another branch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            TranscriptRows(feed: feed, detail: detail, finished: status == .done || status == .idle)
                .equatable()
            ForEach(queued) { message in
                QueuedBubble(text: message.text, canUnsend: message.id == queued.last?.id && !unsending) {
                    Task { await unsend(message) }
                }
            }
            if let plan = openPlan {
                TodoCard(tool: plan)
            }
            // Reserved for the whole turn: a running step spins in its own row, so this
            // only fades out then, and the tail's height (which follow-latest tracks)
            // changes only when the turn starts or ends.
            if agent?.agentStatus == .working, feed.state == .live {
                let stepRunning = feed.conversation.items(at: detail).contains { if case .tool(let tool) = $0 { tool.state == .running } else { false } }
                WorkingRow()
                    .opacity(stepRunning ? 0 : 1)
                    .accessibilityHidden(stepRunning)
                    .animation(.snappy(duration: 0.15), value: stepRunning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if let link = connection.statusText { return link }
        guard let agent else { return "Exited" }
        let workspace = connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.label
        return [agent.agentStatus.label, workspace].compactMap { $0 }.joined(separator: " · ")
    }

    /// The agent's latest plan, while any of it is still to do.
    private var openPlan: ToolActivity? {
        for item in feed.conversation.items.reversed() {
            guard case .tool(let tool) = item, tool.isTodo else { continue }
            if case .todo(let items) = tool.detail, items.contains(where: { $0.state != .done }) { return tool }
            return nil
        }
        return nil
    }

    @ViewBuilder
    private var placeholder: some View {
        if agent == nil, connection.snapshot != nil {
            ContentUnavailableView {
                Label("Agent exited", systemImage: "moon.zzz")
            } description: {
                Text("This agent is no longer running in herdr.")
            } actions: {
                if let ended = endedAgent {
                    Button("Resume in New Tab", systemImage: "play") { resuming = ended }
                        .disabled(!connection.isLive)
                }
            }
        } else if !feed.isOfflineCopy, let reason = locateFailure ?? feed.state.unavailableReason {
            ContentUnavailableView {
                Label("No conversation", systemImage: "text.bubble")
            } description: {
                Text(reason)
            } actions: {
                NavigationLink("Open Terminal", value: Route.terminal(connection.address(paneID: paneID)))
                if let harness = agent?.agent { IntegrationOffer(connection: connection, harness: harness) }
            }
        } else if feed.state == .loading, !feed.isOfflineCopy, connection.snapshot != nil {
            ProgressView()
        } else if feed.state == .live, feed.conversation.items.isEmpty, queued.isEmpty, !sending, sentCount == 0 {
            // A quiet hint, gone the moment a message is on its way; the transcript file
            // only appears once the agent has the first message.
            Text("Send a message to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bottom bar

    /// The question the agent is blocked on, when its transcript says what it asked.
    private var pendingAsk: AskActivity? {
        guard locatedRef == agent?.agentSession, blocked, !feed.isOfflineCopy else { return nil }
        return feed.conversation.pendingAsk
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let ask = pendingAsk {
                AskPanel(ask: ask, omp: agent?.agent == "omp", answering: answering, paneID: paneID,
                         terminalAddress: connection.address(paneID: paneID)) { replies in
                    Task { await answer(ask, with: replies) }
                }
                .cardBackground()
                .id(ask.toolCallId)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if locatedRef == agent?.agentSession, blocked || planReview, let prompt = screenPrompt {
                PermissionCard(prompt: prompt, choosing: choosing, paneID: paneID, terminalAddress: connection.address(paneID: paneID)) { label in
                    Task { await choose(label, on: prompt) }
                }
                .cardBackground()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if blocked {
                NeedsYouBanner(paneID: paneID, terminalAddress: connection.address(paneID: paneID)).cardBackground()
            }
            MessageComposer(draft: $draft, attachments: $attachments, sending: sending || shareImportTaskID != nil, focus: $composerFocused,
                            actions: composerActions) { Task { await sendDraft() } }
                .disabled(!connection.isLive || agent == nil || feed.isOfflineCopy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.smooth, value: pendingAsk?.toolCallId)
        .animation(.smooth, value: screenPrompt)
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, shareImportTaskID == nil, connection.isLive, let agent,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // omp holds a message sent mid-turn as steering and can hand it back (Alt+Up).
        let queues = agent.agent == "omp" && agent.agentStatus == .working && attachments.isEmpty
        let usersBefore = userTexts.count
        let packageID = importedPackageID
        sending = true
        defer { sending = false }
        // Cleared before delivery so the keyboard stays up and anything typed meanwhile is kept.
        draft = ""
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: true, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            if queues { queued.append(QueuedSend(text: text, usersBefore: usersBefore)) }
            attachments = []
            sentCount += 1
            finishImport(packageID)
        } catch {
            draft = restoringDraft(text, before: draft)
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
        }
    }

    private var composerActions: [ComposerAction] {
        guard let agent, agent.agent == "omp", agent.agentStatus == .working, attachments.isEmpty else { return [] }
        return [ComposerAction(title: "Send After This Run", systemImage: "text.append") { Task { await sendFollowUp() } }]
    }

    /// omp's follow-up queue (Ctrl+Q): delivered when the run ends instead of steering it.
    /// The text is typed into omp's own editor, so that editor has to be empty first.
    private func sendFollowUp() async {
        let text = draft
        guard !sending, shareImportTaskID == nil, connection.isLive, let client = connection.client, let session = connection.activeSession,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let usersBefore = userTexts.count
        let packageID = importedPackageID
        sending = true
        defer { sending = false }
        draft = ""
        do {
            guard OmpEditor.draft(inScreen: try await client.readPane(paneID, session: session).text) == nil else {
                draft = restoringDraft(text, before: draft)
                sendError = "omp has unsent text in its editor. Clear it in the terminal first."
                return
            }
            try await connection.sendText(text, pane: paneID, submit: false)
            try await connection.sendKeys(["ctrl+q"], pane: paneID)
            queued.append(QueuedSend(text: text, usersBefore: usersBefore))
            sentCount += 1
            finishImport(packageID)
        } catch {
            draft = restoringDraft(text, before: draft)
            sendError = "The message wasn't queued. Your draft is still here. \(error.localizedDescription)"
        }
    }

    private var userTexts: [String] {
        feed.conversation.items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } }
    }

    /// A queued message leaves once the transcript has it, or once the turn ends (omp sends
    /// what it held, or someone at the desk took it back).
    private func settleQueue() {
        guard !queued.isEmpty else { return }
        if let status = agent?.agentStatus, status == .idle || status == .done {
            queued.removeAll()
            return
        }
        let users = userTexts
        queued.removeAll { message in
            users.dropFirst(message.usersBefore).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == message.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    /// omp's Alt+Up puts its last queued message back in its editor; that text moves to the
    /// composer here and omp's editor is cleared. If the agent took the message first, the
    /// editor stays empty and the transcript shows it as sent.
    private func unsend(_ message: QueuedSend) async {
        guard message.id == queued.last?.id, !unsending, let client = connection.client,
              let session = connection.activeSession else { return }
        unsending = true
        defer { unsending = false }
        do {
            let before = try await client.readPane(paneID, session: session)
            guard OmpEditor.draft(inScreen: before.text) == nil else {
                sendError = "omp has unsent text in its editor. Clear it in the terminal first."
                return
            }
            try await connection.sendKeys(["alt+up"], pane: paneID)
            try await Task.sleep(for: .milliseconds(300))
            let after = try await client.readPane(paneID, session: session)
            queued.removeAll { $0.id == message.id }
            guard OmpEditor.draft(inScreen: after.text) != nil else { return }
            // With text in its editor, Ctrl+C clears it and leaves the turn running.
            try await connection.sendKeys(["ctrl+c"], pane: paneID)
            draft = draft.isEmpty ? message.text : message.text + "\n" + draft
            composerFocused = true
        } catch {
            sendError = "The message couldn't be taken back. \(error.localizedDescription)"
        }
    }

    /// Drives the agent's own prompt one verified key at a time; see `PromptDriver`.
    private func answer(_ ask: AskActivity, with replies: [QuestionReply]) async {
        guard let client = connection.client, let session = connection.activeSession, !answering else { return }
        answering = true
        defer { answering = false }
        let feed = feed
        let io = HerdrPromptIO(client: client, pane: paneID, session: session) { id, timeout in
            await feed.waitForResult(of: id, timeout: timeout)
        }
        do {
            try await PromptDriver.answer(ask, replies: replies, io: io)
            sentCount += 1
        } catch {
            askFailure = Self.message(for: error)
        }
    }

    /// Picks an option on a permission or approval prompt; the prompt leaving the screen is the proof.
    private func choose(_ label: String, on prompt: ScreenPrompt) async {
        guard let client = connection.client, let session = connection.activeSession, choosing == nil else { return }
        choosing = label
        defer { choosing = nil }
        let io = HerdrPromptIO(client: client, pane: paneID, session: session) { _, _ in false }
        do {
            try await PromptDriver.choose(label, on: prompt, io: io)
            screenPrompt = nil
            sentCount += 1
        } catch {
            askFailure = Self.message(for: error)
        }
    }

    /// Finds the transcript file. Claude Code and Codex name only a session id, which the
    /// host resolves to a path; a dropped channel or a file not flushed yet gets a few retries.
    private func locateTranscript() async {
        guard !Task.isCancelled else { return }
        guard let ref = agent?.agentSession else { return }
        if locatedRef != ref {
            locatedRef = ref
            location = nil
            locateFailure = nil
            feed = ConversationFeed()
            screenPrompt = nil
            queued = []
        }
        guard let client = connection.client, let session = connection.activeSession else {
            // Offline: a reported path is enough to paint a kept copy.
            if location == nil, let path = ref.transcriptPath, let format = TranscriptFormat(agent: ref.agent) {
                location = TranscriptLocation(path: path, format: format)
            }
            return
        }
        for attempt in 1...4 {
            let failure: String
            do {
                let found = try await client.locateTranscript(ref, pane: paneID, session: session)
                guard !Task.isCancelled, agent?.agentSession == ref else { return }
                if let found { location = found; locateFailure = nil; return }
                failure = "The agent's transcript isn't on the host."
            } catch {
                failure = "The agent's transcript couldn't be found."
                guard !Task.isCancelled, agent?.agentSession == ref else { return }
            }
            guard attempt < 4 else {
                // A location found before the drop is still right; keep following it.
                if location == nil, connection.isLive { locateFailure = failure }
                return
            }
            guard (try? await Task.sleep(for: .seconds(2 * attempt))) != nil else { return }
        }
    }

    /// Reads the agent's screen while it is blocked with no transcript question, so a
    /// permission prompt can be answered here. Stops as soon as the agent moves on.
    private func watchScreenPrompt() async {
        guard blocked || planReview, pendingAsk == nil, let client = connection.client,
              let session = connection.activeSession else {
            screenPrompt = nil
            return
        }
        while !Task.isCancelled {
            if choosing == nil, let text = try? await client.readPane(paneID, session: session).text {
                guard !Task.isCancelled else { return }
                let parsed = ScreenPrompt.parse(text)
                screenPrompt = parsed?.style == .choice && parsed?.phase == .question ? parsed : nil
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? PromptDriverError else {
            return "The connection dropped before the answer was confirmed."
        }
        return switch error {
        case .noPrompt: "The prompt isn't on the agent's screen anymore."
        case .questionMismatch, .optionNotFound: "The agent's screen shows a different prompt than this one, so nothing was sent."
        case .cursorLost: "The selection didn't move as expected, so nothing was submitted."
        case .unexpectedScreen: "The agent's prompt changed partway through, so the rest wasn't sent."
        case .unsupported: "This kind of answer has to be typed in the terminal."
        case .notConfirmed: "The agent hasn't confirmed the answer yet."
        }
    }

    private func subagentRoute(_ activity: SubagentActivity) -> Route? {
        guard let location, let path = SubagentTranscript.path(parentPath: location.path, format: location.format, subagentID: activity.id) else { return nil }
        let type = activity.agentType.map { " · \($0)" } ?? ""
        return .subagent(connection.address(paneID: paneID), path, location.format.rawValue, activity.name + type)
    }

    private func openSubagent(_ route: Route) {
        scene.navigationPath.append(route)
    }

}
private struct LocateKey: Hashable {
    let liveID: Int
    let ref: AgentSessionRef?
}

private struct FeedKey: Hashable {
    let liveID: Int
    let location: TranscriptLocation?
    let window: Int
    let feedID: ObjectIdentifier
}

private struct PromptKey: Hashable {
    let liveID: Int
    let watching: Bool
    let ref: AgentSessionRef?
}

private struct SharedImportKey: Hashable {
    let importID: UUID?
    let draftID: String?
    let stagedID: UUID?
    let sending: Bool
}

private struct ReadKey: Hashable {
    let sequence: Int?
    let visible: Bool
}

/// The ⋯ menu, compared by value: a menu that is rebuilt while open jumps back to its top, and
/// the conversation re-renders with every streamed record. So nothing here changes per reply:
/// thinking level, tokens and estimated cost open in an alert.
struct ConversationMenu: View, Equatable {
    struct Mute: Equatable {
        let address: PaneAddress
        let reference: String
    }
    enum LiveActivity { case show, hide }
    enum Action { case detail(DetailLevel), find, retry, stop, liveActivity, sessionDetails, explain }

    let detail: DetailLevel
    let canRetry: Bool
    let canStop: Bool
    let liveActivity: LiveActivity?
    /// The model's name (or "Session"); nil when the transcript records none of it.
    let session: String?
    let sessionHasDetails: Bool
    let mute: Mute?
    /// The agent's status label; nil without an agent.
    let status: String?
    let act: (Action) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.detail == rhs.detail && lhs.canRetry == rhs.canRetry && lhs.canStop == rhs.canStop
            && lhs.liveActivity == rhs.liveActivity && lhs.session == rhs.session
            && lhs.sessionHasDetails == rhs.sessionHasDetails && lhs.mute == rhs.mute
            && lhs.status == rhs.status
    }

    var body: some View {
        Menu {
            DetailLevelOptions(selection: Binding(get: { detail }, set: { act(.detail($0)) }))
            Button("Find in Conversation") { act(.find) }
            if canRetry {
                Section { Button("Retry Last Turn") { act(.retry) } }
            }
            if canStop {
                Section { Button("Stop Run", role: .destructive) { act(.stop) } }
            }
            if let liveActivity {
                Section {
                    Button(liveActivity == .hide ? "Hide Live Activity" : "Show Live Activity") { act(.liveActivity) }
                }
            }
            if let session {
                if sessionHasDetails {
                    Section(session) { Button("Session Details") { act(.sessionDetails) } }
                } else {
                    Section { Text(session) }
                }
            }
            if let mute {
                Section {
                    if Mutes.shared.isMuted(mute.address, reference: mute.reference) {
                        Button("Unmute Notifications") { Mutes.shared.unmute(mute.address, reference: mute.reference) }
                    } else {
                        Menu("Mute Notifications") {
                            Button("For 1 Hour") {
                                Mutes.shared.set(mute.address, reference: mute.reference, until: .now.addingTimeInterval(3600))
                            }
                            Button("Until Unmuted") { Mutes.shared.set(mute.address, reference: mute.reference, until: nil) }
                        }
                    }
                }
            }
            if let status {
                Section { Button("Why “\(status)”?") { act(.explain) } }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityLabel("Conversation Actions")
    }
}

// MARK: - Rows

/// Keep projection dependent only on transcript data and presentation preferences, not
/// the composer's draft, focus or scroll state. Observation still tracks the feed here.
private struct TranscriptRows: View, Equatable {
    let feed: ConversationFeed
    let detail: DetailLevel
    let finished: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feed === rhs.feed && lhs.detail == rhs.detail && lhs.finished == rhs.finished
    }

    var body: some View {
        let items = feed.conversation.items(at: detail)
        let finalAssistantID = items.reversed().first { if case .assistant = $0 { true } else { false } }?.id
        ForEach(ConversationRow.rows(items, full: detail == .full,
                                     lastAssistantID: detail == .digest && finished ? finalAssistantID : nil,
                                     subagents: { feed.conversation.subagents(spawnedBy: $0) })) { row in
            row.view.id(row.id)
        }
    }
}

/// Transcript items as the chat shows them: runs of tool calls and thinking fold into
/// one "steps" row so the words stay readable.
enum ConversationRow: Identifiable {
    case item(ConversationItem, finished: Bool)
    case steps([ConversationItem], full: Bool)
    /// The step that spawned subagents, shown as their status instead of a tool row.
    case subagents(callID: String, [SubagentActivity])

    var id: String {
        switch self {
        case .item(let item, _): item.id
        case .steps(let items, let full): "steps-" + (items.first?.id ?? "") + (full ? "-full" : "")
        case .subagents(let callID, _): "subagents-" + callID
        }
    }

    static func rows(_ items: [ConversationItem], full: Bool = false,
                     lastAssistantID: String? = nil,
                     subagents: (String) -> [SubagentActivity] = { _ in [] }) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var run: [ConversationItem] = []
        for item in items {
            switch item {
            case .tool(let tool):
                let children = subagents(tool.id)
                if children.isEmpty {
                    run.append(item)
                } else {
                    if !run.isEmpty { rows.append(.steps(run, full: full)); run = [] }
                    rows.append(.subagents(callID: tool.id, children))
                }
            case .thinking, .raw:
                run.append(item)
            default:
                if !run.isEmpty { rows.append(.steps(run, full: full)); run = [] }
                rows.append(.item(item, finished: item.id == lastAssistantID))
            }
        }
        if !run.isEmpty { rows.append(.steps(run, full: full)) }
        return rows
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .item(.user(_, let text, let images), _): UserBubble(text: text, images: images)
        case .item(.assistant(_, let text), let finished):
            HStack(alignment: .firstTextBaseline) {
                MarkdownText(text: text)
                if finished { Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
        case .item(.ask(let ask), _): if ask.answer != nil { AnsweredAsk(ask: ask) }
        case .item(.notice(_, let text, _), _): NoticeRow(text: text)
        case .item(.peerMessage(_, let peer, let text, let outbound), _):
            PeerMessageCard(peer: peer, text: text, outbound: outbound)
        case .steps(let items, let full): StepsRow(items: items, full: full)
        case .subagents(_, let activities): SubagentGroupRow(activities: activities)
        case .item(.subagentResult(_, let activity), _): SubagentResultRow(activity: activity)
        case .item: EmptyView()
        }
    }
}

struct QueuedSend: Identifiable {
    let id = UUID()
    let text: String
    /// User messages in the transcript when this was sent; only later ones can be it.
    let usersBefore: Int
}

/// A sent message omp hasn't taken yet. The newest one can be tapped back into the composer.
private struct QueuedBubble: View {
    let text: String
    let canUnsend: Bool
    let unsend: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: unsend) {
                UserBubble(text: text, images: [])
                    .opacity(0.55)
            }
            .buttonStyle(.plain)
            .disabled(!canUnsend)
            Text(canUnsend ? "Queued · Tap to Edit" : "Queued")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued: \(text)")
        .accessibilityHint(canUnsend ? "Takes the message back to edit" : "")
        .accessibilityAddTraits(canUnsend ? .isButton : [])
    }
}

private struct UserBubble: View {
    let text: String
    let images: [TranscriptImage]

    /// omp and Claude put "[Image #1, 1568x1047]" where a pasted image went; the label says it already.
    private var shown: String {
        guard !images.isEmpty else { return text }
        return text.replacing(/\[Image #\d+(?:, \d+x\d+)?\]\s*/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            // Images sit above the bubble, clear of the text selection's touch area, which
            // otherwise takes taps meant for the "Image" label.
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty { TranscriptImages(images: images) }
                if !shown.isEmpty {
                    ClampedText(text: shown, lines: 12)
                        .textSelection(.enabled)
                        .tint(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: .rect(cornerRadius: 20))
                }
            }
        }
    }
}

private struct PeerMessageCard: View {
    let peer: String
    let text: String
    let outbound: Bool
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.subagentNamed) private var subagentNamed
    @State private var expanded = false

    var body: some View {
        HStack {
            if outbound { Spacer(minLength: 44) }
            VStack(alignment: outbound ? .trailing : .leading, spacing: 6) {
                header
                Text(MarkdownText.inline(text))
                    .lineLimit(expanded ? nil : 8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.split(separator: "\n").count > 8 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .font(.caption)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: outbound ? .trailing : .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(outbound ? Color.accentColor.opacity(0.35) : .clear) }
            if !outbound { Spacer(minLength: 44) }
        }
    }

    /// A message to or from one of this agent's subagents opens that subagent's thread.
    @ViewBuilder
    private var header: some View {
        let label = Label("\(outbound ? "to" : "from") \(peer)", systemImage: "bubble.left.and.bubble.right")
            .font(.caption)
        if let openSubagent, let activity = subagentNamed?(peer) {
            Button { openSubagent(activity) } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityHint("Opens the subagent's thread")
        } else {
            label.foregroundStyle(.secondary)
        }
    }
}

private struct NoticeRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private struct AnsweredAsk: View {
    let ask: AskActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ask.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question).font(.subheadline.weight(.medium))
                    if let answer = ask.answer, !answer.cancelled {
                        Label(reply(to: question, in: answer), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            if ask.answer?.cancelled == true {
                Label("Dismissed", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
    }

    /// This question's own answer; older records only carry the combined list.
    private func reply(to question: AskQuestion, in answer: AskAnswer) -> String {
        let values = answer.perQuestion[question.question] ?? answer.selected + [answer.custom].compactMap { $0 }
        let note = answer.perQuestionNotes[question.question] ?? (answer.perQuestion.isEmpty ? answer.note : nil)
        return (values.joined(separator: ", ") + (note.map { " — Note: \($0)" } ?? ""))
    }
}

/// Tool calls and thinking between two messages, folded to one line until opened.
private struct StepsRow: View {
    let items: [ConversationItem]
    let full: Bool
    @State private var expanded: Bool

    init(items: [ConversationItem], full: Bool) {
        self.items = items
        self.full = full
        _expanded = State(initialValue: full)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in StepLine(item: item, full: full) }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: "gearshape.2").foregroundStyle(.secondary) }
                Text(summary + (failedCount > 0 ? " · \(failedCount) failed" : "")).lineLimit(1)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    private var tools: [ToolActivity] {
        items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }
    }
    private var failedCount: Int { tools.filter { $0.state == .failed }.count }
    private var running: Bool { tools.contains { $0.state == .running } }
    private var summary: String {
        guard let last = tools.last else { return "Thinking" }
        return tools.count == 1 ? last.summary : "\(tools.count) steps · \(last.summary)"
    }
}

private struct StepLine: View {
    let item: ConversationItem
    let full: Bool
    @State private var showsOutput = false

    init(item: ConversationItem, full: Bool = false) {
        self.item = item
        self.full = full
    }

    var body: some View {
        switch item {
        case .tool(let tool):
            ToolStepView(tool: tool, expanded: full)
        case .thinking(_, let text):
            Text(text).font(.caption.italic()).foregroundStyle(.secondary)
                .lineLimit(showsOutput ? nil : 3).onTapGesture { showsOutput.toggle() }
        case .raw(_, let type, let text):
            Text("\(type): \(text)").font(.caption2.monospaced())
                .foregroundStyle(.tertiary).lineLimit(2)
        default: EmptyView()
        }
    }
}

private struct WorkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.footnote)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Asks

/// The agent's question with its options as one selectable list. The recommended option
/// starts selected and is tagged; nothing is sent until Send (or Next through several
/// questions). A typed "Other" answer replaces a single choice and joins a multiple one
/// (omp only). omp also takes a note per question. Long text clamps with "More".
private struct AskPanel: View {
    let ask: AskActivity
    /// omp's prompt, which the driver can also give a note and "Other" beside checkboxes.
    let omp: Bool
    let answering: Bool
    let paneID: String
    let terminalAddress: PaneAddress
    let onSubmit: ([QuestionReply]) -> Void

    @State private var page = 0
    @State private var replies: [QuestionReply]
    @State private var other = ""
    @State private var note = ""
    @FocusState private var otherFocused: Bool

    init(ask: AskActivity, omp: Bool, answering: Bool, paneID: String, terminalAddress: PaneAddress, onSubmit: @escaping ([QuestionReply]) -> Void) {
        self.ask = ask; self.omp = omp; self.answering = answering; self.paneID = paneID
        self.terminalAddress = terminalAddress; self.onSubmit = onSubmit
        _replies = State(initialValue: ask.questions.map { question in
            guard !question.multi, let index = question.recommended, question.options.indices.contains(index) else {
                return QuestionReply()
            }
            return QuestionReply(selected: [question.options[index].label])
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if answerable, ask.questions.indices.contains(page) {
                let question = ask.questions[page]
                header(question)
                ClampedText(text: question.question, font: .headline, lines: 4)
                if question.multi {
                    Text("Choose any").font(.caption).foregroundStyle(.secondary)
                }
                options(question)
                if !question.multi || omp {
                    otherField
                }
                if omp {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
                        .disabled(answering)
                }
                footer(question)
            } else if let question = ask.questions.first {
                ClampedText(text: question.question, font: .headline, lines: 4)
            }
            NavigationLink(value: Route.terminal(terminalAddress)) {
                Text(answerable ? "Answer in Terminal Instead" : "Answer in Terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(answering)
        }
    }

    private var answerable: Bool {
        !ask.questions.isEmpty && ask.questions.allSatisfy { !$0.options.isEmpty }
    }

    private var isLastPage: Bool { page == ask.questions.count - 1 }

    private var trimmedOther: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private func header(_ question: AskQuestion) -> some View {
        let title = [question.header, ask.questions.count > 1 ? "\(page + 1) of \(ask.questions.count)" : nil]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        if !title.isEmpty {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// One rounded group of rows, like a Settings list: content, not controls, so no glass.
    private func options(_ question: AskQuestion) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Divider().padding(.leading, 44) }
                optionRow(option, in: question, recommended: question.recommended == index)
            }
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        .disabled(answering)
    }

    private func optionRow(_ option: AskOption, in question: AskQuestion, recommended: Bool) -> some View {
        let chosen = (question.multi || trimmedOther.isEmpty) && replies[page].selected.contains(option.label)
        let symbol = question.multi
            ? (chosen ? "checkmark.square.fill" : "square")
            : (chosen ? "checkmark.circle.fill" : "circle")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(option.label).font(.body.weight(.medium))
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(.tint.opacity(0.6)))
                    }
                }
                if let description = option.description, !description.isEmpty {
                    ClampedText(text: description, font: .subheadline, lines: 2, style: .secondary)
                }
                if let preview = option.preview, !preview.isEmpty {
                    ClampedText(text: preview, font: .caption.monospaced(), lines: 3, style: .secondary)
                        .padding(8)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture { pick(option.label, multi: question.multi) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(recommended ? "Recommended" : "")
    }

    private var otherField: some View {
        TextField("Other answer", text: $other)
            .focused($otherFocused)
            .submitLabel(isLastPage ? .send : .next)
            .onSubmit(advance)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .disabled(answering)
    }

    private func footer(_ question: AskQuestion) -> some View {
        HStack {
            if page > 0 {
                Button("Back") {
                    commit()
                    page -= 1
                    load()
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button(action: advance) {
                if answering && isLastPage { ProgressView() } else { Text(isLastPage ? "Send" : "Next") }
            }
            .buttonStyle(.glassProminent)
            .disabled(trimmedOther.isEmpty && replies[page].selected.isEmpty)
        }
        .disabled(answering)
    }

    private func pick(_ label: String, multi: Bool) {
        if multi {
            if let index = replies[page].selected.firstIndex(of: label) {
                replies[page].selected.remove(at: index)
            } else {
                replies[page].selected.append(label)
            }
        } else {
            other = ""
            replies[page].selected = [label]
        }
    }

    /// The page's typed fields into its reply: "Other" replaces a single choice, joins a multiple one.
    private func commit() {
        let multi = ask.questions[page].multi
        replies[page].custom = trimmedOther.isEmpty ? nil : trimmedOther
        if !multi, replies[page].custom != nil { replies[page].selected = [] }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        replies[page].note = omp && !trimmedNote.isEmpty ? trimmedNote : nil
    }

    private func load() {
        other = replies[page].custom ?? ""
        note = replies[page].note ?? ""
    }

    private func advance() {
        guard !trimmedOther.isEmpty || !replies[page].selected.isEmpty else { return }
        commit()
        otherFocused = false
        if isLastPage {
            onSubmit(replies)
        } else {
            page += 1
            load()
        }
    }
}

/// Text cut to `lines`, with a "More" control only when it's actually cut.
struct ClampedText: View {
    let text: String
    var font: Font = .body
    var lines = 3
    /// Nil keeps the inherited style (white inside a bubble).
    var style: HierarchicalShapeStyle? = nil

    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(font)
                .foregroundStyle(style.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .lineLimit(expanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    // The full text fits the clamped frame only when nothing was cut.
                    ViewThatFits(in: .vertical) {
                        Text(text).font(font).fixedSize(horizontal: false, vertical: true).hidden()
                            .onAppear { truncated = false }
                        Color.clear.onAppear { truncated = true }
                    }
                }
            if truncated || expanded {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
    }
}

/// A permission or approval prompt read off the agent's screen (Claude's "Do you want to
/// proceed?", Codex's "Would you like to run the following command?"), with its options.
private struct PermissionCard: View {
    let prompt: ScreenPrompt
    let choosing: String?
    let paneID: String
    let terminalAddress: PaneAddress
    let onChoose: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.title, systemImage: AgentStatus.blocked.symbol)
                .font(.headline).foregroundStyle(AgentStatus.blocked.tint)
            if !prompt.context.isEmpty {
                let clipped = prompt.context.count > 10
                Group {
                    if expanded {
                        ScrollView { contextText }.frame(maxHeight: 320)
                    } else {
                        contextText.lineLimit(10)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                if clipped || expanded {
                    Button(expanded ? "Show Less" : "Show All \(prompt.context.count) Lines") { expanded.toggle() }
                        .font(.footnote)
                }
                Text(prompt.contextMayBeTruncated
                     ? "Only the part on the agent's screen is shown; the full text is in the terminal."
                     : "As the agent's screen shows it; anything cut off there is in the terminal.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Every option looks alike: the first is not necessarily the safe or usual one.
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                        button(option).buttonStyle(.glass)
                    }
                }
            }
            NavigationLink(value: Route.terminal(terminalAddress)) {
                Text("Open Terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).disabled(choosing != nil)
        }
    }

    private var contextText: some View {
        Text(prompt.context.joined(separator: "\n")).font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ option: ScreenPrompt.Option) -> some View {
        Button { onChoose(option.label) } label: {
            HStack {
                Text(option.label).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if choosing == option.label { ProgressView() }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
        .disabled(choosing != nil)
    }
}

private struct NeedsYouBanner: View {
    let paneID: String
    let terminalAddress: PaneAddress

    var body: some View {
        HStack {
            Label("Waiting for you in the terminal", systemImage: AgentStatus.blocked.symbol)
                .font(.subheadline).foregroundStyle(AgentStatus.blocked.tint)
            Spacer()
            NavigationLink("Open", value: Route.terminal(terminalAddress))
                .buttonStyle(.glassProminent)
        }
    }
}

private extension View {
    /// Cards above the composer sit over the scrolling transcript, so they need their own surface.
    func cardBackground() -> some View {
        padding(14).background(.regularMaterial, in: .rect(cornerRadius: 24))
    }
}

/// What following the latest message reacts to: the transcript's size and the viewport's,
/// including the keyboard and composer insets; never the offset itself.
private struct TailGeometry: Equatable {
    struct Layout: Equatable {
        let content: CGFloat
        let container: CGFloat
        let insets: EdgeInsets
    }
    let layout: Layout
    let nearBottom: Bool

    init(_ geometry: ScrollGeometry) {
        layout = Layout(content: geometry.contentSize.height, container: geometry.containerSize.height,
                        insets: geometry.contentInsets)
        // The viewport runs under the composer, ask card and keyboard insets; without taking them
        // off, a scroll of up to that height (half the screen with the keyboard up) still counts
        // as the bottom, and letting go snaps back to it.
        nearBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 80
    }
}
