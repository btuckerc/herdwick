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
    @State private var detailOverride: DetailLevel?
    private var detailSelection: Binding<DetailLevel> {
        Binding(get: { detailOverride ?? settings.detailLevel }, set: { detailOverride = $0 })
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
    @State private var explanation: String?
    /// The ended agent being resumed from the "Agent exited" state.
    @State private var resuming: EndedAgent?
    /// The shared package already merged into this conversation's draft.
    @State private var importedPackageID: UUID?
    /// Find in the loaded messages: the query and which match is in view; nil when closed.
    @State private var find: (query: String, index: Int)?
    @FocusState private var findFocused: Bool

    private var agent: Agent? { connection.snapshot?.agents.first { $0.paneID == paneID } }
    private var blocked: Bool { agent?.agentStatus == .blocked }
    /// omp waits on its Plan Review screen while herdr reports it idle, so the transcript says when.
    private var planReview: Bool {
        agent?.agent == "omp" && agent?.agentStatus != .working && feed.conversation.pendingPlanReview != nil
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
    private func importSharedDraft() {
        guard let id = scene.importPackageID, importedPackageID != id, let draftID,
              scene.importDraftID == draftID || scene.importAddress == connection.address(paneID: paneID),
              let package = SharedInbox.shared.package(id) else { return }
        scene.importPackageID = nil
        scene.importDraftID = nil
        scene.importAddress = nil
        do {
            if SharedInbox.shared.packages.contains(where: { $0.staged == draftID && $0.id != id }) {
                throw SharedInbox.Occupied()
            }
            let incoming = try package.images.map { try DraftAttachment.prepare($0.data, filename: $0.filename, imageRequired: true) }
            guard attachments.count + incoming.count <= SharePackage.maximumImages else { throw AttachmentError.tooMany }
            if package.staged != draftID { try SharedInbox.shared.stage(id, in: draftID) }
            if !package.text.isEmpty, !draft.contains(package.text) {
                let merged = draft.isEmpty ? package.text : draft + "\n" + package.text
                guard DraftStore.save(merged, for: draftID) else { throw CocoaError(.fileWriteUnknown) }
                draft = merged
            }
            attachments += incoming
            importedPackageID = id
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// A conversation opened any way restores the images of the share staged in its draft.
    private func restoreStagedShare() {
        guard importedPackageID == nil, let draftID,
              let package = SharedInbox.shared.packages.first(where: { $0.staged == draftID }) else { return }
        do {
            let incoming = try package.images.map { try DraftAttachment.prepare($0.data, filename: $0.filename, imageRequired: true) }
            guard attachments.count + incoming.count <= SharePackage.maximumImages else { throw AttachmentError.tooMany }
            attachments += incoming
            importedPackageID = package.id
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// After a successful send, the share staged in this draft leaves the shelf.
    private func finishImport() {
        guard let id = importedPackageID else { return }
        do {
            try SharedInbox.shared.remove(id)
            importedPackageID = nil
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Split from `body`, whose single modifier chain overran the type-checker's time limit.
    private var observed: some View {
        scroller
            .toolbar { toolbar }
            .task(id: LocateKey(liveID: connection.liveID, ref: agent?.agentSession)) {
                await locateTranscript()
            }
            .task(id: FeedKey(liveID: connection.liveID, location: location, window: feed.window)) {
                // A kept offline copy paints first, even with no connection.
                if let location { feed.restore(location, host: connection.identity) }
                // A channel can end while the transport lives on (a brief background, a killed
                // `tail`): follow again. A dead transport bumps `liveID`, which restarts this task.
                while !Task.isCancelled, connection.isLive, let client = connection.client, let location {
                    await feed.follow(location, client: client, host: connection.identity)
                    guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                }
            }
            .task(id: PromptKey(liveID: connection.liveID, watching: (blocked || planReview) && pendingAsk == nil)) {
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
            .onChange(of: scene.importPackageID, initial: true) { importSharedDraft() }
            .onChange(of: draftID) { importSharedDraft(); restoreStagedShare() }
    }

    /// Read means seen: the app is in front, this agent's transcript has painted live and its
    /// end is on screen. An error or a still-loading feed is never a read.
    private var showsLatest: Bool {
        scenePhase == .active && feed.state == .live && !feed.isOfflineCopy && locateFailure == nil && atLatest
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
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
            Menu {
                DetailLevelOptions(selection: detailSelection)
                Button("Find in Conversation", systemImage: "magnifyingglass") {
                    find = (find?.query ?? "", 0)
                    findFocused = true
                }
                if canRetry {
                    Section {
                        Button("Retry Last Turn", systemImage: "arrow.clockwise") {
                            Task { await press(["alt+r"], failure: "The retry wasn't sent.") }
                        }
                    }
                }
                if let agent, connection.isLive, !feed.isOfflineCopy {
                    let watching = model.watchedRun.address == connection.address(paneID: paneID)
                    if watching || agent.agentStatus == .working {
                        Section {
                            if watching {
                                Button("Stop Watching Run", systemImage: "eye.slash") {
                                    Task { await model.watchedRun.stop(push: model.push) }
                                }
                            } else {
                                Button("Watch This Run", systemImage: "eye") {
                                    Task {
                                        await model.watchedRun.start(connection: connection, agent: agent, push: model.push)
                                        if let error = model.watchedRun.error { sendError = error }
                                    }
                                }
                            }
                        }
                    }
                }
                if let details = sessionDetails {
                    Section(details.title) { Text(details.body) }
                }
                if let agent {
                    if let reference = agent.agentSession?.value {
                        let address = connection.address(paneID: paneID)
                        Section {
                            if Mutes.shared.isMuted(address, reference: reference) {
                                Button("Unmute Notifications", systemImage: "bell") { Mutes.shared.unmute(address, reference: reference) }
                            } else {
                                Menu("Mute Notifications", systemImage: "bell.slash") {
                                    Button("For 1 Hour") { Mutes.shared.set(address, reference: reference, until: .now.addingTimeInterval(3600)) }
                                    Button("Until Unmuted") { Mutes.shared.set(address, reference: reference, until: nil) }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Why “\(agent.agentStatus.label)”?", systemImage: "questionmark.circle") {
                            Task { await explainStatus() }
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityLabel("Conversation Actions")
        }
    }

    /// Esc interrupts a running turn in omp, Claude Code and Codex alike.
    private var stopSupported: Bool {
        guard let agent, !feed.isOfflineCopy else { return false }
        return ["omp", "claude", "codex"].contains(agent.agent)
    }

    private var canStop: Bool {
        stopSupported && agent?.agentStatus == .working && connection.isLive
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
            Button("Done") { find = nil; findFocused = false }
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

    /// Model, thinking level and the usage recorded in the loaded part of the transcript.
    private var sessionDetails: (title: String, body: String)? {
        let conversation = feed.conversation
        var lines = [conversation.thinkingLevel.map { "Thinking: \($0)" }].compactMap { $0 }
        if let usage = conversation.usage {
            lines.append("Tokens: \(usage.inputTokens.formatted()) in, \(usage.outputTokens.formatted()) out")
            if let cost = usage.cost { lines.append("Cost: \(cost.formatted(.currency(code: "USD")))") }
            if feed.hasEarlier { lines.append("Loaded messages only") }
        }
        guard conversation.modelID != nil || !lines.isEmpty else { return nil }
        return (conversation.modelID ?? "Session", lines.joined(separator: "\n"))
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
        let items = feed.conversation.items(at: detail)
        let finalAssistantID = items.reversed().first { if case .assistant = $0 { true } else { false } }?.id
        let finished = detail == .digest && (agent?.agentStatus == .done || agent?.agentStatus == .idle)
        // Not lazy: a lazy stack pinned to the bottom estimates the heights of rows it
        // hasn't drawn, and a new message re-anchors onto those estimates, which left the
        // screen blank until the next reply. The transcript window bounds the row count.
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
            ForEach(ConversationRow.rows(items, full: detail == .full,
                                         lastAssistantID: finished ? finalAssistantID : nil,
                                         subagents: { feed.conversation.subagents(spawnedBy: $0) })) { row in
                row.view.id(row.id)
            }
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
                let stepRunning = items.contains { if case .tool(let tool) = $0 { tool.state == .running } else { false } }
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
        guard blocked, !feed.isOfflineCopy else { return nil }
        return feed.conversation.pendingAsk
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let ask = pendingAsk {
                AskPanel(ask: ask, omp: agent?.agent == "omp", answering: answering, paneID: paneID,
                         terminalAddress: connection.address(paneID: paneID)) { replies in
                    Task { await answer(ask, with: replies) }
                }
                .id(ask.toolCallId)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if blocked || planReview, let prompt = screenPrompt {
                PermissionCard(prompt: prompt, choosing: choosing, paneID: paneID, terminalAddress: connection.address(paneID: paneID)) { label in
                    Task { await choose(label, on: prompt) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if blocked {
                NeedsYouBanner(paneID: paneID, terminalAddress: connection.address(paneID: paneID))
            }
            MessageComposer(draft: $draft, attachments: $attachments, sending: sending, focus: $composerFocused,
                            actions: composerActions, onStop: stopSupported ? { confirmStop = true } : nil,
                            canStop: canStop) { Task { await sendDraft() } }
                .confirmationDialog("Stop this run?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop", role: .destructive) { Task { await press(["esc"], failure: "The agent couldn't be stopped.") } }
                } message: {
                    Text("Sends Esc to the agent, as at the desk. Messages it was holding go back to its editor.")
                }
                .disabled(!connection.isLive || agent == nil || feed.isOfflineCopy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.smooth, value: pendingAsk?.toolCallId)
        .animation(.smooth, value: screenPrompt)
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, connection.isLive, let agent,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // omp holds a message sent mid-turn as steering and can hand it back (Alt+Up).
        let queues = agent.agent == "omp" && agent.agentStatus == .working && attachments.isEmpty
        let usersBefore = userTexts.count
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
            finishImport()
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
        guard !sending, connection.isLive, let client = connection.client, let session = connection.activeSession,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let usersBefore = userTexts.count
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
            finishImport()
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
        guard let ref = agent?.agentSession else { return }
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
                location = try await client.locateTranscript(ref, pane: paneID, session: session)
                if location != nil { locateFailure = nil; return }
                failure = "The agent's transcript isn't on the host."
            } catch {
                failure = "The agent's transcript couldn't be found."
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
}

private struct PromptKey: Hashable {
    let liveID: Int
    let watching: Bool
}

private struct ReadKey: Hashable {
    let sequence: Int?
    let visible: Bool
}

// MARK: - Rows

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
            case .tool(let tool) where !subagents(tool.id).isEmpty:
                if !run.isEmpty { rows.append(.steps(run, full: full)); run = [] }
                rows.append(.subagents(callID: tool.id, subagents(tool.id)))
            case .tool, .thinking, .raw:
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
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty { TranscriptImages(images: images) }
                if !shown.isEmpty {
                    ClampedText(text: shown, lines: 12)
                        .textSelection(.enabled)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: .rect(cornerRadius: 20))
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
        nearBottom = geometry.visibleRect.maxY >= geometry.contentSize.height - 80
    }
}
