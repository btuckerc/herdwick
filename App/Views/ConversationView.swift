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
    /// Sent messages the transcript doesn't have yet, shown from the tap on. omp holds some
    /// (steering, follow-ups) until the agent next takes input; the last of those can be unsent.
    @State private var pending: [PendingSend] = []
    @State private var unsending = false
    /// Find's temporary switch to Folded for a match Digest hides; Done or a chosen level clears it.
    @State private var detailOverride: DetailLevel?
    /// The match Find last went to; the run holding it opens.
    @State private var findTarget: String?
    /// The saved preference, shared with Settings.
    private var detailSelection: Binding<DetailLevel> {
        Binding(get: { settings.detailLevel }, set: { settings.detailLevel = $0; detailOverride = nil })
    }
    @State private var sentCount = 0
    @FocusState private var composerFocused: Bool
    @State private var keyboardDismissals = 0
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
    @State private var photoSaver = PhotoSaver()
    @State private var confirmStop = false
    @State private var showsSessionDetails = false
    @State private var showsImages = false
    @State private var showsChanges = false
    @State private var showsNow = false
    /// Where the reader left this conversation before this visit; fixed until they leave.
    @State private var arrival: ReadCursors.Mark?
    /// The "Since 9:41" line sits over the composer until tapped or a message is sent.
    @State private var catchUpPinned = true
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
            .sheet(isPresented: $showsImages) {
                ImageGrid(loaded: feed.conversation.toolImages, whole: wholeImages,
                          loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.cwd))
            }
            .sheet(isPresented: $showsChanges) { ChangesSheet(edits: feed.conversation.recordedEdits) }
            .sheet(isPresented: $showsNow) { nowSheet }
            .onChange(of: DraftStore.id(host: connection.identity, agent: agent), initial: true) { _, id in arrive(id) }
            // The cursor moves only while the end is on screen: reading is what moves it.
            .onChange(of: showsLatest ? feed.conversation.lastStableID : nil) { _, item in
                guard demo == nil, let item, let id = DraftStore.id(host: connection.identity, agent: agent) else { return }
                ReadCursors.save(item, for: id)
            }
    }

    /// Where this visit starts from. The demo is never saved; `-HerdwickSeen` stands in, last
    /// read at 9:16 today so the line agrees with the captures' 9:41 status bar.
    private func arrive(_ id: String?) {
        catchUpPinned = true
        if let demo {
            let seen = Calendar.current.date(bySettingHour: 9, minute: 16, second: 0, of: .now) ?? .now
            arrival = demo.launch?.seen.map { ReadCursors.Mark(item: $0, seen: seen) }
        } else {
            arrival = id.flatMap(ReadCursors.load)
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
        .environment(\.openSubagent, EnvironmentAction { activity in
            if let route = subagentRoute(activity) { openSubagent(route) }
        })
        .environment(\.subagentNamed, EnvironmentAction { id in feed.conversation.subagents.first { $0.id == id } })
        .environment(\.previewImage, EnvironmentAction { previewing = $0 })
        .modifier(SavesPhotos(saver: photoSaver))
        .environment(\.reachedCatchUp, EnvironmentAction { catchUpPinned = false })
        .environment(\.opensInPlace, EnvironmentAction { followsLatest = false })
        .environment(\.findTarget, findTarget)
        .environment(\.imageLoader, ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.cwd))
        .modifier(FileLinks(loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.cwd)) { [feed] name in
            feed.conversation.touchedFile(name)
        })
        .sheet(item: $previewing) {
            ImagePreview(source: $0, loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.cwd))
        }
        // Size changes are anchored below, only while following; a role-less anchor here would pin them too.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .onChange(of: feed.conversation.workingSubagents.count) { _, count in
            connection.workingSubagents[paneID] = count
        }
        .onChange(of: feed.conversation.items.count) { settlePending(turnEnded: false) }
        .onChange(of: agent?.agentStatus, statusChanged)
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
        .onChange(of: sentCount) { jumpToLatest() }
        // Only while following, and not mid-gesture: re-anchoring to the bottom as content streams
        // in would drag a flick back, and would push a line opened in place up off its finger.
        .defaultScrollAnchor(followsLatest && !userScrolling ? .bottom : nil, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay { placeholder }
        .connectingBadge(connection)
        .safeAreaInset(edge: .top) {
            if find != nil { findBar }
        }
        // An inset, not `safeAreaBar`: under a bar the transcript's text can't be selected (iOS 26).
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
                detail: settings.detailLevel, canRetry: canRetry, images: feed.conversation.imageCount > 0 || wholeImages != nil,
                changes: feed.conversation.editCount > 0, canStop: canStop,
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
        case .images: showsImages = true
        case .changes: showsChanges = true
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
            Button("Done") { find = nil; findFocused = false; detailOverride = nil; findTarget = nil }
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

    /// Scrolls to a match, first showing it: Folded when Digest hides it, and its run opened.
    private func reveal(_ id: String?) {
        guard let id else { return }
        let detail = detailOverride ?? settings.detailLevel
        if !feed.conversation.items(at: detail).contains(where: { $0.id == id }) { detailOverride = .folded }
        findTarget = id
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

    /// Lists every tool image in the file when earlier history isn't loaded; nil when the
    /// loaded ones are all there are (or the host can't be asked).
    private var wholeImages: (@MainActor () async throws -> [TranscriptImage])? {
        guard feed.hasEarlier, connection.isLive, let client = connection.client,
              let location, location.format != .codex else { return nil }
        return { try await client.transcriptToolImages(path: location.path, format: location.format) }
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
            TranscriptRows(feed: feed, detail: detail, arrival: arrival, nowPinned: pinnedNow != nil)
                .equatable()
            ForEach(unarrived) { message in
                if message.held {
                    QueuedBubble(text: message.text, canUnsend: message.id == pending.last(where: \.held)?.id && !unsending && !sending) {
                        Task { await unsend(message) }
                    }
                } else {
                    UserBubble(text: message.text, images: [])
                }
            }
            if let plan = openPlan {
                TodoCard(tool: plan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Full width even when empty: the scroll view sizes to it, and the placeholder and
        // reconnecting badge over it would otherwise get a sliver and wrap a letter per line.
        .frame(maxWidth: .infinity, alignment: .leading)
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
        } else if feed.state == .loading, !feed.isOfflineCopy, connection.snapshot != nil, !connection.isConnecting, pending.isEmpty {
            ProgressView()
        } else if feed.state == .live, feed.conversation.items.isEmpty, pending.isEmpty, !sending, sentCount == 0 {
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
            } else if locatedRef == agent?.agentSession, blocked || planReview, let prompt = screenPrompt {
                PermissionCard(prompt: prompt, choosing: choosing, paneID: paneID, terminalAddress: connection.address(paneID: paneID)) { label in
                    Task { await choose(label, on: prompt) }
                }
                .cardBackground()
            } else if blocked {
                NeedsYouBanner(paneID: paneID, terminalAddress: connection.address(paneID: paneID)).cardBackground()
            } else if let now = pinnedNow {
                PinnedLine(label: Text(now.label), live: true, action: now.opens ? { showsNow = true } : nil)
            } else if catchUpPinned, let arrival, let catchUp = feed.conversation.catchUp(after: arrival.item) {
                PinnedLine(label: CatchUpLine.summary(catchUp, since: arrival.seen)) {
                    catchUpPinned = false
                    followsLatest = false
                    position.scrollTo(id: CatchUpLine.id, anchor: .top)
                }
            }
            MessageComposer(draft: $draft, attachments: $attachments, sending: sending || shareImportTaskID != nil, focus: $composerFocused,
                            actions: composerActions, dismissals: keyboardDismissals) { Task { await sendDraft() } }
                .disabled(!connection.isLive || agent == nil || feed.isOfflineCopy)
        }
        // An ask or permission card replaces typing: put the keyboard away so the card has the room.
        .onChange(of: pendingAsk != nil || (locatedRef == agent?.agentSession && (blocked || planReview) && screenPrompt != nil)) { _, prompting in
            if prompting { keyboardDismissals += 1 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // An inset gets no scroll edge effect, so the bar brings its own: the transcript fades out
        // just above it instead of running under the Now line.
        .background {
            Rectangle().fill(.background)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                        Color.black
                    }
                }
                .padding(.top, -16)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    /// The Now line, when asks, prompts and Needs You leave the slot over the composer free.
    /// While it shows, the transcript leaves what's running to it.
    private var pinnedNow: (label: String, opens: Bool)? {
        guard pendingAsk == nil, !blocked, !(planReview && screenPrompt != nil) else { return nil }
        return nowLine
    }

    /// What's running, in one line: the newest call, then working subagents and background
    /// commands. Shown while the agent works or its subagents do; nothing when offline.
    private var nowLine: (label: String, opens: Bool)? {
        guard connection.isLive, !feed.isOfflineCopy, feed.state == .live, locatedRef == agent?.agentSession else { return nil }
        let conversation = feed.conversation
        let subagents = conversation.workingSubagents
        guard agent?.agentStatus == .working || !subagents.isEmpty else { return nil }
        let tools = conversation.runningTools
        let background = conversation.backgroundCommands
        var parts = [StepRun(tools.map { .tool($0) }, waitingOn: conversation.waitingOn).running].compactMap { $0 }
        // A wait's line already names what it waits on.
        if tools.last?.name != "wait" {
            if subagents.count == 1 { parts.append("\(subagents[0].name) working") }
            if subagents.count > 1 { parts.append("\(subagents.count) subagents working") }
            if !background.isEmpty { parts.append("\(background.count) in background") }
        }
        return (parts.isEmpty ? "Working…" : parts.joined(separator: " · "), !(tools.isEmpty && subagents.isEmpty && background.isEmpty))
    }

    /// Everything the Now line counts: subagents open their threads.
    private var nowSheet: some View {
        let conversation = feed.conversation
        return NavigationStack {
            List {
                if !conversation.workingSubagents.isEmpty {
                    Section("Subagents") {
                        ForEach(conversation.workingSubagents) { activity in
                            Button {
                                showsNow = false
                                if let route = subagentRoute(activity) { openSubagent(route) }
                            } label: {
                                LabeledContent([activity.name, activity.agentType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
                                    if let date = activity.spawnedAt { Text(date, style: .relative).monospacedDigit() }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                // A wait is listed by what it waits on.
                let running = conversation.runningTools.filter { $0.name != "wait" }
                if !running.isEmpty {
                    Section("Running") {
                        ForEach(running, id: \.id) { tool in
                            Text(tool.kind == .command ? tool.summary : tool.runningTitle)
                                .font(tool.kind == .command ? .subheadline.monospaced() : .body)
                        }
                    }
                }
                if !conversation.backgroundCommands.isEmpty {
                    Section("In Background") {
                        ForEach(Array(conversation.backgroundCommands.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.subheadline.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsNow = false } } }
        }
        .presentationDetents([.medium, .large])
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
        let shown = show(text, usersBefore: usersBefore, held: queues)
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: true, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            attachments = []
            sentCount += 1
            finishImport(packageID)
        } catch {
            pending.removeAll { $0.id == shown }
            draft = restoringDraft(text, before: draft)
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
        }
    }

    /// The message in the transcript from the tap on, not once the agent has written it down:
    /// that can take seconds, and a new thread has no transcript at all until then.
    private func show(_ text: String, usersBefore: Int, held: Bool) -> PendingSend.ID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let message = PendingSend(text: text, usersBefore: usersBefore, held: held)
        pending.append(message)
        jumpToLatest()
        return message.id
    }

    private func jumpToLatest() {
        followsLatest = true
        catchUpPinned = false
        position.scrollTo(edge: .bottom)
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
        let shown = show(text, usersBefore: usersBefore, held: true)
        do {
            guard OmpEditor.draft(inScreen: try await client.readPane(paneID, session: session).text) == nil else {
                pending.removeAll { $0.id == shown }
                draft = restoringDraft(text, before: draft)
                sendError = "omp has unsent text in its editor. Clear it in the terminal first."
                return
            }
            try await connection.sendText(text, pane: paneID, submit: false)
            try await connection.sendKeys(["ctrl+q"], pane: paneID)
            sentCount += 1
            finishImport(packageID)
        } catch {
            pending.removeAll { $0.id == shown }
            draft = restoringDraft(text, before: draft)
            sendError = "The message wasn't queued. Your draft is still here. \(error.localizedDescription)"
        }
    }

    private var userTexts: [String] {
        feed.conversation.items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } }
    }

    /// Filtered as the transcript updates, so the real bubble never shows beside its stand-in.
    private var unarrived: [PendingSend] {
        guard !pending.isEmpty else { return [] }
        let users = userTexts
        return pending.filter { !$0.arrived(in: users) }
    }

    /// A sent message leaves once the transcript has it. A held one also leaves when the agent
    /// is idle (omp sent what it held, or someone at the desk took it back); any other, when a
    /// turn ends without the transcript matching it, except the one still being delivered.
    private func settlePending(turnEnded: Bool) {
        guard !pending.isEmpty else { return }
        let idle = agent?.agentStatus == .idle || agent?.agentStatus == .done
        let delivering = sending ? pending.last?.id : nil
        let users = userTexts
        pending.removeAll { message in
            message.arrived(in: users) || (message.held && idle) || (turnEnded && message.id != delivering)
        }
    }

    private func statusChanged(_ old: AgentStatus?, _ new: AgentStatus?) {
        settlePending(turnEnded: old == .working && (new == .idle || new == .done))
    }

    /// omp's Alt+Up puts its last queued message back in its editor; that text moves to the
    /// composer here and omp's editor is cleared. If the agent took the message first, the
    /// editor stays empty and the transcript shows it as sent.
    private func unsend(_ message: PendingSend) async {
        guard message.id == pending.last(where: \.held)?.id, !unsending, let client = connection.client,
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
            pending.removeAll { $0.id == message.id }
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
            // A new thread gets its session (or a new one) with the first message, which stays
            // shown; counts against another thread's messages would be wrong, so those go.
            if !userTexts.isEmpty { pending = [] }
            locatedRef = ref
            location = nil
            locateFailure = nil
            feed = ConversationFeed()
            screenPrompt = nil
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
    enum Action { case detail(DetailLevel), find, images, changes, retry, stop, liveActivity, sessionDetails, explain }

    let detail: DetailLevel
    let canRetry: Bool
    /// The agent's tools returned images, or earlier history might hold some.
    let images: Bool
    /// The loaded transcript records a successful edit or file write.
    let changes: Bool
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
        lhs.detail == rhs.detail && lhs.canRetry == rhs.canRetry && lhs.images == rhs.images && lhs.changes == rhs.changes && lhs.canStop == rhs.canStop
            && lhs.liveActivity == rhs.liveActivity && lhs.session == rhs.session
            && lhs.sessionHasDetails == rhs.sessionHasDetails && lhs.mute == rhs.mute
            && lhs.status == rhs.status
    }

    var body: some View {
        Menu {
            DetailLevelOptions(selection: Binding(get: { detail }, set: { act(.detail($0)) }))
            Button("Find in Conversation") { act(.find) }
            if images { Button("Images") { act(.images) } }
            if changes { Button("Changes") { act(.changes) } }
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
    let arrival: ReadCursors.Mark?
    let nowPinned: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feed === rhs.feed && lhs.detail == rhs.detail && lhs.arrival == rhs.arrival && lhs.nowPinned == rhs.nowPinned
    }

    var body: some View {
        let conversation = feed.conversation
        let items = conversation.items(at: detail)
        ForEach(ConversationRow.rows(items,
                                     waitingOn: conversation.waitingOn,
                                     answered: items.answeredBriefs(),
                                     since: since(items),
                                     nowPinned: nowPinned,
                                     subagents: { conversation.subagents(spawnedBy: $0) })) { row in
            row.view.id(row.id)
        }
    }

    /// The catch-up line goes before the first shown item after the one last seen.
    private func since(_ shown: [ConversationItem]) -> ConversationRow.Since? {
        guard let arrival, let catchUp = feed.conversation.catchUp(after: arrival.item) else { return nil }
        let all = feed.conversation.items
        guard let seen = all.lastIndex(where: { $0.id == arrival.item }) else { return nil }
        let ids = Set(shown.map(\.id))
        guard let first = all[(seen + 1)...].first(where: { ids.contains($0.id) }) else { return nil }
        return .init(before: first.id, catchUp: catchUp, seen: arrival.seen)
    }
}

/// Transcript items as the chat shows them: runs of tool calls, thinking and briefs sent to
/// other agents fold into one "steps" row so the words stay readable.
enum ConversationRow: Identifiable {
    /// Where the reader left off, and what came after.
    struct Since {
        let before: String
        let catchUp: CatchUp
        let seen: Date
    }

    case item(ConversationItem)
    /// Another agent's reply or result, with the lone brief this agent sent it before.
    case answer(ConversationItem, brief: String)
    case steps([ConversationItem], StepRun)
    /// The step that spawned subagents, shown as their status instead of a tool row.
    case subagents(callID: String, [SubagentActivity])
    case since(Since)

    var id: String {
        switch self {
        case .item(let item), .answer(let item, _): item.id
        case .steps(let items, _): "steps-" + (items.first?.id ?? "")
        case .subagents(let callID, _): "subagents-" + callID
        case .since: CatchUpLine.id
        }
    }

    /// `answered`: briefs by the id of the reply that answers them (`answeredBriefs()`); those
    /// leave their run and open under the reply instead.
    static func rows(_ items: [ConversationItem],
                     waitingOn: [String] = [],
                     answered: [String: ConversationItem] = [:],
                     since: Since? = nil,
                     nowPinned: Bool = false,
                     subagents: (String) -> [SubagentActivity] = { _ in [] }) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var run: [ConversationItem] = []
        let paired = Set(answered.values.map(\.id))
        func flush() {
            guard !run.isEmpty else { return }
            var step = StepRun(run, waitingOn: waitingOn)
            // The pinned Now line says what's running: a run with nothing settled waits to show.
            if nowPinned, step.running != nil {
                step = step.settled()
                if step.label.isEmpty, step.failure == nil { run = []; return }
            }
            rows.append(.steps(run, step))
            run = []
        }
        for item in items {
            if let since, item.id == since.before {
                flush()
                rows.append(.since(since))
            }
            switch item {
            case .tool(let tool):
                let children = subagents(tool.id)
                if children.isEmpty {
                    run.append(item)
                } else {
                    flush()
                    rows.append(.subagents(callID: tool.id, children))
                }
            case .peerMessage(let id, _, _, true) where paired.contains(id):
                continue
            // A brief to another agent is part of the work; what comes back stands alone.
            case .thinking, .raw, .peerMessage(_, _, _, true):
                run.append(item)
            default:
                flush()
                if case .peerMessage(_, _, let brief, true)? = answered[item.id] {
                    rows.append(.answer(item, brief: brief))
                } else {
                    rows.append(.item(item))
                }
            }
        }
        flush()
        return rows
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .item(.user(_, let text, let images)): UserBubble(text: text, images: images)
        case .item(.assistant(_, let text)): MarkdownText(text: text)
        case .item(.ask(let ask)): if ask.answer != nil { AnsweredAsk(ask: ask) }
        case .item(.notice(_, let text, let kind)): NoticeRow(text: text, failed: kind == .error)
        case .item(.peerMessage(_, let peer, let text, _)): AgentMessage(title: "From \(peer)", peer: peer, text: text)
        case .answer(.peerMessage(_, let peer, let text, _), let brief): AgentMessage(title: "From \(peer)", peer: peer, text: text, brief: brief)
        case .steps(let items, let run): StepsRow(items: items, run: run)
        case .subagents(_, let activities): SubagentGroupRow(activities: activities)
        case .item(.subagentResult(_, let activity)): SubagentResultRow(activity: activity)
        case .answer(.subagentResult(_, let activity), let brief): SubagentResultRow(activity: activity, brief: brief)
        case .since(let since): CatchUpLine(catchUp: since.catchUp, seen: since.seen)
        case .item, .answer: EmptyView()
        }
    }
}

struct PendingSend: Identifiable {
    let id = UUID()
    let text: String
    /// User messages in the transcript when this was sent; only later ones can be it.
    let usersBefore: Int
    /// omp holds it until the agent next takes input.
    let held: Bool

    /// A later user message holds its text, whitespace aside (attachments add paths around it).
    func arrived(in users: [String]) -> Bool {
        let key = text.filter { !$0.isWhitespace }
        return users.dropFirst(usersBefore).contains { $0.filter { !$0.isWhitespace }.contains(key) }
    }
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

/// Another agent's words: what it sent this one, a brief this one sent it, or its result.
/// A quiet header over two lines of the text; opening it shows the rest and, for one of this
/// agent's subagents, a link to its thread.
struct AgentMessage: View {
    let title: String
    let peer: String
    var failed = false
    let text: String
    /// What this agent asked it first (a lone brief the reply answers), shown when opened.
    var brief: String? = nil
    /// Shown until opened when the text starts with something better skipped (a brief's headings).
    var gist: String? = nil
    /// The subagent itself when the caller has it; else it's looked up by `peer`.
    var activity: SubagentActivity? = nil
    @State private var expanded = false
    @State private var truncated = false
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.subagentNamed) private var subagentNamed

    var body: some View {
        let thread: (() -> Void)? = openSubagent.flatMap { open in (activity ?? subagentNamed?(peer)).map { found in { open(found) } } }
        let shown = expanded ? text : gist ?? text
        let opens = expanded || truncated || shown != text || thread != nil || brief != nil
        VStack(alignment: .leading, spacing: 2) {
            QuietHeader(isExpanded: expanded, action: opens ? { expanded.toggle() } : nil) {
                failed ? Text(title).foregroundStyle(.red) : Text(title)
            }
            if !shown.isEmpty {
                Text(MarkdownText.inline(shown))
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .background {
                        // The whole text fits the clamped frame only when nothing was cut.
                        if !expanded {
                            ViewThatFits(in: .vertical) {
                                Text(MarkdownText.inline(shown)).font(.subheadline).fixedSize(horizontal: false, vertical: true).hidden()
                                    .onAppear { truncated = false }
                                Color.clear.onAppear { truncated = true }
                            }
                        }
                    }
            }
            if expanded, let brief {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Asked").font(.subheadline).foregroundStyle(.secondary)
                    ClampedText(text: brief, font: .subheadline, lines: 6, style: .secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            }
            if expanded, let thread {
                Button("Open Thread", action: thread)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
            }
        }
        // The header's line has room above its text; the same below the body.
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A brief's lines under its "Change" heading when it has one (task briefs do), else its
    /// first lines that aren't headings.
    static func gist(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = lines.firstIndex { $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains("change") }
            .map { lines[($0 + 1)...] } ?? lines[...]
        return body.filter { !$0.hasPrefix("#") }.prefix(2).joined(separator: " ")
    }
}

/// The one line every step, run, message and status between the agents' words starts with:
/// quiet text and a trailing chevron. With `isExpanded` it opens the line in place and turns
/// down; without, it goes somewhere else. No action, no chevron. What it opens snaps in, as a
/// Settings disclosure does; only the chevron turns, so nothing slides past its neighbours.
struct QuietHeader<Label: View>: View {
    var isExpanded: Bool? = nil
    /// Run labels get two lines; everything else one.
    var lines = 1
    /// How many lines opening it shows, beside the chevron, when the label doesn't say.
    var count: Int? = nil
    let action: (() -> Void)?
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.opensInPlace) private var opensInPlace

    var body: some View {
        let line = HStack(spacing: 0) {
            label.font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
            Spacer(minLength: 4)
            if let count {
                Text(count, format: .number).font(.footnote).monospacedDigit().foregroundStyle(.tertiary)
                    .accessibilityLabel("\(count) steps")
            }
            if action != nil {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
                    .frame(width: 32, height: 28)
            }
        }
        .frame(minHeight: 28)
        .contentShape(.rect)
        if let action {
            Button {
                if isExpanded != nil { opensInPlace?(()) }
                action()
            } label: { line }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
        } else {
            line
        }
    }
}

/// `DisclosureGroup` with a `QuietHeader`: the stock chevron is heavy and primary-coloured.
struct QuietDisclosure: DisclosureGroupStyle {
    var lines = 1
    var count: Int? = nil

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietHeader(isExpanded: configuration.isExpanded, lines: lines, count: count, action: {
                configuration.isExpanded.toggle()
            }) { configuration.label }
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let failed: Bool

    var body: some View {
        ClampedText(text: text, font: .subheadline, lines: 2)
            .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A question the agent asked and what was answered, in the steps' quiet voice.
private struct AnsweredAsk: View {
    let ask: AskActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ask.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.question).foregroundStyle(.secondary)
                    if let answer = ask.answer, !answer.cancelled { Text(reply(to: question, in: answer)) }
                }
            }
            if ask.answer?.cancelled == true { Text("Dismissed").foregroundStyle(.secondary) }
        }
        .font(.subheadline)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// This question's own answer; older records only carry the combined list.
    private func reply(to question: AskQuestion, in answer: AskAnswer) -> String {
        let values = answer.perQuestion[question.question] ?? answer.selected + [answer.custom].compactMap { $0 }
        let note = answer.perQuestionNotes[question.question] ?? (answer.perQuestion.isEmpty ? answer.note : nil)
        return (values.joined(separator: ", ") + (note.map { " — Note: \($0)" } ?? ""))
    }
}

/// Tool calls, thinking and briefs between two messages, folded to one line until opened.
/// The line leads with a failure, then says what's running, or else what the run did.
private struct StepsRow: View {
    let items: [ConversationItem]
    let run: StepRun
    @State private var expanded = false
    @Environment(\.findTarget) private var findTarget

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                // Opening the run is the ask: an edit's diff, or a lone call's detail, shows at once.
                ForEach(items) { item in StepLine(item: item, opens: items.count == 1).id(item.id) }
            }
            .padding(.bottom, 6)
        } label: {
            label
        }
        .disclosureGroupStyle(QuietDisclosure(lines: 2, count: run.showsSteps ? run.steps : nil))
        // Find opens the run holding its match (a brief sent from inside it).
        .onChange(of: findTarget, initial: true) { _, target in
            if let target, items.contains(where: { $0.id == target }) { expanded = true }
        }
    }

    private var label: Text {
        let rest = run.running.map { "\($0)…" } ?? run.label
        guard let failure = run.failure else { return Text(rest) }
        let failed = Text(failure).foregroundStyle(.red)
        return rest.isEmpty ? failed : Text("\(failed) · \(rest)")
    }
}

private struct StepLine: View {
    let item: ConversationItem
    let opens: Bool

    var body: some View {
        switch item {
        case .tool(let tool):
            ToolStepView(tool: tool, expanded: opens || tool.kind == .edit)
        case .thinking(_, let text):
            ClampedText(text: text, font: .subheadline, lines: 2, style: .secondary)
        case .raw(_, let type, let text):
            Text("\(type): \(text)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
        case .peerMessage(_, let peer, let text, _):
            AgentMessage(title: "To \(peer)", peer: peer, text: text, gist: AgentMessage.gist(text))
        default: EmptyView()
        }
    }
}

/// The one line pinned over the composer: what's running now, or what came since the last look.
/// Bare, like the run lines it stands in for (same column, same chevron); a slow pulsing dot
/// marks the Now line and holds still under Reduce Motion.
private struct PinnedLine: View {
    let label: Text
    var live = false
    let action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if live {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .speed(0.5), isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            QuietHeader(action: action) { label }
        }
        .padding(.horizontal, 4)
    }
}

extension EnvironmentValues {
    /// The reader scrolled the catch-up line into view, so its pinned copy can go.
    @Entry var reachedCatchUp: EnvironmentAction<Void, Void>? = nil
    /// The item Find went to, so the run holding it opens.
    @Entry var findTarget: String? = nil
    /// A line opens or closes in place: the transcript stops following its end, so the line
    /// stays put and what it opens grows below it instead of pushing it up.
    @Entry var opensInPlace: EnvironmentAction<Void, Void>? = nil
}

/// Where the reader left off: "Since 9:41 · 3 edits · 2 replies · 1 failure" over a hairline,
/// before the first item they haven't seen.
struct CatchUpLine: View {
    nonisolated static let id = "since-last-look"
    let catchUp: CatchUp
    let seen: Date
    @Environment(\.reachedCatchUp) private var reached

    var body: some View {
        HStack(spacing: 10) {
            Self.summary(catchUp, since: seen).font(.subheadline).foregroundStyle(.secondary).layoutPriority(1)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .frame(minHeight: 28)
        .onScrollVisibilityChange { visible in if visible { reached?(()) } }
    }

    static func summary(_ catchUp: CatchUp, since seen: Date) -> Text {
        let time = Calendar.current.isDateInToday(seen)
            ? seen.formatted(date: .omitted, time: .shortened)
            : seen.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let counts = [(catchUp.edits, "edit", "edits"), (catchUp.replies, "reply", "replies"), (catchUp.images, "image", "images")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        let lead = Text((["Since \(time)"] + (counts.isEmpty && catchUp.failures == 0 ? ["New messages"] : counts)).joined(separator: " · "))
        guard catchUp.failures > 0 else { return lead }
        let failures = Text(catchUp.failures == 1 ? "1 error" : "\(catchUp.failures) errors").foregroundStyle(.red)
        return Text("\(lead) · \(failures)")
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
    @Environment(\.opensInPlace) private var opensInPlace

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
                    opensInPlace?(())
                    expanded.toggle()
                }
                .font(.subheadline)
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
