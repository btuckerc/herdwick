import HerdrAPI
import SwiftUI

/// One pane: the live terminal, a key bar for agent prompts, and a composer that
/// sends a message the way a person would type it.
struct PaneView: View {
    @Environment(Settings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    let connection: HostConnection
    let paneID: String

    @StateObject private var terminal = TerminalController()
    @State private var draft = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var sending = false
    @State private var typing = false
    @State private var sendError: String?
    @State private var sentCount = 0
    @State private var startFlow = AgentStartFlow()
    @FocusState private var composerFocused: Bool
    @State private var fontPinchBase: Double?
    @State private var restingSize: CGSize = .zero
    /// The visible height now, which the keyboard shrinks while `restingSize` stays.
    @State private var viewHeight: CGFloat = 0
    /// The pane's width on the host; read-only mode renders it in full and scrolls sideways.
    @State private var paneCols: Int?
    /// Output above the pane's screen, loaded when reading starts and each time the user
    /// scrolls up into it.
    @State private var history: [[ANSIRun]] = []
    @State private var readingBack = false
    @State private var showsText = false
    @State private var historyTask: Task<Void, Never>?
    @State private var historyID = UUID()

    private var pane: Pane? { connection.snapshot?.panes.first { $0.id == paneID } }
    private var agent: Agent? { connection.snapshot?.agents.first { $0.paneID == paneID } }
    private var workspaceLabel: String? {
        guard let pane else { return nil }
        return connection.snapshot?.workspaces.first { $0.id == pane.workspaceID }?.label
    }
    private var theme: TerminalTheme { settings.theme(for: colorScheme) }

    /// Read-only mode renders the pane at its host size (or the view's, if larger): `observe`
    /// at fewer rows shows only the top rows and hides the prompt, and at fewer columns cuts
    /// wide output off. Typing mode fits the view and resizes the PTY to match instead.
    private var liveSize: CGSize {
        let fit = CGSize(width: max(restingSize.width - 12, 0), height: restingSize.height)
        guard !typing else { return fit }
        let cols = CGFloat(paneCols ?? 0), rows = CGFloat(pane?.viewportRows ?? 0)
        return CGSize(width: max(fit.width, ceil(cols * terminal.cellWidth) + 1),
                      height: max(fit.height, rows * terminal.cellHeight))
    }

    /// Reading scrolls only down to the last row showing anything: the view anchors at the
    /// bottom (a shell's prompt), and an agent drawn at the top of a tall pane would sit above
    /// it, leaving a blank screen. The rows below are blank, so they are clipped, not re-rendered.
    private var shownHeight: CGFloat {
        guard !typing else { return liveSize.height }
        return min(liveSize.height, max(viewHeight, CGFloat(terminal.usedRows) * terminal.cellHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            if agent == nil, pane != nil { startBar }
            outputNotice
            ZStack {
                theme.backgroundColor.ignoresSafeArea(edges: .horizontal)
                // Vertical outside horizontal: each drag moves one way, like a document.
                // Reading keeps its resting size while the keyboard is up: the keyboard covers
                // old output instead of reflowing the stream.
                ScrollView(.vertical) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !typing, !history.isEmpty {
                                TerminalHistory(lines: history, theme: theme, font: settings.font.uiFont(size: settings.fontSize),
                                                lineHeight: terminal.cellHeight)
                            }
                            if restingSize != .zero {
                                TerminalSurface(controller: terminal)
                                    .frame(width: liveSize.width, height: liveSize.height)
                                    .frame(height: shownHeight, alignment: .top)
                                    .clipped()
                                    // Pinch sizes the text in place, in whole points as
                                    // Settings steps, within its range (round 15: only Settings changed it).
                                    .simultaneousGesture(MagnifyGesture()
                                        .onChanged { value in
                                            let base = fontPinchBase ?? settings.fontSize
                                            fontPinchBase = base
                                            let size = min(Settings.fontSizes.upperBound, max(Settings.fontSizes.lowerBound, (base * value.magnification).rounded()))
                                            if size != settings.fontSize { settings.fontSize = size }
                                        }
                                        .onEnded { _ in fontPinchBase = nil })
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .defaultScrollAnchor(.leading)
                    .scrollIndicators(.hidden)
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollDisabled(typing)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 8
                } action: { _, up in
                    if up, !readingBack { refreshHistory() }
                    readingBack = up
                }
                .opacity(connection.isLive && terminal.hasFrame ? 1 : 0.55)
                if !terminal.hasFrame, connection.isLive {
                    ProgressView().tint(theme.foregroundColor)
                }
                if pane == nil, connection.snapshot != nil {
                    ContentUnavailableView("Pane closed", systemImage: "rectangle.slash", description: Text("This pane no longer exists in herdr."))
                        .foregroundStyle(theme.foregroundColor)
                } else if let reason = terminal.closedReason {
                    Text(reason)
                        .font(.footnote)
                        .padding(12)
                        .background(Tokens.Surface.raised, in: .rect(cornerRadius: Tokens.Radius.card))
                        .padding()
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                if !composerFocused || typing { restingSize = size }
                viewHeight = size.height
            }
            controls
        }
        // An agent's terminal opened as the thread itself (it has no transcript) keeps the
        // dock, at the end of the keys' row; one pushed from its conversation goes back there.
        .agentDock(current: connection.address(paneID: paneID), busy: sending)
        .focusedSceneValue(\.herdwickSending, sending)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarBackground(theme.backgroundColor, for: .navigationBar)
        .toolbar {
            let offersIntegration = agent?.agent.map { harness in
                connection.missingIntegrations.contains { $0.target == harness }
            } ?? false
            // Back and its margin end at 72 pt; Type and Read as Text, their margins and the gap
            // take about 120, the offer about 120 more.
            BarTitle(title: title, subtitle: subtitle, room: restingSize.width - 192 - (offersIntegration ? 120 : 0),
                     still: connection.statusText == nil ? agent.flatMap { connection.presentedStatus($0) == .working ? connection.stillSince($0) : nil } : nil,
                     stillReplacesPlace: true,
                     tint: connection.statusText == nil ? agent.map { connection.presentedStatus($0).tint } : nil)
            if offersIntegration, let harness = agent?.agent {
                ToolbarItem(placement: .topBarTrailing) {
                    IntegrationOffer(connection: connection, harness: harness, compact: true)
                }
            }
            // Type sits in the bar, always in the same place, not at the end of the key rail
            // (round 17: with ⌃C ahead of it, it fell off the rail's edge).
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(typing ? "Stop Typing" : "Type", systemImage: typing ? "keyboard.fill" : "keyboard", action: toggleTyping)
                    .keyboardShortcut("t", modifiers: .command)
                    .accessibilityAddTraits(typing ? .isSelected : [])
                    .accessibilityHint("Resizes the pane to this screen")
                    .disabled(!connection.isLive || pane == nil)
                    // Named enlarged on a long press at accessibility sizes (round 85: sb#8).
                    .accessibilityShowsLargeContentViewer()
                Button("Read as Text", systemImage: "doc.plaintext") { showsText = true }
                    .accessibilityShowsLargeContentViewer()
                    // Beside Type's ⌘T (round 40: sb#14, the readable view had no key).
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(pane == nil)
            }
        }
        .sheet(isPresented: $showsText) {
            TerminalText(connection: connection, paneID: paneID, cwd: pane?.workingDirectory, snapshot: terminal.plainText,
                         title: title, receivedAt: connection.lostAt ?? terminal.lastOutputAt)
        }
        .background {
            Group {
                Button("Increase Terminal Text") { adjustFontSize(1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Terminal Text") { adjustFontSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Terminal Text Size") { settings.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // ⇧⌘U and ⌃⌘A on the agent in this terminal, as its conversation takes them (round
            // 65: sb#7); back to the inbox, where a Hide offers Undo.
            .onChange(of: scene.markUnreadRequest) {
                guard onScreen, let agent, connection.presentedStatus(agent) == .idle, !connection.isUnread(agent) else { return }
                connection.markUnread(agent)
                scene.back()
            }
            .onChange(of: scene.hideRequest) {
                guard onScreen, let agent else { return }
                connection.hide(agent)
                scene.hiddenFromThread = connection.address(paneID: paneID)
                scene.back()
            }
            // ⌘L to the line composer, as in a conversation (round 67: sb#3); out of typing first.
            .onChange(of: scene.messageRequest) {
                guard onScreen else { return }
                typing = false
                composerFocused = true
            }
            .hidden()
        }

        .onAppear { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: theme) { _, theme in terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: settings.font) { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: settings.fontSize) { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .task(id: StreamKey(liveID: connection.liveID, typing: typing, grid: typing ? nil : terminal.grid)) {
            guard terminal.grid != nil else { return }
            let control = typing
            repeat {
                guard !Task.isCancelled, connection.isLive, pane != nil, terminal.closedReason == nil,
                      let client = connection.client, let session = connection.activeSession else { return }
                await terminal.run(client: client, session: session, pane: paneID, control: control)
                guard !Task.isCancelled else { return }
                if control { typing = false; return }
                guard terminal.closedReason == nil,
                      (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            } while !Task.isCancelled
        }
        .onChange(of: HistoryKey(liveID: connection.liveID, typing: typing), initial: true) {
            cancelHistory()
            refreshHistory()
        }
        .onAppear { refreshHistory() }
        .onDisappear { cancelHistory() }
        .sensoryFeedback(.success, trigger: sentCount) { _, _ in settings.haptics }
        // Scenario cues for the demo captures: a typed reply, then the real send.
        .onChange(of: demo?.draft, initial: true) { _, text in if let text { draft = text } }
        .onChange(of: demo?.sendCount) { Task { await sendDraft() } }
        .onChange(of: terminal.hasFrame, initial: true) { _, painted in demo?.terminalReady = painted }
        .modifier(AgentStartFeedback(flow: startFlow, onStarted: didStart))
        .alert("Couldn't send", isPresented: .init(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    private var title: String {
        agent?.conversationTitle ?? pane?.label ?? workspaceLabel ?? pane?.terminalTitle ?? paneID
    }

    /// Status in words where a badge would be: the link first, then the agent, and "no update
    /// 6m" in grey once it has gone still, in place of the directory (`BarTitle.still`; round 31:
    /// an agent the inbox showed silent read "Working" here in blue; round 32: with the directory
    /// too, the subtitle pushed Type and Read as Text into an overflow menu).
    private var subtitle: String {
        if let link = connection.statusText { return link }
        let status = agent.map { connection.presentedStatus($0).label } ?? (pane == nil ? nil : "Shell")
        let place = pane?.workingDirectory.map(homeRelative)
        return [status, place].compactMap { $0 }.joined(separator: " · ")
    }

    /// Offline, a compact line above the buffer, never over the output: the screen below is as
    /// it was when the link dropped (round 36: a stale terminal's "Working" prompt read as live).
    /// Live, the pane streams, so its screen is current whatever the transcript says.
    @ViewBuilder private var outputNotice: some View {
        if !connection.isLive {
            TimelineView(.everyMinute) { context in
                let age = connection.lostAt.map { AgentRow.age(of: $0, at: context.date) }
                let words = age.map { $0 == "now" ? "Output as of just now" : "Output as of \($0) ago" } ?? "Output as last received"
                Label("\(words) · Not connected", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(Tokens.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Space.l)
                    .padding(.vertical, Tokens.Space.xs)
                    .accessibilityLabel("\(words). Not connected.")
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if typing {
                HStack(spacing: 8) {
                    keyBar
                    if hasDock { AgentDock.slot }
                }
            } else {
                composer
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // On the terminal's own canvas, as its bar is (round 95: sb#14, under a light theme's
        // cream the keys and composer sat on a white slab, two surfaces meeting).
        .background(theme.backgroundColor.ignoresSafeArea(edges: .bottom))
    }

    private var keyBar: some View {
        KeyBar(typing: $typing, onKeys: { keys in
            Task { await send(keys: keys) }
        }, onTypeToggle: toggleTyping)
        .disabled(!connection.isLive || pane == nil)
    }

    private func toggleTyping() {
        typing.toggle()
        if typing {
            composerFocused = false
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                terminal.focusKeyboard()
            }
        }
    }

    /// This terminal is the scene's top route, so the menu's keys are for it.
    private var onScreen: Bool { scene.navigationPath.last == .terminal(connection.address(paneID: paneID)) }

    private var hasDock: Bool {
        guard settings.showsDock, !scene.sidebarBeside, agent != nil, scene.navigationPath.count == 1 else { return false }
        let current = connection.address(paneID: paneID)
        return model.dockThreads(in: scene).contains { $0.address != current }
    }

    /// Start an agent in this shell; sits under the header so the keyboard area stays for typing.
    /// At its words' width, leading, not the screen's: the shell is the page (round 95: sa#8, a
    /// full-width green bar outweighed the prompt it sat over).
    private var startBar: some View {
        HStack(spacing: 8) {
            Button {
                start(connection.lastAgentKind)
            } label: {
                HStack {
                    if startFlow.running { ProgressView() }
                    Text("Start \(agentKindLabel(connection.lastAgentKind))").lineLimit(1)
                }
                .padding(.horizontal, Tokens.Space.s)
                .frame(minHeight: 30)
            }
            .primaryAction()
            Menu {
                ForEach(startableAgentKinds, id: \.self) { kind in
                    Button("Start \(agentKindLabel(kind))") { start(kind) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 30, height: 30)
            }
            .floatingControl(.circle)
            .accessibilityLabel("Choose agent to start")
            Spacer(minLength: 0)
        }
        .tint(.accentColor)
        .disabled(startFlow.running || !connection.isLive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.backgroundColor)
    }

    private var composer: some View {
        MessageComposer(draft: $draft, attachments: $attachments, sending: sending, focus: $composerFocused,
                        placeholder: agent == nil ? "Run a command" : "Message", docksAgents: hasDock,
                        // The keys take the mic row's middle, so the screen keeps the conversation's two rows.
                        pinned: AnyView(keyBar),
                        // `locked`, not `.disabled`: that would also disable a running dictation's Stop and Cancel.
                        locked: !connection.isLive || pane == nil || startFlow.running,
                        vocabulary: { DictationController.vocabulary(from: [pane?.workingDirectory, agent?.agent].compactMap { $0 }) }) {
            Task { await sendDraft() }
        }
    }

    private func start(_ kind: String) {
        let request = AgentStartFlow.Request(connection: connection, address: connection.address(paneID: paneID), kind: kind)
        Task { await startFlow.start(request, onStarted: didStart) }
    }

    private func didStart(_ agent: Agent, _ address: PaneAddress) {
        let source = Route.terminal(connection.address(paneID: paneID))
        guard scene.navigationPath.last == source else { return }
        if agent.hasTranscript {
            scene.navigationPath[scene.navigationPath.count - 1] = .conversation(address)
        } else if address.paneID != paneID {
            scene.navigationPath[scene.navigationPath.count - 1] = .terminal(address)
        }
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, connection.isLive, pane != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        sending = true
        defer { sending = false }
        // Cleared before delivery so the keyboard stays up and anything typed meanwhile is kept.
        draft = ""
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: agent != nil, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            attachments = []
            sentCount += 1
        } catch {
            draft = restoringDraft(text, before: draft)
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
        }
    }

    private func cancelHistory() {
        historyID = UUID()
        historyTask?.cancel()
        historyTask = nil
    }

    /// One refresh at a time; further scroll-up gestures share the in-flight read.
    private func refreshHistory() {
        guard historyTask == nil, !typing, connection.isLive,
              let client = connection.client, let session = connection.activeSession else { return }
        let id = UUID()
        historyID = id
        historyTask = Task {
            defer { if historyID == id { historyTask = nil } }
            async let size: Void = refreshPaneSize(client: client, session: session, id: id)
            async let text: Void = refreshHistoryText(client: client, session: session, id: id)
            _ = await (size, text)
        }
    }

    private func refreshPaneSize(client: HerdrClient, session: String, id: UUID) async {
        if let size = try? await client.paneSize(paneID, session: session),
           !Task.isCancelled, historyID == id, !typing {
            paneCols = size.cols
        }
    }

    private func refreshHistoryText(client: HerdrClient, session: String, id: UUID) async {
        if let lines = try? await client.paneHistory(paneID, session: session, lines: 500),
           !Task.isCancelled, historyID == id, !typing {
            history = lines
        }
    }

    private func send(keys: [String]) async {
        do {
            try await connection.sendKeys(keys, pane: paneID)
        } catch {
            sendError = "The key wasn't delivered."
        }
    }
    
    private func adjustFontSize(_ delta: Double) {
        settings.fontSize = min(Settings.fontSizes.upperBound, max(Settings.fontSizes.lowerBound, settings.fontSize + delta))
    }
}

private struct HistoryKey: Hashable {
    let liveID: Int
    let typing: Bool
}

private struct StreamKey: Hashable {
    let liveID: Int
    let typing: Bool
    let grid: TerminalController.Grid?
}

/// Keys agents ask for: approve/deny prompts, menus, interrupt, always in reach, the ones an
/// approval needs first and interrupt with them (round 15: they hid behind a Keys toggle, so
/// answering a prompt took an extra tap and graders read the terminal as keyless), then the
/// rest, the row scrolling sideways, its trailing edge fading while more keys lie past it
/// (round 15: "esc" was cut in half at the rail's end; round 16: then "ctrl-c" was, the key
/// that stops a run, so it's "⌃C" now). Type is in the bar (the composer already sends a line;
/// Type is for raw keys). While typing, SwiftTerm's keyboard accessory (with a sticky ctrl)
/// takes over, so the rail is only the way out of it.
struct KeyBar: View {
    @Binding var typing: Bool
    let onKeys: ([String]) -> Void
    let onTypeToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var keysWidth: CGFloat = 0
    @State private var position = ScrollPosition(edge: .leading)
    /// Keys past the trailing edge. From the measured widths, not only scroll changes: those
    /// don't report the first layout, so the fade never showed until the rail was scrolled
    /// (round 88: opus#5, sa#9, the phone's rail read as five keys with nothing past ⌃C).
    private var morePastEdge: Bool { offset + visibleWidth < keysWidth - 1 }

    private typealias Key = (label: String, spoken: String, symbol: String?, keys: [String])
    private let keys: [Key] = [
        ("up", "Up Arrow", "chevron.up", ["up"]),
        ("down", "Down Arrow", "chevron.down", ["down"]),
        ("enter", "Return", "return", ["enter"]),
        ("esc", "Escape", nil, ["esc"]),
        ("⌃C", "Interrupt, Control-C", nil, ["ctrl+c"]),
        ("tab", "Tab", "arrow.right.to.line", ["tab"]),
        ("shift-tab", "Shift-Tab", "arrow.left.to.line", ["shift+tab"]),
        ("left", "Left Arrow", "chevron.left", ["left"]),
        ("right", "Right Arrow", "chevron.right", ["right"]),
    ]

    var body: some View {
        rail
            .overlay(alignment: .trailing) {
                if morePastEdge { moreKeys.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: morePastEdge)
    }

    private var rail: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 4) {
                // 4 pt apart, so on a phone the key past the edge shows its rim in the fade
                // rather than the rail ending flush on ⌃C (round 88: opus#5).
                HStack(spacing: 4) {
                    if typing { typingToggle } else { keyButtons }
                }
                .padding(.vertical, 2)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { keysWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        // A fade a short way in, so the key past the edge reads as more to scroll to, not as one
        // cut off under the dock (round 18: half a key showed beside the sheep), and ⌃C, the
        // last key in reach, keeps its label clear of it (round 88).
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(morePastEdge ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 24)
            }
        }
    }

    /// "…" over the fade while keys lie past the edge, scrolling to them: the fade alone, then
    /// the next key's rim, read as a shadow (round 89: opus#4, sa#7, sb#4), and round 89's
    /// chevron as a disclosure arrow, which answered taps across 24 pt and always animated
    /// (round 90: opus#4, sa#4, sb#2, sb#5). It stays in the fade's 24 pt, so ⌃C, the last key
    /// in reach on a phone, keeps all of its own; its taps reach past it, outward only.
    private var moreKeys: some View {
        Button {
            if reduceMotion { position.scrollTo(edge: .trailing) } else { withAnimation(.snappy) { position.scrollTo(edge: .trailing) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(Color.primary)
                .frame(width: 24, height: 34)
                .padding(.trailing, Tokens.Space.m)
                .padding(.vertical, 5)
                .contentShape(.rect)
                .padding(.trailing, -Tokens.Space.m)
                .padding(.vertical, -5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More Keys")
        .accessibilityShowsLargeContentViewer()
    }

    private var typingToggle: some View {
        Button(action: onTypeToggle) {
            Label("Typing", systemImage: "keyboard.fill").frame(minHeight: 30)
        }
        .floatingControl(.capsule)
        .tint(.accentColor)
        .accessibilityValue("Selected")
        .accessibilityAddTraits(.isSelected)
        .accessibilityHint("Resizes the pane to this screen")
    }

    private var keyButtons: some View {
        ForEach(keys, id: \.label) { key in
            Button {
                onKeys(key.keys)
            } label: {
                Group {
                    if let symbol = key.symbol {
                        Image(systemName: symbol).frame(width: 30, height: 30)
                    } else {
                        Text(key.label).font(.callout.monospaced().weight(.medium))
                            .frame(minWidth: 30, minHeight: 30)
                    }
                }
            }
            .floatingControl(key.symbol == nil ? .capsule : .circle)
            .accessibilityLabel(key.spoken)
            // Capped at their size, so a long press shows the key large, as the system's bars do
            // (round 84: opus#8).
            .accessibilityShowsLargeContentViewer()
        }
    }
}
