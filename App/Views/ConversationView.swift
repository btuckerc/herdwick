import HerdrAPI
import SwiftUI

/// An agent as a conversation: its own transcript as chat, its questions as tappable
/// answers, and a composer. The terminal is one tap away for everything else.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(DecisionLog.self) private var decisionLog
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    let connection: HostConnection
    let paneID: String
    /// Pushes the terminal; alerts can't hold navigation links.
    let openTerminal: () -> Void

    private var entry: ConversationState {
        connection.conversations.entry(host: connection.identity, pane: paneID, agent: agent,
                                       ref: agent?.agentSession ?? endedAgent?.reference)
    }
    private var feed: ConversationFeed { entry.feed }
    private var locatedRef: AgentSessionRef? { agent?.agentSession ?? endedAgent?.reference }
    private var location: TranscriptLocation? {
        get {
            if let location = entry.location { return location }
            if let known = connection.activity[paneID], known.ref == locatedRef, let transcript = known.transcript {
                return TranscriptLocation(path: transcript.path, format: transcript.format)
            }
            if let path = locatedRef?.transcriptPath, let ref = locatedRef, let format = TranscriptFormat(agent: ref.agent) {
                return TranscriptLocation(path: path, format: format)
            }
            if let ended = endedAgent, let path = ended.transcriptPath, let format = TranscriptFormat(agent: ended.harness) {
                return TranscriptLocation(path: path, format: format)
            }
            return nil
        }
        nonmutating set { entry.location = newValue }
    }
    private var decisionKey: String {
        DecisionLog.key(address: connection.address(paneID: paneID), transcriptPath: location?.path)
    }
    @State private var locateFailure: String?
    @State private var draft = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var sending = false
    @State private var sendError: String?
    @State private var answering = false
    @State private var askFailure: String?
    /// The ask and replies behind `askFailure`, for Try Again: the driver picks up from
    /// whichever question or review page the prompt is on now.
    @State private var askRetry: (ask: AskActivity, replies: [QuestionReply])?
    /// The permission or approval prompt on the agent's screen while it is blocked.
    @State private var screenPrompt: ScreenPrompt?
    @State private var choosing: String?
    /// Sent messages the transcript doesn't have yet, shown from the tap on. omp holds some
    /// (steering, follow-ups) until the agent next takes input; the last of those can be unsent.
    private var pending: [PendingSend] {
        get { entry.pending }
        nonmutating set { entry.pending = newValue }
    }
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
    /// A message went through and the agent hasn't answered or started on it yet.
    @State private var handedOff = false
    @FocusState private var composerFocused: Bool
    /// What a card's choice sent, shown briefly where the card was.
    @State private var confirmation: String?
    @State private var keyboardDismissals = 0
    /// The software keyboard is up (its notices, taken on the bottom bar).
    @State private var keyboardUp = false
    /// The newest content is on screen; only then does a finished agent count as read.
    @State private var atLatest = true
    /// The reader's messages' frames and the viewport, kept for opening on a turn whole; a plain
    /// box, so layout changes don't redraw the thread.
    @State private var openGeometry = OpenGeometry()
    /// Room below the transcript's end, so a thread opened at its end doesn't rest on the
    /// reader's message sliced under the bar; gone once anything changes.
    @State private var restInset: CGFloat = 0
    /// Start & Send's first message: queued until the agent is ready, or not sent after all.
    @State private var firstSend: FirstSend?
    enum FirstSend { case waiting, notSent }
    /// The result a reply is being written to, brought under the bar once the keyboard is up.
    @State private var replyAnchor: String?
    /// Keep the newest content in view through every layout change (a reply arriving, the
    /// composer shrinking after a send, the keyboard). The reader's own scrolling sets it;
    /// sending turns it back on.
    @State private var followsLatest = true
    @State private var position = ScrollPosition(edge: .bottom)
    /// Opening on a finished turn: whether the transcript was put at its start yet, and whether
    /// that is still the place held (until the reader scrolls or it fits above the composer).
    @State private var resultAnchor: ResultAnchor = .pending
    enum ResultAnchor { case pending, held, done }
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
    @State private var nextNeedsYouActive = false
    /// This window's claim on the shared feed's follow; another window showing it waits.
    @State private var followerID = UUID()
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
    private var blocked: Bool { agent.map { connection.presentedStatus($0) == .blocked } ?? false }
    /// omp waits on its Plan Review screen while herdr reports it idle, so the transcript says when.
    private var planReview: Bool {
        locatedRef == agent?.agentSession && agent?.agent == "omp" && agent?.agentStatus != .working && feed.conversation.pendingPlanReview != nil
    }
    /// A command the agent ran with `pty: true` waiting at a prompt; see `HostConnection.Wait`.
    private var terminalWait: HostConnection.Wait? {
        guard locatedRef == agent?.agentSession, !feed.isOfflineCopy, let agent,
              let wait = connection.wait(agent), wait.console != nil else { return nil }
        return wait
    }
    /// The console as last read here for `terminalWait`, fresher than the link's; nil screen
    /// once it left the agent's screen.
    @State private var liveConsole: (id: String, screen: ConsoleScreen?)?
    @State private var replying = false
    /// When this thread was opened: a Done card only signs in for a turn that ends while it's
    /// open, not for one already there (round 15: opening a just-finished thread replayed it).
    @State private var openedAt = Date.now
    /// The screen's width, for how much of the bar the title may take.
    @State private var barWidth: CGFloat = 0
    /// For dictation: the folder, the agent and the files it lately read or edited.
    private var dictationVocabulary: [String] {
        let roots = [agent?.workingDirectory, agent?.agent].compactMap { $0 }
        let files = feed.conversation.items.reversed().lazy.compactMap { item -> String? in
            guard case .tool(let tool) = item, tool.kind == .edit || tool.kind == .read else { return nil }
            return tool.summary
        }
        return DictationController.vocabulary(from: roots + files.prefix(100))
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
                if let retry = askRetry, pendingAsk?.toolCallId == retry.ask.toolCallId {
                    Button("Try Again") { Task { await answer(retry.ask, with: retry.replies) } }
                }
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
                          loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.workingDirectory))
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
    /// read ten minutes before launch: inside the loop scene's 18-minute turn and before the
    /// clock (round 14: a fixed 9:16 AM read as the future under an earlier status bar).
    private func arrive(_ id: String?) {
        catchUpPinned = true
        if let demo {
            let seen = Date.now.addingTimeInterval(-10 * 60)
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
        let key = FeedKey(liveID: connection.liveID, location: location, window: feed.window, feedID: ObjectIdentifier(feed))
        let state = entry
        return scroller
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { barWidth = $0 }
            .toolbar { toolbar }
            .alert("Stop this run?", isPresented: $confirmStop) {
                Button("Stop", role: .destructive) { Task { await press(["esc"], failure: "The agent couldn't be stopped.") } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sends Esc to the agent, as at the desk. Messages it was holding go back to its editor.")
            }
            .task(id: LocateKey(liveID: connection.liveID, ref: agent?.agentSession)) {
                await locateTranscript()
            }
            .task(id: key) {
                let feed = state.feed
                let viewerID = UUID()
                connection.conversations.activate(state, viewer: viewerID)
                defer { connection.conversations.deactivate(state, viewer: viewerID) }
                // Capture the key's location; a locate task cannot start a second channel here.
                let location = key.location
                if let location { await feed.restore(location, host: connection.identity) }
                // A channel can end while the transport lives on (a brief background, a killed
                // `tail`): follow again. A dead transport bumps `liveID`, which restarts this task.
                while !Task.isCancelled, connection.isLive, let client = connection.client, let location {
                    // Another window already follows this conversation: its feed is this one too.
                    if !(feed.isFollowing && feed.follower != followerID) {
                        await feed.follow(location, client: client, host: connection.identity, follower: followerID)
                    }
                    guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                }
            }
            .task(id: PromptKey(liveID: connection.liveID, watching: (blocked || planReview) && pendingAsk == nil, ref: agent?.agentSession)) {
                await watchScreenPrompt()
            }
            .task(id: terminalWait.map { "\($0.id)|\(connection.liveID)" }) { await watchConsole() }
            .onChange(of: ReadKey(sequence: agent?.stateChangeSeq, wait: agent.flatMap { connection.wait($0)?.id }, visible: showsLatest), initial: true) {
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
            .onChange(of: feed.isCaughtUp) { _, caughtUp in if caughtUp { entry.settlePending() } }
            .onChange(of: settings.offlineTranscripts) { _, on in if !on { feed.discardOfflineCopy() } }
            .onChange(of: scene.draftRevision) { if let draftID { draft = DraftStore.load(draftID) ?? draft } }
            .task(id: scene.firstMessage?.address == connection.address(paneID: paneID)) { await takeFirstMessage() }
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
        locatedRef == agent?.agentSession && scenePhase == .active && feed.isCaughtUp && !feed.isOfflineCopy && locateFailure == nil && atLatest
    }

    private var scroller: some View {
        ScrollView { transcript }
        .background(Tokens.Surface.base)
        .edgeFade(.top)
        // The fade's depth (`edgeFade`), so a row scrolled to the top (or the thread's first)
        // rests whole beneath it rather than inside it.
        .contentMargins(.top, Tokens.Space.l, for: .scrollContent)
        .scrollPosition($position)
        .environment(\.openSubagent, EnvironmentAction { activity in
            if let route = subagentRoute(activity) { openSubagent(route) }
        })
        .environment(\.subagentNamed, EnvironmentAction { id in feed.conversation.subagents.first { $0.id == id } })
        .environment(\.previewImage, EnvironmentAction { previewing = $0 })
        .modifier(SavesPhotos(saver: photoSaver))
        .environment(\.reachedCatchUp, EnvironmentAction { catchUpPinned = false })
        .environment(\.opensInPlace, EnvironmentAction { followsLatest = false })
        .environment(\.userRowFrame, EnvironmentAction { [openGeometry] in openGeometry.userFrames[$0.id] = $0.frame })
        .environment(\.findTarget, findTarget)
        .environment(\.imageLoader, ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.workingDirectory))
        .modifier(FileLinks(loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.workingDirectory)) { [feed] name in
            feed.conversation.touchedFile(name)
        })
        .sheet(item: $previewing) {
            ImagePreview(source: $0, loader: ImageLoader(connection: connection, transcript: location?.path, cwd: agent?.workingDirectory))
        }
        // Size changes are anchored below, only while following; a role-less anchor here would pin them too.
        // A short thread reads from the top, under the title, rather than floating above the composer;
        // one with a decision card hugs it instead, so the question follows its context with no
        // empty band between (round 19: graders saw a gap above the ask card).
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(answerCardShown ? .bottom : .top, for: .alignment)
        .onChange(of: feed.conversation.workingSubagents.count) { _, count in
            connection.workingSubagents[paneID] = count
        }
        .onChange(of: feed.conversation.items.count) {
            entry.settlePending()
            model.watchedRun.updateDetail(watchedRunDetail, from: connection.address(paneID: paneID))
            restInset = 0
        }
        .onScrollGeometryChange(for: TailGeometry.self) { geometry in
            TailGeometry(geometry)
        } action: { old, new in
            atLatest = new.nearBottom
            openGeometry.layout = new.layout
            // The anchor below handles content growth but not the viewport shrinking under
            // the keyboard or composer, nor a message landing after the send returned.
            if followsLatest, !userScrolling, new.layout != old.layout { position.scrollTo(edge: .bottom) }
            if let id = replyAnchor, new.layout.insets.bottom > old.layout.insets.bottom {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                    position.scrollTo(id: id, anchor: .top)
                    replyAnchor = nil
                }
            }
        }
        .onScrollPhaseChange { old, new, context in
            userScrolling = [.tracking, .interacting, .decelerating].contains(new)
            if userScrolling, resultAnchor == .held { resultAnchor = .done }
            // Only the reader's own scrolling decides; programmatic scrolls don't track or decelerate.
            guard new == .idle, [.tracking, .interacting, .decelerating].contains(old) else { return }
            followsLatest = TailGeometry(context.geometry).nearBottom
            if followsLatest { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: sentCount) {
            restInset = 0
            jumpToLatest()
        }
        // The agent took it: it started, asked, or wrote something back.
        .onChange(of: agent.map { connection.presentedStatus($0) }) { _, status in
            if status == .working || status == .blocked { handedOff = false }
        }
        .onChange(of: feed.conversation.items.last?.id) {
            if case .user? = feed.conversation.items.last {} else { handedOff = false }
        }
        .onChange(of: feed.isCaughtUp, initial: true) { _, caughtUp in if caughtUp { openAtTurn() } }
        // Only while following, and not mid-gesture: re-anchoring to the bottom as content streams
        // in would drag a flick back, and would push a line opened in place up off its finger.
        .defaultScrollAnchor(followsLatest && !userScrolling ? .bottom : nil, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay { placeholder }
        .connectingBadge(connection, lastKnown: agent.map { connection.presentedStatus($0).label })
        .safeAreaInset(edge: .top) {
            if find != nil { findBar }
        }
        // An inset, not `safeAreaBar`: under a bar the transcript's text can't be selected (iOS 26).
        // The software keyboard is up: the composer's focus can't say so (a `FocusState` with no
        // `.focused` view reads false while UIKit edits), the keyboard's own notices can.
        .safeAreaInset(edge: .bottom) {
            bottomBar
                // Taken once the keyboard has settled, so the Next capsule rides up and down with
                // the field and only then turns quiet: swapped as it began, the new line was set at
                // the field's final place while the field still rose, and floated over the
                // transcript (round 93: opus#3).
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in keyboardUp = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardUp = false }
                // ⇧⌘U and ⌃⌘A, the inbox's triage keys, on the thread on screen (round 62: sb#2).
                .onChange(of: scene.markUnreadRequest) {
                    if onScreen, let agent, connection.presentedStatus(agent) == .idle, !connection.isUnread(agent) { menuAction(.markUnread) }
                }
                .onChange(of: scene.hideRequest) { if onScreen { menuAction(.hide) } }
        }
        // The badge stays while Next is down the transcript rather than beside it.
        .agentDock(current: connection.address(paneID: paneID), busy: sending, quiet: nextNeedsYou != nil && !nextInTranscript)
        .focusedSceneValue(\.herdwickSending, sending)
        // ⌘F finds in the conversation on screen (round 12: it opened the inbox's search).
        .onChange(of: scene.findRequest) { if onScreen { menuAction(.find) } }
        .onChange(of: scene.messageRequest) { if onScreen { composerFocused = true } }
        // A name given in herdr wins over the transcript's own title. The bar shows it through
        // `BarTitle`; this one names the screen in Back's history menu.
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }

    /// Whether this thread is the one on screen, for the menu bar's requests.
    private var onScreen: Bool { scene.navigationPath.last == .conversation(connection.address(paneID: paneID)) }

    /// A new agent's thread, before the agent or its terminal names it, goes by the first
    /// thing asked of it (round 20: Start & Send landed on "omp-e03b45"), the queued message's
    /// while it waits to go (round 48: opus#1, "omp-773dd5" until the agent had it).
    private var title: String {
        if let title = agent?.label ?? feed.title ?? feed.conversation.title { return title }
        guard let agent else { return paneID }
        let own = agent.conversationTitle
        let queued = firstSend == .waiting ? TranscriptActivity.previewLine(draft, limit: 48) : ""
        guard own == agent.name, let first = firstUserLine ?? (queued.isEmpty ? nil : queued) else { return own }
        return first
    }

    /// The transcript's first user message as one short line.
    private var firstUserLine: String? {
        for item in feed.conversation.items {
            guard case .user(_, let text, _) = item else { continue }
            let line = TranscriptActivity.previewLine(text, limit: 48)
            return line.isEmpty ? nil : line
        }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Back and its margin end at 72 pt; the Terminal and More pair, its margin and the gap
        // before it take 132, and 8 more keep a title at the cap from tipping it (round 20's
        BarTitle(title: title, subtitle: subtitle, room: barWidth - 212, since: subtitleSince, still: subtitleStill,
                 waiting: subtitleWaits, tint: subtitleTint)
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink(value: Route.terminal(connection.address(paneID: paneID))) {
                // Named enlarged on a long press at accessibility sizes, as the composer's
                // glyph buttons are (round 85: sb#8).
                Label("Terminal", systemImage: "apple.terminal").accessibilityShowsLargeContentViewer()
            }
            let address = connection.address(paneID: paneID)
            let watching = model.watchedRun.address == address
            let offersActivity = agent != nil && connection.isLive && !feed.isOfflineCopy
                && (watching || agent?.agentStatus == .working)
            let details = sessionDetails
            // The harness leads the session's name, e.g. "Claude · claude-sonnet-4".
            let sessionName = [agent?.agent.map(agentKindLabel), details?.title].compactMap { $0 }.joined(separator: " · ")
            ConversationMenu(
                detail: settings.detailLevel, canRetry: canRetry, images: feed.conversation.imageCount > 0 || wholeImages != nil,
                changes: feed.conversation.editCount > 0, canStop: canStop, canAnswerInTerminal: pendingAsk != nil,
                liveActivity: offersActivity ? (watching ? .hide : .show) : nil,
                session: sessionName.isEmpty ? nil : sessionName,
                sessionHasDetails: details?.body.isEmpty == false,
                mute: agent?.agentSession.map { .init(address: address, reference: $0.value) },
                // As the inbox row's swipes offer them (round 61: sb#1 r59, putting a reviewed
                // agent away meant going back to the inbox first).
                canMarkUnread: agent.map { connection.presentedStatus($0) == .idle && !connection.isUnread($0) } ?? false,
                canHide: agent != nil,
                status: agent.map { connection.presentedStatus($0).label },
                // At accessibility sizes Next is the transcript's last block; here it's one
                // reach from any scroll position (round 68: sb#2), with where it runs, as the
                // dock's action says it (round 69: sb#7).
                next: nextNeedsYou?.thread.agent.conversationTitle,
                nextPlace: nextNeedsYou.map { next in
                    [next.thread.connection === connection ? nil : next.thread.connection.profile.name,
                     next.thread.workspace?.displayLabel].compactMap { $0 }.joined(separator: " · ")
                },
                act: menuAction
            )
            .equatable()
        }
    }

    private func menuAction(_ action: ConversationMenu.Action) {
        switch action {
        case .answerInTerminal: openTerminal()
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
                    await model.watchedRun.start(connection: connection, agent: agent, since: workingSince,
                                                 detail: watchedRunDetail, push: model.push)
                    if let error = model.watchedRun.error { sendError = error }
                }
            }
        case .explain: Task { await explainStatus() }
        // Back to the inbox, where the agent's row shows the change; a Hide offers Undo there,
        // as one from the row does.
        case .markUnread:
            guard let agent else { return }
            connection.markUnread(agent)
            scene.back()
        case .hide:
            guard let agent else { return }
            connection.hide(agent)
            scene.hiddenFromThread = connection.address(paneID: paneID)
            scene.back()
        case .next:
            if let next = nextNeedsYou { openNext(next) }
        }
    }

    /// Esc interrupts a running turn in omp, Claude Code, Codex and agy alike.
    private var canStop: Bool {
        guard let agent, !feed.isOfflineCopy, connection.isLive, agent.agentStatus == .working else { return false }
        return ["omp", "claude", "codex", "agy"].contains(agent.agent)
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

    /// Lists every tool image in the file and its subagents' files when earlier history isn't
    /// loaded or there are subagents; nil when the loaded ones are all there are (or the host
    /// can't be asked).
    private var wholeImages: (@MainActor () async throws -> [TranscriptImage])? {
        let subagents = feed.conversation.subagents
        guard feed.hasEarlier || !subagents.isEmpty, connection.isLive, let client = connection.client,
              let location, location.format != .codex else { return nil }
        let names = Dictionary(subagents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return { try await client.transcriptToolImages(path: location.path, format: location.format, subagents: true, names: names) }
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
        return VStack(alignment: .leading, spacing: Tokens.Space.xl) {
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
            TranscriptRows(feed: feed, detail: detail, arrival: arrival, nowPinned: pinnedNow != nil,
                           decisions: decisionLog.entries(for: decisionKey), awaitingApproval: screenPrompt != nil,
                           tailWork: tailWorkLabel, reduceMotion: reduceMotion, openedAt: openedAt)
                .equatable()
            ForEach(unarrived) { message in
                pendingBubble(message)
            }
            if handedOff || (sending && pending.last?.held == false) {
                handoffLine
            }
            if let plan = openPlan {
                TodoCard(tool: plan)
            }
            if nextInTranscript, let next = nextNeedsYou {
                nextFooter(next)
            }
        }
        // Wider on a regular-width iPad, as the Overview's (round 36: 16 pt read cramped beside the
        // sidebar).
        .padding(.horizontal, widthClass == .regular ? Tokens.Space.xl : Tokens.Space.l)
        // Only below: the content margin above keeps the first line clear of the bar's fade. The
        // opening's room below the end is padding, not a content margin, so a send takes it away
        // in the same glide as the scroll (round 69: sa#6, a margin went in one frame and the
        // transcript dropped by it before the glide carried it up).
        .padding(.bottom, 12 + restInset)
        // Full width even when empty: the scroll view sizes to it, and the placeholder and
        // reconnecting badge over it would otherwise get a sliver and wrap a letter per line.
        .frame(maxWidth: Tokens.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .coordinateSpace(.named(transcriptSpace))
    }

    @ViewBuilder
    private func pendingBubble(_ message: PendingSend) -> some View {
        Group {
            if message.held {
                QueuedBubble(text: message.text, canUnsend: message.id == pending.last(where: \.held)?.id && !unsending && !sending && connection.isLive) {
                    Task { await unsend(message) }
                }
            } else {
                UserBubble(text: message.text, images: [])
            }
        }
        // No rise of its own: the transcript's scroll carries it up out of the field (round 45:
        // sa#1, sb#6, opus#2, an unanimated scroll jumped the card above ~45 pt in one frame
        // while only the bubble rose; round 10 had the bubble's own insertion animated as well).
        .contextMenu {
            Button("Remove Pending Message", role: .destructive) { pending.removeAll { $0.id == message.id } }
        }
    }

    /// Under the message just sent, until the agent answers or starts on it: that it's on its
    /// way, then that it went through, without calling the agent Working before the host says so
    /// (round 16: the field emptied and the bubble appeared under a header still saying Done,
    /// with nothing to say whether it had been delivered).
    /// The words swap in place, not crossfaded (round 17: "Sending…" drew over "Sent" for a few
    /// frames); VoiceOver hears "Sent" once it is (`sendDraft`).
    private var handoffLine: some View {
        Label(handedOff ? "Sent · waiting for the agent to start" : "Sending…",
              systemImage: handedOff ? "checkmark" : "arrow.up")
            .labelStyle(.caveat)
            .font(.footnote)
            .foregroundStyle(Tokens.secondaryText)
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .trailing)
            // Tucked under the bubble rather than a transcript block's distance below it.
            .padding(.top, -Tokens.Space.m)
            .transition(.opacity)
    }

    /// Whom a send goes to, as VoiceOver names the field and Send: the title, its host when
    /// several are shown, and its workspace (round 72: sb#1, the title alone couldn't tell two
    /// like-named tasks in different workspaces or hosts apart).
    private var recipient: String? {
        guard let agent else { return nil }
        let workspace = connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.displayLabel
        return AgentDock.accessibilityTitle(title: title, host: settings.allHosts ? connection.profile.name : nil, workspace: workspace)
    }

    /// While reconnecting the pill above the transcript says so, with the agent's last known
    /// status; the subtitle keeps its place (round 39: opus#11, the status went exactly when it
    /// was stale; round 43: sa#4, sb#4, opus#5, "Last known: Done · web-das…" cut the place).
    /// The harness is named in the More menu (round 9: "· OMP" here pushed Terminal off the bar
    /// and cut to "O…" at large sizes).
    private var subtitle: String {
        let workspace = agent.flatMap { agent in connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.displayLabel }
        if handoffWaitingForAgent { return [handedOff ? "Sent" : "Starting", workspace].compactMap { $0 }.joined(separator: " · ") }
        if connection.isConnecting || connection.statusText != nil {
            guard let agent else { return connection.statusText ?? workspace ?? connection.profile.name }
            // The pill says the status; without it (the host failed), the subtitle does, said
            // as last known, in grey (round 41: sa#8, sb#6, a bare "Done" read as current).
            if connection.isConnecting, connection.statusText != nil, let workspace { return workspace }
            return ["Last known: \(connection.presentedStatus(agent).label)", workspace].compactMap { $0 }.joined(separator: " · ")
        }
        guard let agent else { return "Exited" }
        // Gone still, "no update 6m" (`subtitleStill`) in place of how long the turn has run, in grey,
        // as the inbox has it (round 31: blue "Working" here and in the terminal beside the inbox's grey).
        return [connection.presentedStatus(agent).label, workspace].compactMap { $0 }.joined(separator: " · ")
    }

    /// While the transcript's "Sent · waiting for the agent to start" receipt shows, the subtitle
    /// says "Sent" (round 21: the header said Done under that receipt). Same condition as the
    /// receipt: the sent bubble can still be pending, outside the feed. Start & Send's queued
    /// first message is the same wait, said as "Starting" (round 48: opus#1, "Done" before it began).
    private var handoffWaitingForAgent: Bool { handedOff || firstSend == .waiting }

    /// The status's colour while the subtitle leads with it; "Sent" in the secondary grey.
    private var subtitleTint: Color? {
        if handoffWaitingForAgent { return Tokens.secondaryText }
        guard let agent, !connection.isConnecting, connection.statusText == nil else { return nil }
        return connection.presentedStatus(agent).tint
    }

    /// The run's start as the inbox row counts it (`HostConnection.workingSince`: the turn's
    /// message, or going back to work after an answer, if later; round 43: sa#3, just approved,
    /// the subtitle read "Working for 46m"; round 44: the row said "for 2m" over the thread's
    /// "for 1m"), else this transcript's turn start.
    private var workingSince: Date? {
        guard let agent, !connection.isConnecting, connection.statusText == nil,
              connection.presentedStatus(agent) == .working else { return nil }
        if let since = connection.workingSince(agent, status: .working) { return since }
        guard let started = feed.conversation.turnStarted,
              !feed.conversation.finishedTurns.values.contains(where: { $0.started == started }) else { return nil }
        return connection.resumed(agent).map { max($0, started) } ?? started
    }

    /// How long the subtitle's state has held: a turn's run, or a wait from when it asked, the
    /// inbox's "waiting" time ("Waiting 4m"; round 19: the thread said nothing of how long
    /// it had waited, where the inbox and dock did).
    private var subtitleSince: Date? {
        if handoffWaitingForAgent { return nil }
        guard subtitleWaits, let agent else { return workingSince }
        return connection.ageDate(agent, status: .blocked)
    }

    /// When this working agent's transcript last moved, for the subtitle's "no update 6m"
    /// (`BarTitle.still`), which it counts on the minute as the inbox does.
    private var subtitleStill: Date? {
        guard let agent, !handoffWaitingForAgent, !connection.isConnecting, connection.statusText == nil,
              connection.presentedStatus(agent) == .working else { return nil }
        return connection.stillSince(agent)
    }

    /// The subtitle leads with a wait on the user.
    private var subtitleWaits: Bool {
        guard let agent, !handoffWaitingForAgent, !connection.isConnecting, connection.statusText == nil else { return false }
        return connection.presentedStatus(agent) == .blocked
    }

    /// The Live Activity's step line: the Now line's words while something runs ("Waiting on
    /// npm run bench", "boundary-tests working"), else the newest call as its run says it ("Ran
    /// bun test move.test.ts"; a bare tool name like "task" said nothing).
    private var watchedRunDetail: String? {
        if let now = nowLine?.label, now != "Working…" { return now }
        for item in feed.conversation.items.reversed() {
            if case .tool(let tool) = item, tool.name != "wait", tool.summary != tool.name {
                let label = StepRun([item]).label
                return label.isEmpty ? nil : label
            }
        }
        return nil
    }
    /// What runs after an approval, at the transcript's end, until the agent writes again: the
    /// approved command ("Running bun test …"), else "Working…" (round 21: the approval card left
    /// a card-sized hole before the reply). Likewise after the user's own message, once the host
    /// says the agent is at work and before its first word (round 59: opus#1, the bubble sat over
    /// empty black for seconds, only the subtitle's "Working" said it had started).
    private var tailWorkLabel: String? {
        guard agent?.agentStatus == .working, !feed.isOfflineCopy,
              let last = feed.conversation.items.last else { return nil }
        // Nothing shown after the message yet: steps this detail level folds away don't count.
        if case .user? = feed.conversation.items(at: detailOverride ?? settings.detailLevel).last {
            guard !handedOff else { return nil }
            if let command = feed.conversation.runningTools.last(where: { $0.kind == .command }),
               let running = StepRun([.tool(command)]).running {
                return running
            }
            return "Working…"
        }
        guard let approval = decisionLog.entries(for: decisionKey).last(where: {
                  $0.receipt.hasPrefix("Approved") && $0.afterItemID == last.id
              }) else { return nil }
        if let command = feed.conversation.runningTools.last(where: { $0.kind == .command }),
           let running = StepRun([.tool(command)]).running {
            return running
        }
        return approval.detail.map { "Running \($0)" } ?? "Working…"
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
        } else if connection.isConnecting, !feed.isRenderable, !feed.isOfflineCopy {
            // The link is the cause, so say that, not that the transcript is unreadable; the
            // pill above says when it retries.
            ContentUnavailableView {
                Label("Not connected", systemImage: "wifi.slash")
            } description: {
                // The pinned line and the composer's "Write a Draft" already offer the draft. What
                // the inbox last read stands in for the copy it hasn't got (round 6: nothing did).
                VStack(spacing: Tokens.Space.m) {
                    Text("This conversation loads when \(connection.profile.name) is reachable again.")
                    if let agent, let preview = connection.preview(agent) {
                        VStack(spacing: Tokens.Space.xs) {
                            Text(connection.lastTurnAt(agent).map { "Last turn \($0.formatted(.relative(presentation: .named)))" } ?? "Last seen")
                                .font(.footnote.weight(.semibold))
                            Text("“\(preview)”").font(.callout).lineLimit(4)
                        }
                        .foregroundStyle(Tokens.secondaryText)
                    }
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
        } else if feed.state == .loading, !feed.isRenderable, !feed.isOfflineCopy, connection.snapshot != nil, !connection.isConnecting, pending.isEmpty {
            ProgressView()
        } else if firstSend == .waiting, feed.conversation.items.isEmpty {
            // Starting, not idle: the message is queued over the field (round 48: opus#1, "Send
            // a message to get started" sat over a message already set to go).
            VStack(spacing: Tokens.Space.s) {
                ProgressView()
                Text("Starting \(firstSendAgentName)…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
                let format = agent?.agent.flatMap { TranscriptFormat(agent: $0) }
                AskPanel(ask: ask, omp: agent?.agent == "omp", drivable: format == .omp || format == .claude,
                         answering: answering, paneID: paneID,
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
                // Out at once when its choice lands: the receipt is already in the transcript
                // (round 22: a fading "Approving…" card sat under "You approved" for 400 ms).
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else if let wait = terminalWait, let console = liveConsole?.id == wait.id ? liveConsole?.screen : wait.console {
                TerminalInputCard(console: console, sending: replying, terminalAddress: connection.address(paneID: paneID)) { text, shown in
                    Task { await replyToTerminal(text, shown: shown, wait: wait) }
                }
                .cardBackground()
                .id(wait.id)
            } else if blocked, confirmation == nil, !answering, choosing == nil {
                // Right after a choice lands, herdr may still say blocked for a beat: what was
                // sent holds the slot rather than a stale "waiting for you". So does an answer
                // still confirming: the transcript logs it, taking the card away, a moment before
                // the driver returns (round 6: the banner flashed in that gap).
                NeedsYouBanner(paneID: paneID, terminalAddress: connection.address(paneID: paneID)).cardBackground()
            }
            if let confirmation, !answerCardShown { confirmationPill(confirmation) }
            if let firstSend { firstSendLine(firstSend) }
            // The pinned line rides over the field, between the mic and the dock while it's short.
            MessageComposer(draft: $draft, attachments: $attachments, sending: sending || shareImportTaskID != nil, focus: $composerFocused,
                            placeholder: composerOffline ? "Write a Draft" : "Message", recipient: recipient,
                            actions: composerActions, dismissals: keyboardDismissals, docksAgents: hasDock,
                            pinned: pinnedLineShown ? AnyView(pinnedLine) : nil,
                            locked: agent == nil, offline: composerOffline,
                            vocabulary: { dictationVocabulary }, onWillFocus: keepPlaceForReply) { Task { await sendDraft() } }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3), value: confirmation)
        // An ask or permission card replaces typing: put the keyboard away so the card has the room.
        .onChange(of: pendingAsk != nil || (locatedRef == agent?.agentSession && (blocked || planReview) && screenPrompt != nil)) { _, prompting in
            if prompting { keyboardDismissals += 1 }
        }
        // 4 pt outside the transcript's text, in the same centred column.
        .padding(.horizontal, widthClass == .regular ? Tokens.Space.xl - 4 : Tokens.Space.m)
        .frame(maxWidth: Tokens.readableWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // An inset gets no scroll edge effect, so the bar brings its own: the transcript fades out
        // just above it instead of running under the Now line.
        .background {
            Rectangle().fill(Tokens.Surface.base)
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

    /// A choice landed: the card gives way to what was sent, for a moment, before the agent's
    /// next line takes the slot.
    private func confirmationPill(_ text: String) -> some View {
        SentPill(text: text)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(2.5))
                // herdr can say blocked a few beats after the answer landed: the pill keeps the
                // slot until it doesn't (8 s at most), not a stale "Waiting for you" banner.
                var waited = 2.5
                while blocked, waited < 8, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 0.25
                }
                if confirmation == text { confirmation = nil }
            }
    }

    /// Other threads to switch to, so the dock keeps its place in the bar; none beside the iPad
    /// sidebar, which lists them (`SceneState.sidebarBeside`).
    private var hasDock: Bool {
        guard settings.showsDock, !scene.sidebarBeside else { return false }
        let current = connection.address(paneID: paneID)
        return model.dockThreads(in: scene).contains { $0.address != current }
    }

    /// An ask, permission or Needs You card holds the slot over the composer instead.
    private var promptCardShown: Bool {
        blocked || terminalWait != nil || (locatedRef == agent?.agentSession && planReview && screenPrompt != nil)
    }

    /// A card that takes an answer (ask, permission, terminal input), as opposed to the bare
    /// Needs You banner.
    private var answerCardShown: Bool {
        pendingAsk != nil || terminalWait != nil
            || (locatedRef == agent?.agentSession && (blocked || planReview) && screenPrompt != nil)
    }
    /// The host is away or this is the offline copy: the composer drafts but doesn't send.
    private var composerOffline: Bool { !connection.isLive || feed.isOfflineCopy }

    private var pinnedLineShown: Bool {
        guard !promptCardShown else { return false }
        if (nextNeedsYou != nil && !nextInTranscript) || pinnedNow != nil { return true }
        guard feed.state == .live, catchUpPinned, let arrival else { return false }
        return feed.conversation.catchUp(after: arrival.item) != nil
    }

    private var nextNeedsYou: (thread: Thread, count: Int)? {
        guard nextNeedsYouActive || restsOnNext, pendingAsk == nil, screenPrompt == nil else { return nil }
        let current = connection.address(paneID: paneID)
        let others = model.dockThreads(in: scene).filter { $0.address != current }
        guard let first = AgentDock.firstNeedsYou(in: others, scene: scene) else { return nil }
        let count = others.count(where: scene.needsUser)
        return (first, count)
    }

    /// The open agent has finished and nothing of its own is pinned: the line names who needs
    /// the user next, as it does after an answer (round 39: opus#10, sa#7, sb#15, a sheep with
    /// an orange 1 didn't say it led to another agent). Not beside the iPad's sidebar, which
    /// lists them, nor over a catch-up line or a send under way. At accessibility sizes it
    /// follows the result in the transcript instead (see `nextInTranscript`).
    private var restsOnNext: Bool {
        guard !scene.sidebarBeside, let agent, connection.isLive, !feed.isOfflineCopy,
              !sending, pending.isEmpty,
              [AgentStatus.done, .idle].contains(connection.presentedStatus(agent)) else { return false }
        guard feed.state == .live, catchUpPinned, let arrival else { return true }
        return feed.conversation.catchUp(after: arrival.item) == nil
    }

    /// At accessibility sizes Next follows the result at the transcript's end rather than pinning
    /// over it (round 48: sa#1, sb#3, opus#8, pinned, its lines and the composer left the verdict
    /// a sliver of the screen; round 44's title-only pill still took two lines), after an answer
    /// too (round 49: sb#5, pinned again then, it took the room back in the busiest moment).
    private var nextInTranscript: Bool {
        typeSize.isAccessibilitySize && nextNeedsYou != nil
    }

    private func openNext(_ next: (thread: Thread, count: Int)) {
        nextNeedsYouActive = false
        AgentDock.open(next.thread, current: connection.address(paneID: paneID),
                       busy: sending, width: nil, scene: scene)
    }

    private func nextAccessibilityLabel(_ next: (thread: Thread, count: Int)) -> String {
        let host = next.thread.connection === connection ? nil : next.thread.connection.profile.name
        let title = AgentDock.accessibilityTitle(title: next.thread.agent.conversationTitle, host: host,
                                                 workspace: next.thread.workspace?.displayLabel)
        return "Next agent that needs you: \(title)\(next.count > 1 ? ". \(next.count) waiting" : "")"
    }

    /// The accessibility-size Next as the transcript's last block: the orange glyph inline before
    /// the whole title, then where it runs and how many wait, across the column's full width (round
    /// 49: sa#4, sb#15, a glyph column and a chevron column broke "web-dashboard" over two lines);
    /// a line of the transcript, not a second card under the result (round 68: sa#4, its plate
    /// stood as tall as the result's last paragraph), its title ending in a chevron, so it reads
    /// as a way on, not a heading (round 69: opus#4).
    private func nextFooter(_ next: (thread: Thread, count: Int)) -> some View {
        let host = next.thread.connection === connection ? nil : next.thread.connection.profile.name
        // The workspace only where it isn't this one's: at these sizes its line stood as tall as
        // the title, a block of navigation under the result (round 89: sa#4, sb#2), but dropped
        // everywhere the large-text reader lost where an agent in another one runs (round 90:
        // sb#3). Another host and a count show too; they change what the tap does.
        let here = agent.flatMap { agent in connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.displayLabel }
        let workspace = next.thread.workspace?.displayLabel
        let detail = [host, host == nil && workspace == here ? nil : workspace, next.count > 1 ? "\(next.count) waiting" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { openNext(next) } label: {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                // A step under the result's body, as a way on rather than a second result (round
                // 86: sa#3, sb#3, at body semibold it rivalled the result in weight; round 89:
                // sa#4, medium, the semibold still read as a heading).
                Text("\(Text(Image(systemName: AgentStatus.blocked.symbol)).foregroundStyle(Tokens.Tint.attention)) Next: \(next.thread.agent.conversationTitle) \(Text(Image(systemName: "chevron.right")).font(.subheadline.weight(.semibold)).foregroundStyle(Tokens.secondaryText))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                if !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Tokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nextAccessibilityLabel(next))
        .accessibilityHint("Opens its conversation")
        .accessibilityAddTraits(.isButton)
    }

    /// What's running now, else what came since the last look; next attention takes priority.
    @ViewBuilder
    private var pinnedLine: some View {
        if let next = nextNeedsYou, !nextInTranscript {
            // Where it is, quieter than what it is (round 6: the title alone didn't say where
            // it runs): its host too when that isn't this one. Short of room the count goes
            // first, then the host; then the place moves under the title (round 8: the
            // workspace was the first to go), and only then is it dropped.
            let host = next.thread.connection === connection ? nil : next.thread.connection.profile.name
            let workspace = next.thread.workspace?.displayLabel
            let place = { (parts: [String?]) in
                let shown = parts.compactMap { $0 }
                return shown.isEmpty ? Text(verbatim: "") : Text(" · \(shown.joined(separator: " · "))").foregroundStyle(.secondary)
            }
            let waiting = next.count > 1 ? " · \(next.count) waiting" : ""
            let title = next.thread.agent.conversationTitle
            let shorter: [Text] = (waiting.isEmpty ? [] : [Text("Next: \(title)\(place([host, workspace]))")])
                + (host == nil ? [] : [Text("Next: \(title)\(place([workspace]))")])
                + [Text("Next: \(title)")]
            let placeParts = [host, workspace].compactMap { $0 }
            let stacked: (title: Text, detail: Text)? = placeParts.isEmpty ? nil
                : (title: Text("Next: \(title)"), detail: Text(placeParts.joined(separator: " · ")))
            // While this agent works, or while the reader writes, Next is a quiet line, not the
            // capsule: the run in the transcript, or the reply, is the thing at hand and Next an
            // option (round 60: sa#1, the capsule outweighed the new task's running step after
            // Start & Send; round 61: sa#2 r60, with the keyboard up it held the strongest place
            // over the field while the result being answered faded above it).
            PinnedLine(label: Text("Next: \(title)\(place([host, workspace]))\(waiting)"),
                       symbol: AgentStatus.blocked.symbol, tint: Tokens.Tint.attention,
                       prominent: nowLine == nil && !keyboardUp,
                       shorter: shorter, stacked: stacked) {
                openNext(next)
            }
            .accessibilityLabel(nextAccessibilityLabel(next))
            .accessibilityHint("Opens its conversation")
        } else if promptCardShown {
            EmptyView()
        } else if let now = pinnedNow {
            // Too narrow for the step and its subagents on one line: the step over them in
            // caption, then the step alone (round 16: "Running bun test refill.test.ts · b…").
            let halves = now.step.flatMap { step in now.extra.map { (title: Text(step), detail: Text($0)) } }
            PinnedLine(label: Text(now.label), live: true, shorter: halves.map { [$0.title] } ?? [],
                       stacked: halves, action: now.opens ? { showsNow = true } : nil)
        } else if feed.state == .live, catchUpPinned, let arrival, let catchUp = feed.conversation.catchUp(after: arrival.item) {
            PinnedLine(label: CatchUpLine.summary(catchUp, since: arrival.seen)) {
                catchUpPinned = false
                followsLatest = false
                position.scrollTo(id: CatchUpLine.id, anchor: .top)
            }
        }
    }

    /// The Now line, when asks, prompts and Needs You leave the slot over the composer free.
    /// While it shows, the transcript leaves what's running to it; while Next holds the slot,
    /// the transcript keeps it (round 59: opus#1, a run started under "Next: Deploy to staging"
    /// showed in neither place, the user's bubble over empty black until the result).
    private var pinnedNow: (label: String, opens: Bool, step: String?, extra: String?)? {
        guard pendingAsk == nil, !blocked, terminalWait == nil, !(planReview && screenPrompt != nil),
              nextNeedsYou == nil || nextInTranscript else { return nil }
        return nowLine
    }

    /// What's running, in one line: the newest call, then working subagents and background
    /// commands. Shown while the agent works or its subagents do; nothing when offline. `step`
    /// and `extra` are its two halves, for a row too narrow for both on one line.
    private var nowLine: (label: String, opens: Bool, step: String?, extra: String?)? {
        guard connection.isLive, !feed.isOfflineCopy, feed.state == .live, locatedRef == agent?.agentSession else { return nil }
        let conversation = feed.conversation
        let subagents = conversation.workingSubagents
        guard agent?.agentStatus == .working || !subagents.isEmpty else { return nil }
        let tools = conversation.runningTools
        let background = conversation.backgroundCommands
        let step = StepRun(tools.map { .tool($0) }, waitingOn: conversation.waitingOn).running
        var extras: [String] = []
        // A wait's line already names what it waits on.
        if tools.last?.name != "wait" {
            if subagents.count == 1 { extras.append("\(subagents[0].name) working") }
            if subagents.count > 1 { extras.append("\(subagents.count) subagents working") }
            if !background.isEmpty { extras.append("\(background.count) in background") }
        }
        let parts = [step].compactMap { $0 } + extras
        let extra = extras.isEmpty ? nil : extras.joined(separator: " · ")
        return (parts.isEmpty ? "Working…" : parts.joined(separator: " · "), !(tools.isEmpty && subagents.isEmpty && background.isEmpty),
                step, extra)
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

    /// New Agent's first message: it lands in the composer if that's empty (the demo keeps no
    /// drafts; elsewhere it's the saved draft already). With Start & Send it goes once the agent
    /// has reported its session (its harness is up) and isn't busy, a second after that so its
    /// prompt reads input. Meanwhile a line over the field says it will, with Don't Send (round
    /// 20: the queued message sat in the composer like any draft, and a timeout was silent).
    /// Not up within 30 s, it says it wasn't sent and the text stays in the composer; left
    /// first, it just stays there.
    private func takeFirstMessage() async {
        let address = connection.address(paneID: paneID)
        guard let message = scene.firstMessage, message.address == address,
              message.agentName == nil || agent == nil || agent?.name == message.agentName else { return }
        defer { if scene.firstMessage == message { scene.firstMessage = nil } }
        if draft.isEmpty { draft = message.text }
        guard message.send else { return }
        withAnimation { firstSend = .waiting }
        for _ in 0..<60 {
            // Don't Send, or the user sent or cleared it themselves.
            guard firstSend == .waiting, !draft.isEmpty else {
                if firstSend == .waiting { withAnimation { firstSend = nil } }
                return
            }
            if let agent, agent.hasTranscript, connection.isLive,
               message.agentName == nil || agent.name == message.agentName,
               ![.working, .blocked].contains(connection.presentedStatus(agent)) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, firstSend == .waiting else { return }
                // Still the agent it was written for; another in the pane keeps it as a draft.
                guard message.agentName == nil || self.agent?.name == message.agentName else {
                    withAnimation { firstSend = nil }
                    return
                }
                withAnimation { firstSend = nil }
                await sendDraft()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        guard firstSend == .waiting else { return }
        withAnimation { firstSend = .notSent }
        AccessibilityNotification.Announcement("Not sent. \(firstSendAgentName) didn't start in time; your message is in the composer.").post()
    }

    private var firstSendAgentName: String { agent?.agent.map(agentKindLabel) ?? "The agent" }

    /// Start & Send's line over the field: queued, or not sent after all.
    private func firstSendLine(_ state: FirstSend) -> some View {
        HStack(spacing: Tokens.Space.s) {
            Label(state == .waiting ? "Sends when \(firstSendAgentName) is ready" : "Not sent: \(firstSendAgentName) didn't start in time",
                  systemImage: state == .waiting ? "clock" : "exclamationmark.circle")
                .labelStyle(.caveat)
                .foregroundStyle(Tokens.secondaryText)
            Spacer(minLength: 0)
            Button(state == .waiting ? "Don't Send" : "OK") { withAnimation { firstSend = nil } }
                .fontWeight(.semibold)
        }
        .font(.footnote)
        .padding(.horizontal, Tokens.Space.xs)
        .frame(minHeight: 44)
        .transition(.opacity)
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, shareImportTaskID == nil, connection.isLive, let agent,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // omp holds a message sent mid-turn as steering and can hand it back (Alt+Up).
        let queues = agent.agent == "omp" && agent.agentStatus == .working && attachments.isEmpty
        let finished = [AgentStatus.done, .idle].contains(connection.presentedStatus(agent))
        let boundary = feed.conversation.lastStableID
        let packageID = importedPackageID
        let origin = draftID
        // The bubble goes in with the scroll to it, one short glide that carries the card above
        // up with it, and the field empties in the same frame (`show`).
        let shown = withAnimation(sendMotion) {
            sending = true
            // Cleared before delivery so the keyboard stays up and anything typed meanwhile is kept.
            draft = ""
            // A reply to a finished agent hands it off, as an answer does: the line goes on to
            // whoever needs the user next (round 42: sb#3, it went with the send, leaving only the
            // dock's badge); a message into a running turn doesn't. Set as the send starts, so the
            // line resting there stays through it (round 44: sa#14, it blinked out and back).
            nextNeedsYouActive = finished && !queues
            return show(text, afterItemID: boundary, held: queues)
        }
        defer { sending = false }
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: true, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            attachments = []
            sentCount += 1
            handedOff = !queues
            if !queues { AccessibilityNotification.Announcement("Sent, waiting for the agent to start").post() }
            finishImport(packageID)
        } catch {
            // The draft holds the text again; a bubble beside it would invite sending it twice.
            nextNeedsYouActive = false
            pending.removeAll { $0.id == shown }
            restoreFailedSend(text, to: origin)
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
        }
    }

    /// A failed send's text goes back into the draft it came from, ahead of anything typed
    /// since. Stored as well: the user may have left this conversation while it was sending.
    private func restoreFailedSend(_ text: String, to origin: String?) {
        let restored = restoringDraft(text, before: origin.flatMap(DraftStore.load) ?? draft)
        draft = restored
        guard let origin else { return }
        DraftStore.save(restored, for: origin)
        scene.draftRevision += 1
    }

    /// A send's glide: the bubble in and the scroll to it as one motion.
    private var sendMotion: Animation? { reduceMotion ? nil : .snappy(duration: 0.3) }

    /// The message in the transcript from the tap on, not once the agent has written it down:
    /// that can take seconds, and a new thread has no transcript at all until then.
    private func show(_ text: String, afterItemID: String?, held: Bool) -> PendingSend.ID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let message = PendingSend(text: text, afterItemID: afterItemID, held: held)
        // The opening's room below the end goes in the same update (round 19: it went only once
        // the send returned, so the transcript settled 25 pt lower a frame after rising to it),
        // and in the same animation (see `transcript`'s bottom padding).
        pending.append(message)
        restInset = 0
        jumpToLatest()
        return message.id
    }

    /// A thread that isn't working opens on its latest turn whole (round 16: every grader saw
    /// threads open on a request sliced through its letters under the bar's fade). From where
    /// the reader's last message sits and where the end would rest:
    /// - whole at the end already: the end;
    /// - its top 30 pt or less above the end's view: its top, just under the fade (the turn's end
    ///   then has only its padding below the composer);
    /// - cut through at the end, its visible part (the fade's included) 56 pt or less: the end,
    ///   with that much room below it (`restInset`), so the message sits just out of view rather
    ///   than sliced; over a decision card the end stays on the card and the message's foot shows
    ///   under the fade, as a chat's does (round 19: room there read as an empty band above the
    ///   card; round 20: a deeper fade instead read as a black band under the bar);
    /// - otherwise a thread ending on a finished reply opens at the reply's top, so its Done line
    ///   and verdict come first (round 10: at accessibility sizes the review opened on its last
    ///   lines), a reply that fits still ending at the bottom.
    /// Once per opening, and not while a message is on its way.
    private func openAtTurn() {
        guard resultAnchor == .pending else { return }
        resultAnchor = .done
        guard pending.isEmpty, find == nil, agent.map({ connection.presentedStatus($0) }) != .working else { return }
        let items = feed.conversation.items(at: detailOverride ?? settings.detailLevel)
        let request = items.last { if case .user = $0 { true } else { false } }
        let result = items.last.flatMap { last -> ConversationItem? in
            guard case .assistant = last, feed.conversation.finishedTurns[last.id] != nil else { return nil }
            return last
        }
        guard request != nil || result != nil else { return }
        resultAnchor = .held
        followsLatest = false
        Task { @MainActor in
            // After the rows are laid out, or the scroll has nothing to go to; the message's
            // frame comes with its layout, a beat later if not yet.
            await Task.yield()
            if let request, openGeometry.userFrames[request.id] == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard resultAnchor == .held else { return }
            let frame = request.flatMap { openGeometry.userFrames[$0.id] }
            if let request, let frame, let restTop = openGeometry.restTop, frame.minY < restTop {
                // Rows still show, faded, in the fade above the content margin.
                let seenTop = restTop - Tokens.Space.l
                if restTop - frame.minY <= 30 {
                    position.scrollTo(id: request.id, anchor: .top)
                } else if frame.maxY > seenTop, frame.maxY - seenTop <= 56 {
                    // Over a card the end stays on the card.
                    if !answerCardShown {
                        restInset = frame.maxY - seenTop
                        // Once the room is laid out; the offset alone stays where it was.
                        try? await Task.sleep(for: .milliseconds(30))
                        position.scrollTo(edge: .bottom)
                    }
                } else if let result {
                    position.scrollTo(id: result.id, anchor: .top)
                }
            } else if frame == nil, let result {
                position.scrollTo(id: result.id, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard resultAnchor == .held else { return }
            resultAnchor = .done
            // The end is on screen too, so the newest is followed again.
            if atLatest { followsLatest = true }
        }
    }

    /// Focusing an empty composer on a settled thread keeps what's read in view: the keyboard
    /// covers the end rather than pushing the result's Done line and verdict up out of view
    /// (round 19: all three graders lost the verdict they were replying to), and a thread that
    /// ends on a result brings the result's top under the bar, so the room the keyboard leaves
    /// holds the reply being answered (round 20: it held the narration and tool rows before it,
    /// with only the verdict's first line). Decided as the field is about to take focus, so the
    /// keyboard's first frame already sees it (round 20: set once focus had changed, it came
    /// after the keyboard had moved the transcript). Sending follows the end again
    /// (`jumpToLatest`); a working agent's stream is still followed.
    private func keepPlaceForReply() {
        guard draft.isEmpty, pending.isEmpty, let agent, connection.presentedStatus(agent) != .working else { return }
        followsLatest = false
        let items = feed.conversation.items(at: detailOverride ?? settings.detailLevel)
        guard let last = items.last, case .assistant = last, feed.conversation.finishedTurns[last.id] != nil else { return }
        // Once the keyboard has taken its room (before, a result that fits has nowhere to go).
        replyAnchor = last.id
        Task { try? await Task.sleep(for: .seconds(1)); replyAnchor = nil }
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
        let boundary = feed.conversation.lastStableID
        let packageID = importedPackageID
        let origin = draftID
        sending = true
        defer { sending = false }
        draft = ""
        var shown: PendingSend.ID?
        do {
            guard OmpEditor.draft(inScreen: try await client.readPane(paneID, session: session).text) == nil else {
                restoreFailedSend(text, to: origin)
                sendError = "omp has unsent text in its editor. Clear it in the terminal first."
                return
            }
            shown = withAnimation(sendMotion) { show(text, afterItemID: boundary, held: true) }
            try await connection.sendText(text, pane: paneID, submit: false)
            try await connection.sendKeys(["ctrl+q"], pane: paneID)
            sentCount += 1
            nextNeedsYouActive = false
            finishImport(packageID)
        } catch {
            pending.removeAll { $0.id == shown }
            restoreFailedSend(text, to: origin)
            sendError = "The message wasn't queued. Your draft is still here. \(error.localizedDescription)"
        }
    }

    /// Settlement waits for a caught-up transcript; until then a stand-in whose real message is
    /// already shown is only hidden, so the two never show side by side.
    private var unarrived: [PendingSend] { entry.unsettled }

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
            // Empty: the agent took it first, and the transcript will show it as sent.
            guard let recovered = OmpEditor.draft(inScreen: after.text) else { return }
            // A message queued at the desk since is newer, so Alt+Up hands that one back instead.
            // The editor may show only part of a long message.
            let shown = recovered.filter { !$0.isWhitespace }
            guard message.text.filter({ !$0.isWhitespace }).contains(shown) || message.matches(recovered) else {
                sendError = "omp handed back a different queued message, so it was left in omp's editor."
                return
            }
            // With text in its editor, Ctrl+C clears it and leaves the turn running.
            try await connection.sendKeys(["ctrl+c"], pane: paneID)
            pending.removeAll { $0.id == message.id }
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
        askRetry = nil
        do {
            // A try after "not confirmed" may find the agent has logged the answer since.
            if await feed.waitForResult(of: ask.toolCallId, timeout: .zero) {
                sentCount += 1
                confirm("Answered", after: ask.toolCallId)
                return
            }
            try await PromptDriver.answer(ask, replies: replies, io: io)
            sentCount += 1
            let text = replies.count == 1 ? (replies[0].selected + [replies[0].custom].compactMap { $0 }).joined(separator: ", ") : ""
            // The transcript's question-and-answer block says what was asked; the decision only
            // adds that it was answered here, and when.
            confirm(text.isEmpty ? "Answered" : "Answered “\(text)”", after: ask.toolCallId)
        } catch {
            if (error as? PromptDriverError) != .unsupported { askRetry = (ask, replies) }
            askFailure = PromptDriverError.message(for: error)
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
            confirm(PromptOptionKind.receipt(for: label), detail: prompt.shownSubject, detailMayBeCut: prompt.contextMayBeTruncated)
        } catch {
            askRetry = nil
            askFailure = PromptDriverError.message(for: error)
        }
    }

    /// Shows the completed action in the slot the card left, and says it to VoiceOver.
    /// `after`: the item the decision follows in the thread; by default the newest.
    private func confirm(_ text: String, detail: String? = nil, detailMayBeCut: Bool = false, after: String? = nil) {
        confirmation = text
        decisionLog.record(key: decisionKey, afterItemID: after ?? feed.conversation.items.last?.id,
                           receipt: text, detail: detail, detailMayBeCut: detailMayBeCut, saved: demo == nil)
        nextNeedsYouActive = true
        AccessibilityNotification.Announcement(text).post()
    }

    /// Finds the transcript file. Claude Code and Codex name only a session id, which the
    /// host resolves to a path, unless the inbox already resolved it for the row's preview;
    /// a dropped channel or a file not flushed yet gets a few retries.
    private func locateTranscript() async {
        guard !Task.isCancelled else { return }
        guard let ref = locatedRef else { return }
        locateFailure = nil
        if let known = connection.activity[paneID], known.ref == ref, let transcript = known.transcript {
            location = TranscriptLocation(path: transcript.path, format: transcript.format)
            locateFailure = nil
            return
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
                // A folder check only as the folder the agent runs in, as Needs You has it.
                let cwd = agent?.workingDirectory ?? connection.snapshot?.panes.first { $0.id == paneID }?.workingDirectory
                let parsed = ScreenPrompt.parse(text)?.trustResolved(cwd: cwd)
                screenPrompt = parsed?.style == .choice && parsed?.phase == .question ? parsed : nil
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Follows the console of a waiting PTY command, so the card shows what it prints and goes
    /// as soon as the console leaves the agent's screen.
    private func watchConsole() async {
        // What an earlier link read doesn't count: the card shows the link's console until this one reads.
        liveConsole = nil
        guard let wait = terminalWait, let client = connection.client, let session = connection.activeSession else { return }
        while !Task.isCancelled {
            if !replying, let text = try? await client.readPane(paneID, session: session).text {
                guard !Task.isCancelled else { return }
                liveConsole = (wait.id, ConsoleScreen.parse(text))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Types `text` and Enter into the waiting command, once its console still shows the
    /// prompt the user answered (`shown`) for the same wait.
    private func replyToTerminal(_ text: String, shown: ConsoleScreen, wait: HostConnection.Wait) async {
        guard let client = connection.client, let session = connection.activeSession, !replying else { return }
        replying = true
        defer { replying = false }
        askRetry = nil
        do {
            let screen = ConsoleScreen.parse(try await client.readPane(paneID, session: session).text)
            guard session == connection.activeSession, agent.flatMap({ connection.wait($0)?.id }) == wait.id,
                  let screen, screen.command == shown.command, screen.prompt == shown.prompt else {
                liveConsole = (wait.id, screen)
                askFailure = screen == nil
                    ? "The command isn't waiting on the agent's screen anymore, so nothing was sent."
                    : "The command's prompt changed, so nothing was sent. Check the new one and reply again."
                return
            }
            if text.isEmpty {
                try await client.sendKeys(["enter"], pane: paneID, session: session)
            } else {
                try await client.sendText(text, pane: paneID, submit: true, session: session)
            }
            sentCount += 1
            if let after = try? await client.readPane(paneID, session: session).text {
                liveConsole = (wait.id, ConsoleScreen.parse(after))
            }
        } catch {
            askFailure = "The reply couldn't be sent. \(error.localizedDescription)"
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
    /// A wait leaves the sequence alone, so one arriving on screen is read by its own id.
    let wait: String?
    let visible: Bool
}

/// The ⋯ menu, compared by value: a menu that is rebuilt while open jumps back to its top, and
/// the conversation re-renders with every streamed record. So nothing here changes per reply:
/// thinking level, tokens and estimated cost open in an alert.
/// The places to go sit side by side in one row, so a slip lands on a neighbour you can see is
/// different; settings and rarer items are named submenus, Stop alone at the end.
struct ConversationMenu: View, Equatable {
    struct Mute: Equatable {
        let address: PaneAddress
        let reference: String
    }
    enum LiveActivity { case show, hide }
    enum Action { case detail(DetailLevel), find, images, changes, retry, stop, liveActivity, sessionDetails, explain, answerInTerminal, markUnread, hide, next }

    let detail: DetailLevel
    let canRetry: Bool
    /// The agent's tools returned images, or earlier history might hold some.
    let images: Bool
    /// The loaded transcript records a successful edit or file write.
    let changes: Bool
    let canStop: Bool
    let canAnswerInTerminal: Bool
    let liveActivity: LiveActivity?
    /// The model's name (or "Session"); nil when the transcript records none of it.
    let session: String?
    let sessionHasDetails: Bool
    let mute: Mute?
    /// The inbox row's triage, from here: both go back to the inbox.
    let canMarkUnread: Bool
    let canHide: Bool
    /// The agent's status label; nil without an agent.
    let status: String?
    /// The next agent that needs you, by title, and where it runs; nil when none does.
    let next: String?
    let nextPlace: String?
    let act: (Action) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.detail == rhs.detail && lhs.canRetry == rhs.canRetry && lhs.images == rhs.images && lhs.changes == rhs.changes && lhs.canStop == rhs.canStop
            && lhs.liveActivity == rhs.liveActivity && lhs.session == rhs.session
            && lhs.sessionHasDetails == rhs.sessionHasDetails && lhs.mute == rhs.mute
            && lhs.status == rhs.status && lhs.canAnswerInTerminal == rhs.canAnswerInTerminal
            && lhs.canMarkUnread == rhs.canMarkUnread && lhs.canHide == rhs.canHide && lhs.next == rhs.next && lhs.nextPlace == rhs.nextPlace
    }

    var body: some View {
        Menu {
            if let next {
                Section {
                    // Title, then subtitle, then icon: a menu item's own layout.
                    if let nextPlace, !nextPlace.isEmpty {
                        Button { act(.next) } label: {
                            Text("Next Needs You: \(next)")
                            Text(nextPlace)
                            Image(systemName: AgentStatus.blocked.symbol)
                        }
                    } else {
                        Button("Next Needs You: \(next)", systemImage: AgentStatus.blocked.symbol) { act(.next) }
                    }
                }
            }
            Section {
                // A palette row only with company: Find alone in one read as a stray tile
                // (round 50: opus#9).
                if images || changes {
                    ControlGroup {
                        Button("Find", systemImage: "magnifyingglass") { act(.find) }
                            .accessibilityLabel("Find in Conversation")
                        if images { Button("Images", systemImage: "photo.on.rectangle") { act(.images) } }
                        if changes { Button("Changes", systemImage: "doc.text") { act(.changes) } }
                    }
                } else {
                    Button("Find in Conversation", systemImage: "magnifyingglass") { act(.find) }
                }
                if canAnswerInTerminal {
                    Button("Answer in Terminal", systemImage: "apple.terminal") { act(.answerInTerminal) }
                }
            }
            Section {
                // "View", its levels checked inside, not "View: Messages and Steps" wrapping to
                // two lines (round 50: opus#9).
                Menu("View", systemImage: "slider.horizontal.3") {
                    DetailLevelOptions(selection: Binding(get: { detail }, set: { act(.detail($0)) }))
                }
                if session != nil || liveActivity != nil || status != nil {
                    Menu("Session", systemImage: "info.circle") {
                        if let session {
                            if sessionHasDetails {
                                Section(session) { Button("Session Details", systemImage: "info.circle") { act(.sessionDetails) } }
                            } else {
                                Section { Text(session) }
                            }
                        }
                        if let liveActivity {
                            Button(liveActivity == .hide ? "Hide Live Activity" : "Show Live Activity",
                                   systemImage: "rectangle.on.rectangle") { act(.liveActivity) }
                        }
                        if let status {
                            Button("Why “\(status)”?", systemImage: "questionmark.circle") { act(.explain) }
                        }
                    }
                }
                if let mute {
                    if Mutes.shared.isMuted(mute.address, reference: mute.reference) {
                        Button("Unmute Notifications", systemImage: "bell") { Mutes.shared.unmute(mute.address, reference: mute.reference) }
                    } else {
                        Menu("Mute Notifications", systemImage: "bell.slash") {
                            Button("For 1 Hour", systemImage: "clock") {
                                Mutes.shared.set(mute.address, reference: mute.reference, until: .now.addingTimeInterval(3600))
                            }
                            Button("Until Unmuted", systemImage: "bell.slash") {
                                Mutes.shared.set(mute.address, reference: mute.reference, until: nil)
                            }
                        }
                    }
                }
            }
            if canMarkUnread || canHide {
                Section {
                    if canMarkUnread { Button("Mark as Unread", systemImage: "envelope.badge") { act(.markUnread) } }
                    if canHide { Button("Hide", systemImage: "eye.slash") { act(.hide) } }
                }
            }
            if canRetry {
                Section { Button("Retry Last Turn", systemImage: "arrow.clockwise") { act(.retry) } }
            }
            if canStop {
                Section { Button("Stop Run", systemImage: "stop.circle", role: .destructive) { act(.stop) } }
            }
        } label: {
            Label("More", systemImage: "ellipsis").accessibilityShowsLargeContentViewer()
        }
        .menuOrder(.fixed)
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
    let decisions: [DecisionLog.Entry]
    let awaitingApproval: Bool
    let tailWork: String?
    let reduceMotion: Bool
    let openedAt: Date
    @State private var projection = ConversationProjection()
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feed === rhs.feed && lhs.detail == rhs.detail && lhs.arrival == rhs.arrival && lhs.nowPinned == rhs.nowPinned
            && lhs.decisions == rhs.decisions && lhs.awaitingApproval == rhs.awaitingApproval
            && lhs.tailWork == rhs.tailWork && lhs.openedAt == rhs.openedAt
    }

    var body: some View {
        let lines = self.lines
        // A stack of its own, at the transcript's spacing, to carry the thread's rotors: its
        // results, decisions and other agents' words, as the inbox has its own (round 81: sb#4,
        // a long thread was read top to bottom to find them).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                Group {
                    switch line {
                    case .row(.result(.assistant(_, let text), let turn)):
                        TurnResult(text: text, turn: turn, resumed: resumed(turn), id: line.id, openedAt: openedAt).id(line.id)
                    case .row(let row): row.view.id(row.id)
                    case .decision(let entry): DecisionRow(entry: entry).id(line.id)
                    }
                }
                .padding(.top, index == 0 ? 0 : Self.gap(after: lines[index - 1], before: line))
            }
            if let tailWork { TailWorkLine(label: tailWork, reduceMotion: reduceMotion).padding(.top, lines.isEmpty ? 0 : Tokens.Space.xl) }
        }
        .accessibilityRotor("Results") { rotor(lines, Self.result) }
        .accessibilityRotor("Decisions") { rotor(lines, Self.decision) }
        .accessibilityRotor("Agent Messages") { rotor(lines, Self.message) }
    }

    /// One run's narration and its work (tool steps, subagents, another agent's reply or a
    /// subagent's finish) sit close, a half gap apart, so the result after them (and the user's
    /// next message, a decision, the catch-up line) keeps the full break and reads as the turn's
    /// end (round 87: sa#3, every row a uniform 24 pt apart, the review spent its screen on gaps
    /// before the result; round 88: opus#3, sa#2, a wait and the reply it waited for, or a
    /// subagent's finish and the narration after it, still stood 24 pt apart). Two paragraphs of
    /// narration with no work between them keep the full gap.
    private static func gap(after previous: Line, before line: Line) -> CGFloat {
        func narration(_ line: Line) -> Bool {
            if case .row(.item(.assistant)) = line { true } else { false }
        }
        func work(_ line: Line) -> Bool {
            switch line {
            case .row(.steps), .row(.subagents), .row(.answer), .row(.item(.subagentResult)), .row(.item(.peerMessage)): true
            default: false
            }
        }
        let inRun = { (line: Line) in narration(line) || work(line) }
        let sameRun = inRun(previous) && inRun(line) && (work(previous) || work(line))
        return sameRun ? Tokens.Space.m : Tokens.Space.xl
    }

    private struct Stop: Identifiable {
        let id: String
        let label: String
    }

    /// One rotor's stops, each by the row's scroll id, so VoiceOver brings it into view.
    private func rotor(_ lines: [Line], _ label: (Line) -> String?) -> some AccessibilityRotorContent {
        ForEach(lines.compactMap { line in label(line).map { Stop(id: line.id, label: $0) } }) { stop in
            AccessibilityRotorEntry(Text(stop.label), id: stop.id)
        }
    }

    /// A finished turn: when, its warning first as the card sets it (round 82: sb#1, the stop
    /// said "No blocking findings" without the step to take before deploying), then its first line.
    private static func result(_ line: Line) -> String? {
        guard case .row(.result(.assistant(_, let text), let turn)) = line else { return nil }
        let when = turn.at.map { "Done \($0.transcriptStamp)" } ?? "Done"
        return [when, TranscriptActivity.caution(text).map(AgentRow.spokenCaution), Self.firstLine(text)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// What the user decided, here or from the inbox, and every question asked and answered.
    private static func decision(_ line: Line) -> String? {
        switch line {
        case .decision(let entry): DecisionRow.spoken(entry)
        // With what was chosen, every question and every choice, as the transcript's record says
        // it, so scanning the rotor tells how each was resolved (round 88: sb#13, it named the
        // question only; round 90: sb#1, keyed by the question's id it missed every per-question
        // answer, which the parsers key by its text).
        case .row(.item(.ask(let ask))) where ask.answer != nil:
            ask.questions.isEmpty ? nil : "Answered: " + ask.questions.map { question in
                guard let answer = ask.answer, !answer.cancelled else { return "\(question.question), dismissed" }
                let reply = AnsweredAsk.reply(to: question, in: answer)
                return reply.isEmpty ? question.question : "\(question.question), \(reply)"
            }.joined(separator: "; ")
        default: nil
        }
    }

    /// Another agent's message or a subagent's finish.
    private static func message(_ line: Line) -> String? {
        switch line {
        case .row(.item(.peerMessage(_, let peer, let text, _))), .row(.answer(.peerMessage(_, let peer, let text, _), _)):
            "From \(peer): \(Self.firstLine(text))"
        case .row(.item(.subagentResult(_, let activity))), .row(.answer(.subagentResult(_, let activity), _)):
            "\(activity.name) finished"
        default: nil
        }
    }

    /// A message's first line as speech: its Markdown marks dropped, long ones cut.
    private static func firstLine(_ text: String) -> String {
        let line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text)
            .replacing("**", with: "").replacing("`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    private enum Line: Identifiable {
        case row(ConversationRow)
        case decision(DecisionLog.Entry)
        var id: String {
            switch self {
            case .row(let row): row.id
            case .decision(let entry): "decision-" + entry.id.uuidString
            }
        }
    }

    /// The user's last yes or answer inside a finished turn, so its "Took" counts the agent's
    /// time after it rather than the wait for the user. A denial isn't resuming; "Chose “Skip”"
    /// is an answer.
    private func resumed(_ turn: FinishedTurn) -> (at: Date, word: String)? {
        guard let started = turn.started, let end = turn.at,
              let entry = decisions.last(where: { $0.at > started && $0.at <= end && !$0.receipt.hasPrefix("Denied") })
        else { return nil }
        return (entry.at, entry.receipt.hasPrefix("Approved") ? "approved" : "answered")
    }

    /// The projected rows, the run a prompt is holding up said as waiting, and each decision
    /// after the row holding the item that was last when it was made.
    private var lines: [Line] {
        var rows = projection.rows(feed: feed, detail: detail, arrival: arrival, nowPinned: nowPinned)
        if awaitingApproval, let last = rows.lastIndex(where: { if case .steps = $0 { true } else { false } }),
           case .steps(let items, _) = rows[last] {
            rows[last] = .steps(items, StepRun(items, waitingOn: feed.conversation.waitingOn, awaitingApproval: true))
        }
        guard !decisions.isEmpty else { return rows.map(Line.row) }
        var rowOf: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            switch row {
            case .item(let item), .answer(let item, _), .result(let item, _): rowOf[item.id] = index
            case .steps(let items, _): for item in items { rowOf[item.id] = index }
            case .subagents(let callID, _): rowOf[callID] = index
            case .since: break
            }
        }
        let anchored = Dictionary(grouping: decisions) { placement($0, rowOf: rowOf, count: rows.count) }
        var lines: [Line] = []
        for (index, row) in rows.enumerated() {
            lines += (anchored[index] ?? []).map(Line.decision)
            lines.append(.row(row))
        }
        return lines + (anchored[rows.count] ?? []).map(Line.decision)
    }

    /// After the nearest shown item at or before the one the decision followed, or (made from
    /// the inbox, which doesn't read the transcript) the last call running what it approved;
    /// neither found puts it at the end.
    private func placement(_ entry: DecisionLog.Entry, rowOf: [String: Int], count: Int) -> Int {
        let all = feed.conversation.items
        let target = entry.afterItemID.flatMap { id in all.lastIndex { $0.id == id } }
            ?? entry.detail.flatMap { detail in all.lastIndex { if case .tool(let tool) = $0 { tool.summary == detail } else { false } } }
        guard let target else { return count }
        for item in all[...target].reversed() {
            if let row = rowOf[item.id] { return row + 1 }
        }
        return 0
    }
}

/// A decision made from the app, left in the thread once its card is gone: quiet, like the
/// system's own "You changed the group name" lines in Messages.
private struct DecisionRow: View {
    let entry: DecisionLog.Entry
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off until it lands, for a record made just now (`body`).
    @State private var signed: Bool

    init(entry: DecisionLog.Entry) {
        self.entry = entry
        _signed = State(initialValue: Date.now.timeIntervalSince(entry.at) > 3)
    }

    var body: some View {
        let denied = entry.receipt == "Denied"
        // An ask's question and answer stand just above, in the transcript's own block; the line
        // only adds who answered, and when.
        let ask = entry.receipt.hasPrefix("Answered")
        let said = ask ? "answered" : entry.receipt.prefix(1).lowercased() + entry.receipt.dropFirst()
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Image(systemName: denied ? "xmark.shield" : "checkmark.shield")
                .foregroundStyle(denied ? Tokens.Tint.danger : Tokens.Tint.settled)
                // A record made just now signs itself in: its shield draws on as the card it
                // replaces goes (round 83: opus Delight, the core decision had no moment of its
                // own). Old records, and any under Reduce Motion, are simply there.
                .symbolEffect(.drawOn, isActive: !signed && !reduceMotion)
                .task {
                    guard !signed else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    signed = true
                }
            VStack(alignment: .leading, spacing: 2) {
                // Its day too once it isn't today's (round 83: sb#8, kept a week, records read
                // by time alone couldn't be told apart).
                Text("You \(said) · \(entry.at.transcriptStamp)")
                    .foregroundStyle(Tokens.secondaryText)
                if !ask, let detail = entry.detail, !detail.isEmpty {
                    // At the card's size (round 25: in caption the record's command and caveat
                    // were smaller than the request they answered).
                    Text(detail).font(.footnote.monospaced()).foregroundStyle(Tokens.secondaryText)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    if entry.detailMayBeCut {
                        // The card's warning, kept on the record (round 82: sb#9, opus#6, the
                        // receipt fell back to a grey viewfinder for the same doubt).
                        ScreenReadCaveat()
                    }
                }
            }
        }
        .font(.footnote)
        .padding(.vertical, Tokens.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(entry))
    }

    /// The record as VoiceOver says it, here and in the thread's Decisions rotor.
    static func spoken(_ entry: DecisionLog.Entry) -> String {
        let ask = entry.receipt.hasPrefix("Answered")
        return ["You \(entry.receipt.prefix(1).lowercased() + entry.receipt.dropFirst())",
                entry.at.transcriptStamp,
                ask ? nil : entry.detail, !ask && entry.detailMayBeCut ? "read from the screen, may be incomplete" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

extension Date {
    /// "9:12 PM", "Tue 9:12 PM" within the week, then "Mar 3, 9:12 PM", and before this year
    /// "Mar 3, 2025, 9:12 PM": the transcript's times, its records' too (round 91: sb#9, a weekday
    /// alone gave results weeks apart one date; round 92: opus#13, last year's read as this year's;
    /// round 93: sb#15, the year before the weekday, so New Year's week can't drop it).
    var transcriptStamp: String {
        if Calendar.current.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if !Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        }
        if timeIntervalSinceNow > -6 * 86_400 { return formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
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
    /// The reply that ended a turn, under a line saying when and how long it took.
    case result(ConversationItem, FinishedTurn)

    var id: String {
        switch self {
        case .item(let item), .answer(let item, _), .result(let item, _): item.id
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
                     finished: [String: FinishedTurn] = [:],
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
                // A wait and what ended it are one event: one agent's result, the row saying how
                // long it ran, or a message breaking in (round 89: opus#12, sb#14, "Waited for X"
                // stood over "X finished", a bare "Waited" over "From X").
                if !run.isEmpty, run.allSatisfy({ Self.isWait($0, endedBy: item) }) {
                    run = []
                }
                flush()
                if case .peerMessage(_, _, let brief, true)? = answered[item.id] {
                    rows.append(.answer(item, brief: brief))
                } else if case .assistant = item, let turn = finished[item.id] {
                    rows.append(.result(item, turn))
                } else {
                    rows.append(.item(item))
                }
            }
        }
        flush()
        return rows
    }

    /// A settled wait that `next` ends: a wait for that one agent before its result, or one for
    /// no agent of its own (a message broke in on it) before that message.
    private static func isWait(_ item: ConversationItem, endedBy next: ConversationItem) -> Bool {
        guard case .tool(let tool) = item, tool.name == "wait", tool.state != .running else { return false }
        switch next {
        case .subagentResult(_, let activity): return tool.waitedFor == [activity.name]
        case .peerMessage(_, _, _, false): return tool.waitedFor.isEmpty
        default: return false
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .item(.user(let id, let text, let images)): UserBubble(text: text, images: images).modifier(ReportsUserFrame(id: id))
        case .item(.assistant(_, let text)): MarkdownText(text: text)
        case .result(.assistant(_, let text), let turn): TurnResult(text: text, turn: turn, id: id, openedAt: .now)
        case .item(.ask(let ask)): if ask.answer != nil { AnsweredAsk(ask: ask) }
        case .item(.notice(_, let text, let kind)): NoticeRow(text: text, failed: kind == .error)
        case .item(.peerMessage(_, let peer, let text, _)): AgentMessage(title: "From \(peer)", peer: peer, text: text)
        case .answer(.peerMessage(_, let peer, let text, _), let brief): AgentMessage(title: "From \(peer)", peer: peer, text: text, brief: brief)
        case .steps(let items, let run): StepsRow(items: items, run: run)
        case .subagents(_, let activities): SubagentGroupRow(activities: activities)
        case .item(.subagentResult(_, let activity)): SubagentResultRow(activity: activity)
        case .answer(.subagentResult(_, let activity), let brief): SubagentResultRow(activity: activity, brief: brief)
        case .since(let since): CatchUpLine(catchUp: since.catchUp, seen: since.seen)
        case .item, .answer, .result: EmptyView()
        }
    }
}

/// The transcript's own coordinates: a row's place in them changes with layout, not scrolling.
private let transcriptSpace = "transcript"

/// Reports a message's frame in the transcript when its layout changes.
private struct ReportsUserFrame: ViewModifier {
    let id: String
    @Environment(\.userRowFrame) private var report

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(transcriptSpace)) } action: { frame in
            report?((id: id, frame: frame))
        }
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
                // Footnote, the floor for words a decision rests on (round 80: opus#4).
                .font(.footnote)
                .foregroundStyle(Tokens.secondaryText)
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
                        .padding(.horizontal, Tokens.Space.l)
                        .padding(.vertical, Tokens.Space.s)
                        .foregroundStyle(.primary)
                        .background(Tokens.userBubble, in: .rect(cornerRadius: Tokens.Radius.card))
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
    /// The body hangs under the header's words, past its symbol, so it reads as quoted.
    @ScaledMetric(relativeTo: .subheadline) private var inset = 22
    @Environment(\.opensInPlace) private var opensInPlace
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let thread: (() -> Void)? = openSubagent.flatMap { open in (activity ?? subagentNamed?(peer)).map { found in { open(found) } } }
        // At AX sizes the message itself, not a gist that a Show More would open (round 71: sb#10).
        let shown = expanded || typeSize.isAccessibilitySize ? text : gist ?? text
        let opens = expanded || truncated || shown != text || thread != nil || brief != nil
        VStack(alignment: .leading, spacing: 2) {
            QuietHeader(isExpanded: expanded, symbol: "person.2.fill", action: opens ? { expanded.toggle() } : nil) {
                failed ? Text(title).foregroundStyle(.red) : Text(title)
            }
            if !shown.isEmpty {
                // Four lines, then Show More (round 68: sa#1, sb#7, at two a three-line NO-GO
                // stopped at "Fix: deny o…", its one instruction cut; round 69: sb#4, a message
                // just past four still fell back to two). At AX sizes all of it (round 49: sb#10,
                // two lines held three words; round 70: sb#2, six still cut a peer's verdict,
                // and a Show More per message there cost a tap for every line read).
                // Quoted: another agent's words in the transcript's grey on a hairline rule under
                // the header's symbol, evidence apart from this agent's own conclusion in primary
                // (round 80: sa#1, opus#2, findings and the paraphrase of them read at one weight).
                Text(MarkdownText.inline(shown))
                    .font(.subheadline)
                    .foregroundStyle(Tokens.secondaryText)
                    .lineLimit(expanded || typeSize.isAccessibilitySize ? nil : 4)
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
                    .padding(.leading, inset)
                    .background(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 2).padding(.leading, 8)
                    }
                // Cut words say so where they stop, not only by the header's chevron.
                if !expanded, truncated || shown != text {
                    Button("Show More") {
                        opensInPlace?(())
                        expanded = true
                    }
                    .inlineAction()
                    .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.leading, inset)
                    // Named for its message: in the Buttons rotor a row of bare "Show More"s
                    // didn't say whose (round 48: sb#11).
                    .accessibilityLabel("Show More: \(title)")
                    .accessibilityHint("Shows the whole message")
                }
            }
            if expanded, let brief {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Asked").font(.subheadline).foregroundStyle(.secondary)
                    ClampedText(text: brief, font: .subheadline, lines: 6, style: .secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
                .padding(.leading, inset)
            }
            if expanded, let thread {
                Button("Open Thread", action: thread)
                    .inlineAction()
                    .padding(.top, 4)
                    .padding(.leading, inset)
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
    /// What kind of line it is (agents talking, subagents), so it doesn't pass for prose.
    var symbol: String? = nil
    let action: (() -> Void)?
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.opensInPlace) private var opensInPlace
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let line = HStack(spacing: 0) {
            if let symbol { QuietSymbol(name: symbol) }
            // Whole at accessibility sizes, where one line held two words (round 66: sb#3).
            label.font(.subheadline).foregroundStyle(Tokens.secondaryText).lineLimit(typeSize.isAccessibilitySize ? nil : lines)
            Spacer(minLength: 4)
            if let count {
                Text(count, format: .number).font(.footnote).monospacedDigit().foregroundStyle(Tokens.secondaryText)
                    .accessibilityLabel("\(count) steps")
            }
            if action != nil {
                // The steps row's chevron, at the column's end: centred in a 32 pt box it stood
                // 13 pt short of the run lines' (round 65: subagent results' chevrons out of line).
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
                    .frame(width: 32, height: 28, alignment: .trailing)
            }
        }
        .frame(minHeight: 28)
        // Drawn 28 pt tall to keep the transcript dense; it answers taps across 44.
        .contentShape(Rectangle().inset(by: -8))
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

/// What runs after an approval, until the agent writes again: a step line with a spinner, the
/// still working glyph under Reduce Motion (round 21: the card left a card-sized hole).
private struct TailWorkLine: View {
    let label: String
    let reduceMotion: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 0) {
            if reduceMotion {
                QuietSymbol(name: AgentStatus.working.symbol)
            } else {
                ProgressView().controlSize(.small).frame(width: 22, alignment: .leading)
            }
            Text(label).font(.subheadline).foregroundStyle(Tokens.secondaryText)
                // Keep the whole post-approval step visible at AX sizes (round 39: sb#7).
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Tokens.minTap)
        .accessibilityElement(children: .combine)
    }
}

/// What a card's choice did, in the past tense, its mark bouncing once as it lands.
private struct SentPill: View {
    let text: String
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let denied = text == "Denied"
        Label {
            Text(text).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
        } icon: {
            Image(systemName: denied ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(denied ? Tokens.Tint.danger : Color.accentColor)
                .symbolEffect(.bounce, options: .nonRepeating, value: landed)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Tokens.Surface.raised, in: .capsule)
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { landed = true } }
        // `confirm` announces it.
        .accessibilityHidden(true)
    }
}

/// The leading mark of a quiet line: which kind of thing it is, in the column prose doesn't use.
/// Centred on one centre line near the column's start, so a narrow hourglass and a wide pair of
/// people sit on the same axis with the same gap to their words (round 89: opus#7, set flush
/// left, wide glyphs nearly touched the label and the hourglass left a hole).
struct QuietSymbol: View {
    let name: String
    var tint: Color? = nil
    @ScaledMetric(relativeTo: .subheadline) private var width = 22
    @ScaledMetric(relativeTo: .subheadline) private var glyph = 16

    var body: some View {
        Image(systemName: name)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint ?? Tokens.secondaryText)
            .frame(width: glyph, alignment: .center)
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Result prose keeps paragraph and list groups apart; bold lead-ins become inset callouts.
private struct ResultBody: View {
    let text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A last paragraph that is a warning callout, apart from the rest, so the card can set it
    /// before the verdict (round 39: sa#12, sb#2, "Before deploying" came after every bullet;
    /// round 49: sa#1, sb#4). Only a final top-level block moves; nothing else is reordered.
    /// Only its first sentence, the thing to do, as the inbox's caution: what follows stays at
    /// the end of the body as plain prose (round 55: sa#1, sb#5, "I left the working tree
    /// unchanged" took the warning's rule and, at accessibility sizes, lines before the verdict).
    func splitFinalWarning() -> (warning: String?, body: String) {
        guard let last = paragraphs.last, TranscriptActivity.isWarningCallout(last) else { return (nil, text) }
        var rest = Array(paragraphs.dropLast())
        var warning = last
        if !last.contains("\n"), let end = last.firstMatch(of: /\.\s+(?=[A-Z])/) {
            warning = String(last[..<end.range.lowerBound]) + "."
            rest.append(String(last[end.range.upperBound...]))
        }
        return (warning, rest.joined(separator: "\n\n"))
    }

    /// A short last paragraph of plain prose straight after a list: the agent's closing remark
    /// on its findings, set apart by the card (round 85: sa#1). Anything else stays in the body,
    /// as does a remark holding something to act on: a link, code or a path, or a question
    /// (round 86: opus#6, "Ready for a quick browser check at https://…" went grey).
    func splitClosingNote() -> (body: String, note: String?) {
        guard paragraphs.count >= 2, let last = paragraphs.last, !last.contains("\n"), last.count <= 140,
              last.first?.isLetter == true, !last.hasSuffix("?"), !last.contains("`"),
              last.firstMatch(of: /:\/\/|www\.|\w\/\w/) == nil else { return (text, nil) }
        let list = paragraphs[paragraphs.count - 2].split(separator: "\n")
        guard !list.isEmpty, list.allSatisfy({ $0.firstMatch(of: /^\s*([-*•]|\d+[.)])\s/) != nil }) else { return (text, nil) }
        return (paragraphs.dropLast().joined(separator: "\n\n"), last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if paragraph.firstMatch(of: /^\*\*([^*]+):\*\*/) != nil {
                    let warning = TranscriptActivity.isWarningCallout(paragraph)
                    let glyph = Image(systemName: warning ? "exclamationmark.triangle" : "arrow.right.circle")
                    let tint = warning ? Tokens.Tint.caution : Tokens.secondaryText
                    let large = typeSize.isAccessibilitySize
                    Group {
                        if large || !paragraph.contains("\n") {
                            // The tinted rule and the semibold lead carry it, the words wrapping
                            // on one edge inside the rule, VoiceOver saying "Warning": a glyph in a gutter
                            // cost a word a line at accessibility sizes (round 40: sa#2, sb#6) and
                            // set the caution deeper than the verdict (round 51: sa#7); inline,
                            // beside the rule, it gave the first line a fussy indent (round 53:
                            // sa#14) and split "Before deploying" at accessibility sizes (round
                            // 52: sa#6). Never a line of its own (round 42: sa#1, sb#1, opus#1,
                            // the caution's end fell into the fade). A callout holding a list
                            // keeps the gutter, so its items stay set as Markdown.
                            let words = (try? AttributedString(markdown: paragraph, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                ?? AttributedString(paragraph)
                            Text(words).accessibilityLabel(warning ? Text("Warning, \(words)") : Text(words))
                        } else {
                            HStack(alignment: .top, spacing: Tokens.Space.s) {
                                glyph.foregroundStyle(tint)
                                MarkdownText(text: paragraph)
                            }
                        }
                    }
                    // A rule in its tint down the leading edge, not an inset plate: a grey slab
                    // inside the grey card read as assembled, not designed (round 50: sa#2;
                    // round 48: sa#9, nested plates in the light). At accessibility sizes too,
                    // closer (round 51: opus#9, there the caution was a glyph alone); a plate's
                    // 12 pt each side had cost it lines there (round 45: sa#3, sb#8).
                    .padding(.leading, large ? Tokens.Space.s : Tokens.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Capsule().fill(warning ? tint : Color.secondary.opacity(0.4)).frame(width: 3)
                    }
                } else {
                    MarkdownText(text: paragraph)
                }
            }
        }
    }
}

/// The reply that ended a turn, on a raised card signed by the sheep, "Done · 9:12" and
/// "Took 2m 5s" beside it:
/// the outcome stands apart from the narration before it (round 7: behind a rule it still read as
/// one more paragraph), and the reader sees when the agent stopped. "Took" is time since the
/// user's message, or since their approval or answer when the turn waited on one ("Took 12s
/// after you approved"; round 15: "Took 45m 47s" under "You approved · 7:54" counted the wait
/// for the user as the agent's work). Only transcript-stamped times; the words are the agent's.
private struct TurnResult: View {
    let text: String
    let turn: FinishedTurn
    /// The user's approval or answer during the turn ("approved", "answered"), if any.
    var resumed: (at: Date, word: String)? = nil
    let id: String
    /// When the thread was opened; rows painted with it are history, not a finish.
    let openedAt: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Turns whose seal has been signed this launch, so scrolling back or reopening the thread
    /// shows it still (round 15: the end of a turn had no moment of its own).
    @MainActor private static var signed: Set<String> = []
    /// A turn that ended in the last 20 s and arrived after the thread had opened and painted:
    /// it just finished in front of the reader. Not when opening a thread that already holds it.
    private var fresh: Bool {
        guard let at = turn.at, !Self.signed.contains(id) else { return false }
        let now = Date.now
        return now.timeIntervalSince(openedAt) > 1 && now.timeIntervalSince(at) < 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            // At accessibility sizes no header: the caution or verdict leads and "Done" opens the
            // time line (round 42: sa#1, sb#1, opus#1: the seal and "Done" took the lines the
            // caution's end needed above the fade; the nav subtitle already says Done).
            if !typeSize.isAccessibilitySize {
                header
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(caption(spoken: true))
                    .accessibilityAddTraits(.isHeader)
            }
            if let verdict = Self.verdict(text) {
                let large = typeSize.isAccessibilitySize
                // The caution comes before the verdict at every size (round 44: sa#1, sb#1, at
                // accessibility sizes, under a three-line verdict its end fell into the fade;
                // round 49: sa#1, sb#4, at regular sizes "No blocking findings" still spoke first,
                // two orders for one result), and before the timing there (round 40: sa#2, sb#6).
                let body = ResultBody(text: verdict.rest).splitFinalWarning()
                // At accessibility sizes, with no header above it, it is the first heading, so
                // heading navigation can't land past it on the reassuring verdict (round 45: sb#1).
                if let warning = body.warning {
                    ResultBody(text: warning)
                        .accessibilityElement(children: large ? .combine : .contain)
                        .accessibilityAddTraits(large ? .isHeader : [])
                }
                // The agent's own opening line, set as the outcome; the words are unchanged. At
                // accessibility sizes body-sized, its weight setting it apart (round 41: sa#3,
                // sb#15, a title-sized verdict pushed the caution into the fade).
                MarkdownText(text: verdict.lead).font(large ? .body.weight(.semibold) : .title3.weight(.semibold))
                    .padding(.bottom, Tokens.Space.s)
                    // Headings navigation still lands on the card with no header above it.
                    .accessibilityAddTraits(large ? .isHeader : [])
                // A closing remark after the findings ("I left the working tree unchanged") as a
                // quieter postscript, so the card ends on its findings rather than one more line
                // at their weight (round 85: sa#1, the plate read as one undifferentiated block).
                let closing = ResultBody(text: body.body).splitClosingNote()
                ResultBody(text: closing.body)
                if let note = closing.note {
                    Text((try? AttributedString(markdown: note)) ?? AttributedString(note))
                        // A step smaller at accessibility sizes, where the end matter took a
                        // screen's quarter (round 86: sb#8).
                        .font(large ? .footnote : .subheadline)
                        .foregroundStyle(Tokens.secondaryText)
                }
                // At accessibility sizes, with no header, the timing closes the card: between
                // the verdict and its findings it broke the reading for two large lines (round
                // 56: opus#4, sa#7); in caption there, as bookkeeping (round 86: sb#8).
                if large, let timing {
                    Text(timing).font(.caption).foregroundStyle(Tokens.secondaryText)
                }
            } else {
                // No verdict to lead: the time line does, standing for the header.
                if typeSize.isAccessibilitySize, let timing {
                    Text(timing).font(.footnote).foregroundStyle(Tokens.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                }
                ResultBody(text: text)
            }
        }
        // At accessibility sizes a narrower inset, so a line holds more than two or three of
        // the large words (round 87: opus#8, sa#7, at 16 pt a finding wrapped every 15 characters).
        .padding(typeSize.isAccessibilitySize ? Tokens.Space.m : Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
        .padding(.top, Tokens.Space.s)
        .onAppear { Self.signed.insert(id) }
    }

    /// The seal and "Done · 9:12 · took 2m 5s" on one quiet line; VoiceOver hears it as one
    /// header. Short of room, the timing goes under "Done" (round 60: sa#3, "Done · 9:12" over
    /// "Took 2m 5s" beside a 32 pt seal gave bookkeeping three lines' weight above the verdict).
    /// At accessibility sizes there's no header: any closing caution leads, then the verdict, the
    /// time line, then the body (round 20: the clock and duration displaced the verdict; round
    /// 38: after the whole body it was a scroll away; round 42: the header itself cost the
    /// caution; round 44: the verdict's three lines did).
    private var header: some View {
        let done = Text("Done").fontWeight(.semibold).foregroundStyle(.primary)
        let clockText = Text(clock.map { " · \($0)" } ?? "").foregroundStyle(Tokens.secondaryText)
        return HStack(alignment: .center, spacing: Tokens.Space.s) {
            HerdSeal(size: 28, play: fresh)
            ViewThatFits(in: .horizontal) {
                Text("\(done)\(clockText)\(Text(timing.map { " · \($0.lowercased())" } ?? "").foregroundStyle(Tokens.secondaryText))")
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(done)\(clockText)")
                    if let timing {
                        Text(timing).font(.footnote).foregroundStyle(Tokens.secondaryText)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    /// The line under "Done": "Took 2m 5s", or at accessibility sizes, where it stands for the
    /// header, "Done · 9:12 · took 2m 5s".
    private var timing: String? {
        let took = took(width: .narrow)
        guard typeSize.isAccessibilitySize else { return took }
        return (["Done", clock, took?.lowercased()].compactMap { $0 }).joined(separator: " · ")
    }

    private var clock: String? { turn.at?.transcriptStamp }

    /// "Took 12s after you approved" or "Took 2m 5s"; nil under a second or without both ends.
    private func took(width: Duration.UnitsFormatStyle.UnitWidth) -> String? {
        func format(_ seconds: TimeInterval) -> String {
            Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds],
                                                                 width: width, maximumUnitCount: 2))
        }
        if let resumed, let at = turn.at {
            let seconds = at.timeIntervalSince(resumed.at)
            return seconds >= 1 ? "Took \(format(seconds)) after you \(resumed.word)" : nil
        }
        return turn.duration.map { width == .wide ? "Took \(format($0)) since your message" : "Took \(format($0))" }
    }

    /// A short first paragraph of plain prose with more after it reads as the reply's verdict
    /// ("No blocking findings in PR #412."), so it leads in semibold (round 9: verdict, reasons
    /// and caveat sat at one weight, and the reader had to take in the whole card to find the
    /// outcome). Anything else (a list, a heading, a long opening) is left as written.
    static func verdict(_ text: String) -> (lead: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.range(of: "\n\n") else { return nil }
        let lead = String(trimmed[..<split.lowerBound])
        let rest = trimmed[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, lead.count <= 140, !lead.contains("\n"), let first = lead.first,
              first.isLetter || first.isNumber,
              lead.firstMatch(of: /^\d+[.)]\s/) == nil else { return nil }
        return (lead, rest)
    }

    private func caption(spoken: Bool) -> Text {
        let parts = [["Done", clock].compactMap { $0 }.joined(separator: " "),
                     took(width: spoken ? .wide : .narrow)?.lowercased()].compactMap { $0 }
        return Text(parts.joined(separator: spoken ? ", " : " · "))
    }
}

/// `DisclosureGroup` with a `QuietHeader`: the stock chevron is heavy and primary-coloured.
struct QuietDisclosure: DisclosureGroupStyle {
    var lines = 1
    var count: Int? = nil
    var symbol: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietHeader(isExpanded: configuration.isExpanded, lines: lines, count: count, symbol: symbol, action: {
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
        HStack(spacing: Tokens.Space.m) {
            if failed { Rectangle().fill(Tokens.Tint.danger).frame(width: 3) }
            ClampedText(text: text, font: .subheadline, lines: 2)
                .foregroundStyle(failed ? AnyShapeStyle(Tokens.Tint.danger) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A question the agent asked and what was answered, in the steps' quiet voice.
private struct AnsweredAsk: View {
    let ask: AskActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ask.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.question).font(.subheadline.weight(.semibold))
                    if let answer = ask.answer, !answer.cancelled {
                        Text(Self.reply(to: question, in: answer)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if ask.answer?.cancelled == true { Text("Dismissed").foregroundStyle(.secondary) }
        }
        .padding(.leading, Tokens.Space.m)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// This question's own answer, its choices as a list ("A and B"); older records only carry
    /// the combined list. The Decisions rotor says it the same way.
    static func reply(to question: AskQuestion, in answer: AskAnswer) -> String {
        let values = answer.perQuestion[question.question] ?? answer.selected + [answer.custom].compactMap { $0 }
        let note = answer.perQuestionNotes[question.question] ?? (answer.perQuestion.isEmpty ? answer.note : nil)
        return values.formatted(.list(type: .and)) + (note.map { " — Note: \($0)" } ?? "")
    }
}

/// Tool calls, thinking and briefs between two messages, folded to one line until opened.
/// The line leads with a failure, then says what's running, or else what the run did.
private struct StepsRow: View {
    let items: [ConversationItem]
    let run: StepRun
    @State private var expanded = false
    @Environment(\.findTarget) private var findTarget
    @Environment(\.opensInPlace) private var opensInPlace
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Button {
                opensInPlace?(())
                expanded.toggle()
            } label: {
                // No step count beside it: the line already says what the run did, and VoiceOver reads the count.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    QuietSymbol(name: run.failure == nil ? symbol : "exclamationmark.triangle.fill",
                                tint: run.failure != nil ? Tokens.Tint.danger
                                    : run.running != nil ? AgentStatus.working.tint
                                    : run.tests != nil ? Tokens.Tint.settled : Tokens.secondaryText)
                    labelView.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, Tokens.Space.s)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                // The quiet lines' size (`QuietHeader`): at footnote a run read as disabled. Their
                // height too, 28 pt drawn and 44 answering taps: at 44 drawn a run stood further
                // from its neighbours than a subagent's line did (round 67: opus#1, sa#2, the
                // machinery's uneven gaps broke the transcript's rhythm).
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 28)
                .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(run.steps) \(run.steps == 1 ? "step" : "steps"): \(spoken)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(items) { item in StepLine(item: item, opens: items.count == 1).id(item.id) }
                }
            }
        }
        // Find opens the run holding its match (a brief sent from inside it).
        .onChange(of: findTarget, initial: true) { _, target in
            if let target, items.contains(where: { $0.id == target }) { expanded = true }
        }
    }

    /// The run's kind when every call shared one (round 14: one wrench for commands, reads and
    /// waits alike made the evidence trail hard to scan); a mixed run keeps the wrench.
    private var symbol: String {
        switch run.sole {
        case .kind(.command): "apple.terminal"
        case .kind(.read): "doc.text"
        case .kind(.edit): "pencil"
        case .kind(.search): "magnifyingglass"
        case .wait: "hourglass"
        case .kind(.other), nil: "wrench.and.screwdriver"
        }
    }

    /// The failure first, then a test run's totals, then the rest, which StepRun keeps to counts
    /// beside an outcome (round 20: "142 passed · Read 0042_backfill…" read as one confused
    /// sentence and truncated mid-filename).
    private var label: Text {
        let rest = run.running.map { "\($0)…" } ?? run.label
        var words = Text(rest)
        if run.running == nil, let tests = run.tests {
            // Beside an outcome the rest is counts ("2 edits"); each stays on one line.
            let counts = rest.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "\u{00A0}·\u{00A0}", with: " · ")
            words = rest.isEmpty ? tests.token : Text("\(tests.token) · \(counts)")
        }
        guard let failure = run.failure else { return words }
        let failed = Text(failure).foregroundStyle(.red)
        return rest.isEmpty && run.tests == nil ? failed : Text("\(failed) · \(words)")
    }

    /// A test outcome followed by counts, which wrap rather than truncate.
    private var countsOnly: Bool { run.running == nil && run.tests != nil && !run.label.isEmpty }

    /// A finished test run without a failure: the outcome on its line, any counts in footnote
    /// under it (round 45: sa#4, "38 tests passed · 2 edits · 1 command · 1 read · 2 images"
    /// wrapped as one even grey slab, an activity log rather than a result).
    @ViewBuilder private var labelView: some View {
        if run.running == nil, run.failure == nil, let tests = run.tests {
            VStack(alignment: .leading, spacing: 2) {
                // The outcome in primary, the counts under it grey (round 46: sa#7, both grey,
                // the total didn't win the line).
                tests.token.foregroundStyle(Color.primary).fontWeight(.medium)
                if !run.label.isEmpty {
                    // Each count whole, wrapping between them (round 24: "1 re…" cut a noun).
                    Text(run.label.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "\u{00A0}·\u{00A0}", with: " · "))
                        .font(.footnote)
                }
            }
            .foregroundStyle(Tokens.secondaryText)
        } else {
            label.foregroundStyle(Tokens.secondaryText)
                // One line, like the other quiet lines: a command wrapped mid-path pushed the prose
                // apart (round 10). A failure keeps a second line, as do a test outcome's counts,
                // which wrap whole (round 24: "1 re…" and "2 i…" cut the noun off a count); opening
                // it shows every step whole.
                .lineLimit(typeSize.isAccessibilitySize ? nil : run.failure == nil && !countsOnly ? 1 : 2)
        }
    }

    /// What the line shows, in its order (round 9: a failure went unspoken).
    private var spoken: String {
        let tests = run.running == nil ? run.tests.map { "tests: \($0.summary)" } : nil
        return [run.failure, tests, run.running ?? run.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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
/// It hugs its words with the chevron right after them, so it reads as one tappable status and
/// leaves the row's end to the agent dock (a run line's chevron, out at the column's edge, would
/// hang short of the dock); the inbox's working ring, turning slowly, marks the Now line (round
/// 15: an anonymous dot; round 48: sa#9, a sheep here beside the dock's read as two of one
/// button), and holds still under Reduce Motion.
private struct PinnedLine: View {
    let label: Text
    var live = false
    var symbol: String? = nil
    var tint: Color = .secondary
    /// The next thing to do, not a status: a glass capsule beside the mic and the dock, in
    /// primary text, so it doesn't read as one more quiet run line.
    var prominent = false
    /// Shorter forms, longest first, for when the label doesn't fit whole on one line: drop
    /// detail rather than cut a word of it (round 7: "Next: Deploy to staging · w…").
    var shorter: [Text] = []
    /// Before the last, shortest form: a title over its detail in caption, so the detail
    /// survives a narrow row (round 8: the workspace was the first thing dropped).
    var stacked: (title: Text, detail: Text)? = nil
    /// How far the label may wrap at accessibility sizes, where the field's line is full width.
    var accessibilityLines = 3
    let action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let line = HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            } else if live {
                Image(systemName: AgentStatus.working.symbol)
                    .foregroundStyle(AgentStatus.working.tint)
                    .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.25), isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            // At accessibility sizes the full-width field's line has room to wrap instead of cut.
            if shorter.isEmpty || typeSize.isAccessibilitySize {
                styled(label)
            } else {
                ViewThatFits(in: .horizontal) {
                    styled(label)
                    ForEach(shorter.indices.dropLast(), id: \.self) { styled(shorter[$0]) }
                    if let stacked {
                        VStack(alignment: .leading, spacing: 0) {
                            styled(stacked.title)
                            // The app's secondary grey, Increase Contrast included (round 17: system grey caption read as faint).
                            stacked.detail.font(.footnote).foregroundStyle(Tokens.secondaryText).lineLimit(1)
                        }
                    }
                    if let last = shorter.last { styled(last) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
            }
            if action != nil {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Tokens.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, prominent ? 0 : 4)
        if prominent, let action {
            Button(action: action) { line }
                .floatingControl()
                // The capsule is drawn button-height; it answers taps across the whole slot.
                .frame(minHeight: Tokens.minTap)
                .contentShape(.rect)
        } else if let action {
            // It rides a slot a button tall; it answers taps across all of it.
            Button(action: action) { line.frame(minHeight: Tokens.minTap).contentShape(.rect) }.buttonStyle(.plain)
        } else {
            line.frame(minHeight: Tokens.minTap)
        }
    }

    /// The app's secondary grey, Increase Contrast included, for the whole quiet line (round 18:
    /// in the system's grey the live step read as disabled).
    private func styled(_ text: Text) -> some View {
        text.font(prominent ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(prominent ? Color.primary : Tokens.secondaryText)
            .lineLimit(typeSize.isAccessibilitySize ? accessibilityLines : 1)
            .multilineTextAlignment(.leading)
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
    /// Where each of the reader's messages sits in the transcript (`transcriptSpace`), for
    /// opening on a turn whole.
    @Entry var userRowFrame: EnvironmentAction<(id: String, frame: CGRect), Void>? = nil
}

/// Where the reader left off: "New since 9:41 · 3 edits · 2 replies · 1 failure" between accent
/// hairlines, "New" in the accent, before the first item they haven't seen (round 8: grey on
/// grey hairlines, the boundary passed unnoticed in a scroll).
struct CatchUpLine: View {
    nonisolated static let id = "since-last-look"
    let catchUp: CatchUp
    let seen: Date
    @Environment(\.reachedCatchUp) private var reached
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                // One line between the rules when it fits, else stacked (round 14: the fixed
                // line had no way to wrap).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s) {
                        Rectangle().fill(Color.accentColor.opacity(0.6)).frame(minWidth: 12, maxHeight: 1)
                        Self.summary(catchUp, since: seen).font(.footnote).foregroundStyle(Tokens.secondaryText)
                            .fixedSize()
                        Rectangle().fill(Color.accentColor.opacity(0.6)).frame(minWidth: 12, maxHeight: 1)
                    }
                    .frame(minHeight: Tokens.minTap)
                    stacked
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(catchUp, since: seen))
        .onScrollVisibilityChange { visible in if visible { reached?(()) } }
    }

    /// "New since 9:41" over the counts, wrapping, with no rules, at accessibility sizes and
    /// wherever the one line doesn't fit.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New since \(time)")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
            Self.details(catchUp).font(.footnote).foregroundStyle(Tokens.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Space.s)
    }

    private var time: String { seen.transcriptStamp }
    private static func details(_ catchUp: CatchUp) -> Text {
        let counts = [(catchUp.edits, "edit", "edits"), (catchUp.replies, "reply", "replies"), (catchUp.images, "image", "images")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        let rest = counts.isEmpty ? "No changes" : counts.joined(separator: " · ")
        guard catchUp.failures > 0 else { return Text(rest) }
        return Text("\(rest) · \(Text(catchUp.failures == 1 ? "1 error" : "\(catchUp.failures) errors").foregroundStyle(.red))")
    }


    static func summary(_ catchUp: CatchUp, since seen: Date) -> Text {
        let time = seen.transcriptStamp
        let counts = [(catchUp.edits, "edit", "edits"), (catchUp.replies, "reply", "replies"), (catchUp.images, "image", "images")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        let rest = (["since \(time)"] + counts).joined(separator: " · ")
        let lead = Text("\(Text("New").fontWeight(.semibold).foregroundStyle(Color.accentColor)) \(rest)")
        guard catchUp.failures > 0 else { return lead }
        let failures = Text(catchUp.failures == 1 ? "1 error" : "\(catchUp.failures) errors").foregroundStyle(.red)
        return Text("\(lead) · \(failures)")
    }
}

// MARK: - Asks

/// Ordinary choices send in one tap. Opening the editor makes submission explicit without
/// confusing a replacement answer with an additional note.
private struct AskPanel: View {
    let ask: AskActivity
    let omp: Bool
    let drivable: Bool
    let answering: Bool
    let paneID: String
    let terminalAddress: PaneAddress
    let onSubmit: ([QuestionReply]) -> Void

    private enum TextMode: String { case other = "Other", note = "Note" }
    @State private var page = 0
    @State private var replies: [QuestionReply]
    @State private var others: [String]
    @State private var notes: [String]
    @State private var usesOther: [Bool]
    @State private var modes: [TextMode?]
    @State private var customised = false
    /// The choice a one-tap send came from, for its progress indicator. Repeated taps are
    /// harmless: `answer` refuses to start while another answer is being driven.
    @State private var tapped: String?
    @FocusState private var editorFocused: Bool
    @Environment(SceneState.self) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize

    init(ask: AskActivity, omp: Bool, drivable: Bool, answering: Bool, paneID: String, terminalAddress: PaneAddress,
         onSubmit: @escaping ([QuestionReply]) -> Void) {
        self.ask = ask; self.omp = omp; self.drivable = drivable; self.answering = answering; self.paneID = paneID
        self.terminalAddress = terminalAddress; self.onSubmit = onSubmit
        let count = ask.questions.count
        _replies = State(initialValue: ask.questions.map { _ in QuestionReply() })
        _others = State(initialValue: Array(repeating: "", count: count))
        _notes = State(initialValue: Array(repeating: "", count: count))
        _usesOther = State(initialValue: Array(repeating: false, count: count))
        _modes = State(initialValue: Array(repeating: nil, count: count))
    }

    var body: some View {
        CappedScroll(maxHeight: 420) {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            if answerable, ask.questions.indices.contains(page) {
                let question = ask.questions[page]
                header(question)
                // In the inbox row's semibold, the question the card is about (round 72: sa#5,
                // in body regular it read weaker than the same question in the inbox), after
                // Needs You's glyph, as the approval card's title has it (round 75: opus#10, the
                // two waiting cards didn't look like the same kind of thing).
                Label {
                    MarkdownText(text: question.question).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: AgentStatus.blocked.symbol).foregroundStyle(AgentStatus.blocked.tint)
                        .accessibilityHidden(true)
                }
                if question.multi { Text("Choose any").font(.footnote).foregroundStyle(Tokens.secondaryText) }
                options(question)
                if modes[page] != nil { editor(question) }
                let other = modes[page] == nil && (!question.multi || omp)
                if oneTap(question) {
                    // The card's two ways out side by side, each with its glyph, when they fit
                    // (round 89: opus#11, stacked with different leading, one with an icon and
                    // one without, they read as stray links rather than the card's actions).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.xl) {
                            if other { otherAnswer }
                            terminalLink.disabled(locked)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if other { otherAnswer }
                            terminalLink.disabled(locked)
                        }
                    }
                } else {
                    if other { otherAnswer }
                    footer
                    terminalLink.disabled(locked)
                }
            } else {
                if let question = ask.questions.first { Text(question.question).font(.headline) }
                terminalLink
            }
        }
        }
        // Not disabled as a whole: that greys the option saying what's under way; the rest are,
        // so VoiceOver doesn't offer them while the answer is taken (round 75: sb#1).
        .allowsHitTesting(!locked)
        .onChange(of: answering) { _, active in
            if !active { tapped = nil }
        }
        .task(id: scene.writeAnswer) { await takeWriteAnswer() }
    }

    /// The inbox's Write Your Own Answer for this agent: the editor opens as the thread does,
    /// focused once the push has settled.
    private func takeWriteAnswer() async {
        guard scene.writeAnswer == terminalAddress, answerable, ask.questions.indices.contains(page) else { return }
        customised = true
        modes[page] = .other
        try? await Task.sleep(for: .milliseconds(450))
        editorFocused = true
        // Last: clearing it changes this task's id, which cancels the task.
        scene.writeAnswer = nil
    }

    private var locked: Bool { answering }
    private var answerable: Bool {
        drivable && !ask.questions.isEmpty && ask.questions.allSatisfy { !$0.options.isEmpty }
    }
    private var isLastPage: Bool { page == ask.questions.count - 1 }
    private func oneTap(_ question: AskQuestion) -> Bool { ask.questions.count == 1 && !question.multi && !customised }
    private var custom: String { usesOther[page] ? others[page].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
    private var canAdvance: Bool { !custom.isEmpty || !replies[page].selected.isEmpty }
    private var terminalLink: some View {
        NavigationLink(value: Route.terminal(terminalAddress)) {
            Label("Answer in Terminal", systemImage: "apple.terminal").frame(minHeight: Tokens.minTap)
        }
        .inlineAction()
    }
    /// Opens the field for an answer of one's own, with the pencil the terminal link's glyph
    /// pairs with (round 89: opus#11).
    private var otherAnswer: some View {
        Button {
            customised = true
            modes[page] = .other
            editorFocused = true
        } label: {
            Label("Other Answer…", systemImage: "square.and.pencil").frame(minHeight: Tokens.minTap)
        }
        .inlineAction()
        .accessibilityHint("Opens a field to type an answer instead of choosing one.")
        .disabled(locked)
    }

    @ViewBuilder private func header(_ question: AskQuestion) -> some View {
        let title = [question.header, ask.questions.count > 1 ? "\(page + 1) of \(ask.questions.count)" : nil]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        if !title.isEmpty { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
    }

    private func options(_ question: AskQuestion) -> some View {
        VStack(spacing: Tokens.Space.s) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionRow(option, in: question, recommended: question.recommended == index, shortcut: locked ? nil : index)
                    .numberedShortcut(locked ? nil : index)
                    .disabled(locked && tapped != option.label)
            }
        }
    }
    /// The recommended choice of a one-tap ask carries the composer's send arrow, as the inbox's
    /// does: a tap sends it (round 49: sa#2, outlined here it read as an informational inset).
    /// In a column of its own, or at accessibility sizes inline before the label.
    private func sendsOnTap(_ question: AskQuestion, recommended: Bool, label: String) -> Bool {
        recommended && oneTap(question) && !(locked && tapped == label)
    }
    private func optionRow(_ option: AskOption, in question: AskQuestion, recommended: Bool, shortcut: Int?) -> some View {
        let chosen = (question.multi || !usesOther[page]) && replies[page].selected.contains(option.label)
        return Button { pick(option.label, in: question) } label: {
            // The send arrow in a column of its own, centred on the tile, its ⌘ key under it, as
            // the inbox's is (round 88: opus#1, sa#3, here the key still sat in the top corner).
            let arrow = sendsOnTap(question, recommended: recommended, label: option.label) && !typeSize.isAccessibilitySize
            HStack(alignment: .center, spacing: Tokens.Space.m) {
                optionContent(option, in: question, recommended: recommended, shortcut: arrow ? nil : shortcut, chosen: chosen)
                if arrow {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        ShortcutHint(shortcut)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, Tokens.Space.xs)
            .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
            .contentShape(.rect)
        }
        .choiceButton(recommended: recommended)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        // What's on the button, all of it: the explanation and preview are part of the choice,
        // and so is "Recommended", in the label as the inbox's options say it (round 12: only a
        // hint, lost with hints off). A one-tap answer sends as it's chosen, so its label ends
        // "Sends now" and its hint says where (round 53: sb#1, with hints off it sounded like
        // one more option; round 52: sb#1, it had no hint).
        .accessibilityLabel(locked && tapped == option.label ? "Answering…"
            : [option.label, recommended ? "Recommended" : nil, option.description, option.preview.map { "Preview: \($0)" },
               oneTap(question) && !locked ? "Sends now" : nil]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ". "))
        .accessibilityHint(oneTap(question) && !locked ? "Answers “\(option.label)” on the agent's screen." : "")
        // The chosen one, while it's taken, is progress rather than a button (round 76: sb#2).
        .accessibilityRemoveTraits(locked && tapped == option.label ? .isButton : [])
        .accessibilityAddTraits(locked && tapped == option.label ? .updatesFrequently : [])
    }

    /// The option's mark, "Recommended", label, explanation and preview, and its ⌘ hint.
    private func optionContent(_ option: AskOption, in question: AskQuestion, recommended: Bool, shortcut: Int?, chosen: Bool) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            if question.multi {
                Image(systemName: chosen ? "checkmark.square.fill" : "square")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
            } else if !oneTap(question) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                // Said, not only tinted: a lone tinted option read as already chosen (round 10).
                if recommended, !(locked && tapped == option.label) {
                    Text("Recommended").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                let label = locked && tapped == option.label ? AttributedString("Answering…") : MarkdownText.inline(option.label)
                Group {
                    if sendsOnTap(question, recommended: recommended, label: option.label), typeSize.isAccessibilitySize {
                        Text("\(Text(Image(systemName: "arrow.up.circle.fill")).foregroundStyle(Color.accentColor)) \(Text(label))")
                    } else {
                        Text(label)
                    }
                }
                .font(.body.weight(.medium))
                if let description = option.description, !description.isEmpty {
                    MarkdownText(text: description).font(.subheadline).foregroundStyle(Tokens.secondaryText)
                }
                if let preview = option.preview, !preview.isEmpty {
                    Text(preview).font(.subheadline.monospaced()).foregroundStyle(Tokens.secondaryText)
                        .padding(Tokens.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Surface.inset, in: .rect(cornerRadius: Tokens.Radius.plate))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if locked && tapped == option.label { ProgressView() }
            ShortcutHint(shortcut)
        }
    }

    private func editor(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            if omp {
                Picker("Text mode", selection: Binding(get: { modes[page] ?? .other }, set: {
                    modes[page] = $0
                    if $0 == .other { usesOther[page] = !others[page].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                })) {
                    Text("Other").tag(TextMode.other)
                    Text("Note").tag(TextMode.note)
                }
                .pickerStyle(.segmented)
            } else {
                Text("Other").font(.subheadline.weight(.medium))
            }
            TextField(modes[page] == .note ? "Add a note" : "Other answer", text: Binding(
                get: { modes[page] == .note ? notes[page] : others[page] },
                set: {
                    if modes[page] == .note { notes[page] = $0 }
                    else { others[page] = $0; usesOther[page] = true }
                }), axis: .vertical)
                .lineLimit(1...4)
                .focused($editorFocused)
                .padding(Tokens.Space.m)
                .background(Tokens.Surface.inset, in: .rect(cornerRadius: Tokens.Radius.plate))
            if usesOther[page], !others[page].isEmpty, modes[page] == .note {
                Text("Other: \(others[page])").font(.footnote).foregroundStyle(Tokens.secondaryText)
            }
            if modes[page] == .other, !notes[page].isEmpty {
                Text("Note: \(notes[page])").font(.footnote).foregroundStyle(Tokens.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("Back") { commit(); page -= 1; editorFocused = false }
                    .floatingControl()
            }
            Spacer()
            Button(action: advance) {
                if locked { ProgressView() } else { Text(isLastPage ? "Send" : "Next") }
            }
            .primaryAction()
            .disabled(!canAdvance)
        }
    }

    private func pick(_ label: String, in question: AskQuestion) {
        guard !locked else { return }
        if question.multi {
            if let index = replies[page].selected.firstIndex(of: label) { replies[page].selected.remove(at: index) }
            else { replies[page].selected.append(label) }
        } else {
            usesOther[page] = false
            replies[page].selected = [label]
        }
        if oneTap(question) { tapped = label; advance() }
    }

    private func commit() {
        replies[page].custom = custom.isEmpty ? nil : custom
        if !ask.questions[page].multi, !custom.isEmpty { replies[page].selected = [] }
        let note = notes[page].trimmingCharacters(in: .whitespacesAndNewlines)
        replies[page].note = omp && !note.isEmpty ? note : nil
    }

    private func advance() {
        guard !locked, canAdvance else { return }
        commit()
        editorFocused = false
        if isLastPage {
            onSubmit(replies)
        } else {
            page += 1
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
                .inlineAction()
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
    /// A lasting grant waiting on its confirmation.
    @State private var confirmingScope: String?

    var body: some View {
        CappedScroll(maxHeight: 420) {
        VStack(alignment: .leading, spacing: 10) {
            // No "Waiting for approval" caption: the run line just above says it, and the
            // title's glyph and colour are Needs You's.
            Label(prompt.title, systemImage: AgentStatus.blocked.symbol)
                .font(.headline).foregroundStyle(AgentStatus.blocked.tint)
            if !prompt.context.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    CappedScroll(maxHeight: 180) { contextText }
                    .padding(Tokens.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Surface.inset, in: .rect(cornerRadius: Tokens.Radius.plate))
                    // On its own line under what it qualifies (round 18: caveat and link shared
                    // one small line), with the way to the whole command right under it, before
                    // the answers (round 23: below Approve and the session grant, it invited a
                    // decision before a look).
                    if prompt.contextMayBeTruncated {
                        ScreenReadCaveat()
                        terminalLink
                    }
                }
            }
            optionChoices
            // The terminal also answers what the card can't: "Answer in Terminal", one link
            // either way (round 14 capture: a second link repeated it).
            if !shortened { terminalLink }
        }
        }
    }

    private var terminalLink: some View {
        NavigationLink(value: Route.terminal(terminalAddress)) {
            // "Inspect", not "Full Command": the terminal shows what the screen shows, which
            // may be cut too (round 25: "Full Command" read as a promise of completeness).
            Label(shortened ? "Inspect in Terminal" : "Answer in Terminal", systemImage: "apple.terminal")
                .frame(minHeight: Tokens.minTap)
        }
        .inlineAction().disabled(choosing != nil)
    }

    private var shortened: Bool { !prompt.context.isEmpty && prompt.contextMayBeTruncated }

    /// The harness's own "Command:" label repeats what the plate already is.
    private var contextText: some View {
        var lines = prompt.context
        if let first = lines.first, first.hasPrefix("Command: ") { lines[0] = String(first.dropFirst("Command: ".count)) }
        // A folder check names the folder as verified against the agent's.
        if let folder = prompt.folder, !lines.isEmpty { lines[0] = folder }
        return Text(lines.joined(separator: "\n")).font(.callout.monospaced())
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var optionChoices: some View {
        let (pair, single, scopes, other) = groups
        VStack(spacing: Tokens.Space.s) {
            if let pair {
                ViewThatFits(in: .horizontal) {
                    if !typeSize.isAccessibilitySize {
                        HStack(spacing: Tokens.Space.s) {
                            button(pair.0, centered: true).primaryAction(.roundedRectangle(radius: Tokens.Radius.choice)).frame(maxWidth: .infinity)
                            // Deny at its own width, Approve taking the rest, as in the inbox
                            // (round 60: opus#6, equal halves here, unequal there).
                            button(pair.1, centered: true).choiceButton()
                                .frame(minWidth: 96).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    VStack(spacing: Tokens.Space.s) {
                        button(pair.0).primaryAction(.roundedRectangle(radius: Tokens.Radius.choice))
                        button(pair.1).choiceButton()
                    }
                }
            }
            ForEach(single, id: \.label) { option in optionButton(option) }
            if !scopes.isEmpty { scopeChoices(scopes) }
            ForEach(other, id: \.label) { option in optionButton(option) }
        }
        .grantConfirmation($confirmingScope, label: { $0 }, prompt: { [prompt] _ in prompt }, grant: onChoose)
    }

    /// The options as shown, top to bottom: Approve and Deny side by side when both are there
    /// (else each option in turn), the lasting grants, then the rest after a pair.
    private var groups: (pair: (ScreenPrompt.Option, ScreenPrompt.Option)?, single: [ScreenPrompt.Option],
                         scopes: [ScreenPrompt.Option], other: [ScreenPrompt.Option]) {
        let kind = { (option: ScreenPrompt.Option) in PromptOptionKind(label: option.label) }
        let scopes = prompt.options.filter { kind($0) == .scope }
        if let approve = prompt.options.first(where: { kind($0) == .approve }),
           let deny = prompt.options.first(where: { kind($0) == .deny }) {
            return ((approve, deny), [], scopes, prompt.options.filter { kind($0) == .neutral })
        }
        return (nil, prompt.options.filter { kind($0) != .scope }, scopes, [])
    }

    /// An option's ⌘-number: its place in the order shown.
    private func number(_ option: ScreenPrompt.Option) -> Int? {
        let (pair, single, scopes, other) = groups
        let shown = (pair.map { [$0.0, $0.1] } ?? []) + single + scopes + other
        return shown.firstIndex { $0.label == option.label }
    }

    /// A grant that outlasts this command, apart from the one-off pair under a hairline and
    /// confirmed before it's given (round 7: it read as one more green link, like Full Text in
    /// Terminal, with nothing saying it lasts). A borderless row, lighter than Deny (round 8:
    /// a grey slab as heavy as Deny's made it read as a peer of the one-off answers), in plain
    /// text colour: `.primary` inside a borderless button resolves to the tint (round 22: a
    /// second green action under Approve).
    private func scopeChoices(_ scopes: [ScreenPrompt.Option]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Divider().padding(.vertical, Tokens.Space.xs)
            ForEach(scopes, id: \.label) { option in
                Button { if choosing == nil { confirmingScope = option.label } } label: {
                    HStack(spacing: Tokens.Space.m) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(Tokens.secondaryText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choosing == option.label ? "Choosing…" : option.label).font(.body.weight(.medium))
                                .foregroundStyle(Color.primary)
                            Text("Won't ask again for matching requests")
                                .font(.footnote).foregroundStyle(Tokens.secondaryText)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if choosing == option.label { ProgressView().controlSize(.small) }
                        ShortcutHint(choosing == nil ? number(option) : nil)
                    }
                    .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                // The others are off while one sends, to VoiceOver too, and the one sending is
                // a status (round 77: sb#1, untappable, they still read as live buttons).
                .disabled(choosing != nil && choosing != option.label)
                .accessibilityRemoveTraits(choosing == option.label ? .isButton : [])
                .accessibilityAddTraits(choosing == option.label ? .updatesFrequently : [])
                .numberedShortcut(choosing == nil ? number(option) : nil)
                .accessibilityLabel(choosing == option.label ? "Choosing…"
                    : [option.label, option.detail, "Won't ask again for matching requests"].compactMap { $0 }.joined(separator: ". "))
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder private func optionButton(_ option: ScreenPrompt.Option) -> some View {
        switch PromptOptionKind(label: option.label) {
        case .approve: button(option).primaryAction(.roundedRectangle(radius: Tokens.Radius.choice))
        case .scope: EmptyView()
        case .neutral, .deny: button(option).choiceButton()
        }
    }

    /// `centered`: a pair side by side reads as two buttons; a list of choices keeps its edge.
    private func button(_ option: ScreenPrompt.Option, centered: Bool = false) -> some View {
        let pending = choosing == option.label
        let kind = PromptOptionKind(label: option.label)
        let progressLabel = kind == .approve ? "Approving…" : kind == .deny ? "Denying…" : "Choosing…"
        let shortcut = choosing == nil ? number(option) : nil
        return Button { onChoose(option.label) } label: {
            HStack {
                if centered && pending { ProgressView().controlSize(.small) }
                VStack(alignment: centered ? .center : .leading, spacing: Tokens.Space.xs) {
                    Text(pending ? progressLabel : shown(option)).font(.body.weight(.medium))
                    if !pending, let detail = option.detail { Text(detail).font(.subheadline).foregroundStyle(Tokens.secondaryText) }
                }
                .multilineTextAlignment(centered ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                if !centered {
                    Spacer(minLength: 0)
                    if pending { ProgressView().controlSize(.small) }
                }
                ShortcutHint(shortcut)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: centered ? .center : .leading)
        }
        .disabled(choosing != nil && !pending)
        .accessibilityRemoveTraits(pending ? .isButton : [])
        .accessibilityAddTraits(pending ? .updatesFrequently : [])
        .numberedShortcut(shortcut)
        .accessibilityLabel(pending ? progressLabel : [shown(option), option.detail].compactMap { $0 }.joined(separator: ". "))
    }

    /// omp's plain "Approve" says "Approve Once" beside its lasting grant, the scope of each
    /// said rather than inferred (round 56: sa#15, "Approve" over "Approve bash for this
    /// session"). Shown only: the option chosen is the screen's own.
    private func shown(_ option: ScreenPrompt.Option) -> String {
        option.label == "Approve" && prompt.options.contains { PromptOptionKind(label: $0.label) == .scope }
            ? "Approve Once" : option.label
    }
}

/// How an option on a screen prompt reads as a decision, by its label, scope first ("Yes, and
/// don't ask again" is a yes that lasts). Shared by the card and the inbox's inline approvals.
enum PromptOptionKind: Equatable {
    case approve, scope, deny, neutral

    init(label: String) {
        let label = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude's "Yes, I trust this folder" lasts for the folder: a grant, confirmed first.
        if label.contains("don't ask again") || label.contains("always") || label.contains("session")
            || (label.hasPrefix("yes") && label.contains("trust")) { self = .scope }
        else if label.hasPrefix("yes") || label.hasPrefix("approve") || label.hasPrefix("allow") { self = .approve }
        else if label.hasPrefix("no") || label.hasPrefix("deny") || label.hasPrefix("reject") || label.hasPrefix("esc") { self = .deny }
        else { self = .neutral }
    }

    /// The option a notification's Approve picks: a plain one-time yes, never a scoped grant.
    /// Only an option whose label and detail together use just these words counts ("Yes",
    /// "Yes, proceed (y)", "Approve Once"); omp's "Approve Directory: /tmp", or a "Yes" whose
    /// wrapped detail reads "and don't ask again for …", grants more than the one call, so a
    /// prompt with no such option gets no Approve button (round 38 release audit).
    static func oneTimeApproval(in options: [ScreenPrompt.Option]) -> ScreenPrompt.Option? {
        let plain: Set<String> = ["yes", "approve", "allow", "proceed", "once", "y", "this", "time"]
        return options.first { option in
            let text = [option.label, option.detail].compactMap { $0 }.joined(separator: " ")
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            return PromptOptionKind(label: option.label) == .approve && !words.isEmpty && words.allSatisfy(plain.contains)
        }
    }

    /// What was done, in the past tense: "Approved once", "Approved · bash for this session",
    /// "Denied", or "Chose “Skip”". A plain yes says it was once, so the record keeps the scope
    /// the card drew (round 79: sb#3, "Approved" didn't say whether it lasts).
    static func receipt(for label: String) -> String {
        switch PromptOptionKind(label: label) {
        case .approve: return "Approved once"
        case .scope:
            let scope = label.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?i)(yes|approve|allow)\b,?\s*(and\s+)?"#, with: "", options: .regularExpression)
            return scope.isEmpty ? "Approved" : "Approved · \(scope)"
        case .deny: return "Denied"
        case .neutral: return "Chose “\(label)”"
        }
    }
}

extension View {
    /// A lasting grant ("Yes, and don't ask again") waits on this before it's given, wherever
    /// it's offered: the thread's card, the inbox row's "…" menu and its context menu (round 8:
    /// the inbox's two granted it in one tap). `label` is the option it would choose.
    /// `prompt`: what the grant is for, when it says more than its label (a folder to trust).
    func grantConfirmation<Pending>(_ pending: Binding<Pending?>, label: @escaping (Pending) -> String,
                                    prompt: ((Pending) -> ScreenPrompt?)? = nil,
                                    grant: @escaping (Pending) -> Void) -> some View {
        confirmationDialog(pending.wrappedValue.map(label) ?? "", isPresented: Binding {
            pending.wrappedValue != nil
        } set: { if !$0 { pending.wrappedValue = nil } }, titleVisibility: .visible, presenting: pending.wrappedValue) { request in
            Button(label(request)) { grant(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(prompt?(request)?.grantMessage ?? "Matching requests from this agent won't ask you again.")
        }
    }
}

extension ScreenPrompt {
    /// A lasting grant's reach, when the prompt names it: Claude's folder check.
    var grantMessage: String? {
        guard title == "Trust this folder?", let folder = folder ?? subject else { return nil }
        return "\(folder)\n\nClaude will be able to read, edit and run files in this folder, now and in later sessions."
    }
}

extension PromptDriverError {
    /// Why answering on the agent's screen stopped, for the card's or the inbox's alert.
    static func message(for error: Error) -> String {
        guard let error = error as? PromptDriverError else {
            return "The connection dropped before the answer was confirmed."
        }
        return switch error {
        case .noPrompt: "The prompt isn't on the agent's screen anymore."
        case .questionMismatch, .optionNotFound: "The agent's screen doesn't match this prompt, so Herdwick stopped before sending anything more."
        case .cursorLost: "The selection didn't move as expected, so Herdwick stopped before pressing Enter."
        case .unexpectedScreen: "The agent's prompt changed partway through, so Herdwick stopped before sending more."
        case .unsupported: "This kind of answer has to be typed in the terminal."
        case .notConfirmed: "The keys were sent, but the agent hasn't logged the answer yet."
        }
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
                .primaryAction()
        }
    }
}

/// A command the agent ran with `pty: true` waiting at a prompt: herdr reports the agent as
/// working, so only the transcript and the console on its screen say it waits on you.
private struct TerminalInputCard: View {
    let console: ConsoleScreen
    let sending: Bool
    let terminalAddress: PaneAddress
    /// The reply and the console it answers, so a prompt that changed meanwhile isn't answered.
    let onReply: (String, ConsoleScreen) -> Void
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for input in the terminal", systemImage: AgentStatus.blocked.symbol)
                .font(.headline).foregroundStyle(AgentStatus.blocked.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(console.command).font(.caption.monospaced().weight(.semibold)).lineLimit(2)
                Text(console.lines.suffix(8).joined(separator: "\n")).font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.inset, in: .rect(cornerRadius: Tokens.Radius.plate))
            if console.offersYesNo {
                HStack(spacing: Tokens.Space.s) {
                    Button { onReply("y", console) } label: { Text("Yes").frame(maxWidth: .infinity) }
                        .choiceButton()
                    Button { onReply("n", console) } label: { Text("No").frame(maxWidth: .infinity) }
                        .choiceButton()
                }
                .disabled(sending)
            }
            HStack(spacing: 8) {
                field.submitLabel(.send).onSubmit(send)
                    .padding(.horizontal, Tokens.Space.m)
                    .frame(minHeight: Tokens.minTap)
                    .background(Tokens.Surface.inset, in: .capsule)
                Button(action: send) {
                    Group { if sending { ProgressView() } else { Image(systemName: "arrow.up") } }
                        .frame(width: 30, height: 30)
                }
                .primaryAction(.circle).disabled(sending)
                .accessibilityLabel("Send to the terminal")
            }
            NavigationLink(value: Route.terminal(terminalAddress)) {
                Label("Open Terminal", systemImage: "apple.terminal").frame(minHeight: Tokens.minTap)
            }
            .inlineAction().disabled(sending)
        }
        // A reply typed for one prompt (a password, say) never carries over to the next.
        .onChange(of: console.prompt) { reply = "" }
    }

    @ViewBuilder private var field: some View {
        let secret = console.prompt.map { $0.lowercased().contains("password") || $0.lowercased().contains("passphrase") } ?? false
        if secret {
            SecureField("Reply", text: $reply)
        } else {
            TextField("Reply", text: $reply).autocorrectionDisabled().textInputAutocapitalization(.never)
        }
    }

    /// An empty reply is a bare Enter, which takes a prompt's default.
    private func send() {
        guard !sending else { return }
        onReply(reply, console)
        reply = ""
    }
}

private extension View {
    /// Cards above the composer sit over the scrolling transcript, so they need their own surface.
    func cardBackground() -> some View {
        padding(Tokens.Space.l).raisedCard()
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

/// What opening on a turn whole reads (`openAtTurn`): the reader's messages' frames in the
/// transcript and the viewport. A plain class, so its changes don't redraw the thread.
private final class OpenGeometry {
    var userFrames: [String: CGRect] = [:]
    var layout: TailGeometry.Layout?

    /// The transcript's first line in view, under the bars and margins, when it rests at its end
    /// (the container's size already leaves out the insets).
    var restTop: CGFloat? {
        layout.map { $0.content - $0.container }
    }
}
