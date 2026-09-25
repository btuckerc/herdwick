import HerdrAPI
import SwiftUI

/// One pane: the live terminal, a key bar for agent prompts, and a composer that
/// sends a message the way a person would type it.
struct PaneView: View {
    @Environment(Settings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DemoDirector.self) private var demo: DemoDirector?
    let connection: HostConnection
    let paneID: String

    @State private var terminal = TerminalController()
    @State private var draft = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var sending = false
    @State private var typing = false
    @State private var sendError: String?
    @State private var sentCount = 0
    @State private var startFlow = AgentStartFlow()
    @FocusState private var composerFocused: Bool
    @State private var restingSize: CGSize = .zero
    /// The pane's width on the host; read-only mode renders it in full and scrolls sideways.
    @State private var paneCols: Int?
    /// Output above the pane's screen, loaded when reading starts and each time the user
    /// scrolls up into it.
    @State private var history: [[ANSIRun]] = []
    @State private var readingBack = false

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

    var body: some View {
        VStack(spacing: 0) {
            if agent == nil, pane != nil { startBar }
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
                    if up, !readingBack { Task { await loadHistory() } }
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
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        .padding()
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                if !composerFocused || typing { restingSize = size }
            }
            .animation(.smooth, value: terminal.hasFrame)

            controls
        }
        .navigationTitle(agent?.conversationTitle ?? pane?.label ?? workspaceLabel ?? pane?.terminalTitle ?? paneID)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.backgroundColor, for: .navigationBar)
        .onAppear { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: theme) { _, theme in terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: settings.font) { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .onChange(of: settings.fontSize) { terminal.apply(theme: theme, font: settings.font, size: settings.fontSize) }
        .task(id: StreamKey(liveID: connection.liveID, typing: typing, grid: typing ? nil : terminal.grid)) {
            guard let client = connection.client, let session = connection.activeSession, terminal.grid != nil else { return }
            await terminal.run(client: client, session: session, pane: paneID, control: typing)
            if typing, !Task.isCancelled { typing = false }
        }
        .task(id: HistoryKey(liveID: connection.liveID, typing: typing)) { await loadHistory() }
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

    /// Status in words where a badge would be: the link first, then the agent.
    private var subtitle: String {
        if let link = connection.statusText { return link }
        let status = agent.map(\.agentStatus.label) ?? (pane == nil ? nil : "Shell")
        return [status, pane?.cwd.map(homeRelative)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            KeyBar(typing: $typing) { keys in
                Task { await send(keys: keys) }
            } onTypeToggle: {
                typing.toggle()
                if typing {
                    composerFocused = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        terminal.focusKeyboard()
                    }
                }
            }
            if !typing { composer }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .disabled(!connection.isLive || pane == nil)
    }

    /// Start an agent in this shell; sits under the header so the keyboard area stays for typing.
    private var startBar: some View {
        HStack {
            Button {
                start(connection.lastAgentKind)
            } label: {
                HStack {
                    if startFlow.running { ProgressView() }
                    Text("Start \(agentKindLabel(connection.lastAgentKind))")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Menu {
                ForEach(["omp", "claude", "codex"], id: \.self) { kind in
                    Button("Start \(agentKindLabel(kind))") { start(kind) }
                }
            } label: { Image(systemName: "chevron.down") }
            .buttonStyle(.glass)
            .accessibilityLabel("Choose agent to start")
        }
        .tint(.accentColor)
        .disabled(startFlow.running || !connection.isLive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.backgroundColor)
    }

    private var composer: some View {
        MessageComposer(draft: $draft, attachments: $attachments, sending: sending, focus: $composerFocused,
                        placeholder: agent == nil ? "Run a command" : "Message") { Task { await sendDraft() } }
            .disabled(startFlow.running)
    }

    private func start(_ kind: String) {
        let request = AgentStartFlow.Request(connection: connection, address: connection.address(paneID: paneID), kind: kind)
        Task { await startFlow.start(request, onStarted: didStart) }
    }

    private func didStart(_ agent: Agent, _ address: PaneAddress) {
        let source = Route.terminal(connection.address(paneID: paneID))
        guard model.navigationPath.last == source else { return }
        if agent.hasTranscript {
            model.navigationPath[model.navigationPath.count - 1] = .conversation(address)
        } else if address.paneID != paneID {
            model.navigationPath[model.navigationPath.count - 1] = .terminal(address)
        }
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, connection.isLive, pane != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: agent != nil, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            draft = ""
            attachments = []
            sentCount += 1
        } catch {
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
        }
    }

    /// Refreshes the host width and the output above the screen. Read-only calls: the
    /// host's pane is never scrolled or resized for reading.
    private func loadHistory() async {
        guard !typing, let client = connection.client, let session = connection.activeSession else { return }
        if let size = try? await client.paneSize(paneID, session: session) { paneCols = size.cols }
        if let lines = try? await client.paneHistory(paneID, session: session, lines: 500), !Task.isCancelled {
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

/// Keys agents ask for: approve/deny prompts, menus, interrupt. While typing, SwiftTerm's
/// keyboard accessory (with a sticky ctrl) takes over, so only the exit toggle stays.
struct KeyBar: View {
    @Binding var typing: Bool
    let onKeys: ([String]) -> Void
    let onTypeToggle: () -> Void

    private let keys: [(label: String, symbol: String?, keys: [String])] = [
        ("esc", nil, ["esc"]),
        ("tab", "arrow.right.to.line", ["tab"]),
        ("shift-tab", "arrow.left.to.line", ["shift+tab"]),
        ("up", "chevron.up", ["up"]),
        ("down", "chevron.down", ["down"]),
        ("left", "chevron.left", ["left"]),
        ("right", "chevron.right", ["right"]),
        ("enter", "return", ["enter"]),
        ("ctrl-c", nil, ["ctrl+c"]),
    ]

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        onTypeToggle()
                    } label: {
                        Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                            .frame(minWidth: 28, minHeight: 22)
                    }
                    .buttonStyle(.glass)
                    .tint(typing ? .accentColor : nil)
                    .accessibilityLabel(typing ? "Stop typing in the terminal" : "Type in the terminal (resizes the pane to this screen)")

                    if !typing {
                        ForEach(keys, id: \.label) { key in
                            Button {
                                onKeys(key.keys)
                            } label: {
                                Group {
                                    if let symbol = key.symbol {
                                        Image(systemName: symbol)
                                    } else {
                                        Text(key.label).font(.callout.monospaced().weight(.medium))
                                    }
                                }
                                .frame(minWidth: 28, minHeight: 22)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel(key.label)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
    }
}
