import HerdrAPI
import SwiftUI

/// An agent as a conversation: its own transcript as chat, its questions as tappable
/// answers, and a composer. The terminal is one tap away for everything else.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
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
    @State private var detailOverride: DetailLevel?
    private var detailSelection: Binding<DetailLevel> {
        Binding(get: { detailOverride ?? settings.detailLevel }, set: { detailOverride = $0 })
    }
    @State private var sentCount = 0
    @FocusState private var composerFocused: Bool

    private var agent: Agent? { connection.snapshot?.agents.first { $0.paneID == paneID } }
    private var blocked: Bool { agent?.agentStatus == .blocked }

    var body: some View {
        let detail = detailOverride ?? settings.detailLevel
        let items = feed.conversation.items(at: detail)
        let finalAssistantID = items.reversed().first { if case .assistant = $0 { true } else { false } }?.id
        let finished = detail == .digest && (agent?.agentStatus == .done || agent?.agentStatus == .idle)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if feed.hasEarlier {
                    Button("Show Earlier Messages") { feed.showEarlier() }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                ForEach(ConversationRow.rows(items, full: detail == .full,
                                             lastAssistantID: finished ? finalAssistantID : nil,
                                             subagents: { feed.conversation.subagents(spawnedBy: $0) })) { row in
                    row.view
                }
                if let plan = openPlan {
                    TodoCard(tool: plan)
                }
                // A running step already spins in its row; this covers the model thinking.
                if agent?.agentStatus == .working, feed.state == .live, !stepRunning {
                    WorkingRow()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .environment(\.openSubagent) { activity in
            if let route = subagentRoute(activity) { openSubagent(route) }
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: feed.conversation.workingSubagents.count) { _, count in
            connection.workingSubagents[paneID] = count
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay { placeholder }
        .safeAreaInset(edge: .top) {
            if settings.showWorkingSubagents {
                WorkingSubagentsTray(activities: feed.conversation.workingSubagents) { activity in
                    if let route = subagentRoute(activity) { openSubagent(route) }
                }
                .animation(.smooth, value: feed.conversation.workingSubagents)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(feed.title ?? feed.conversation.title ?? agent?.conversationTitle ?? paneID)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.terminal(connection.address(paneID: paneID))) {
                    Label("Terminal", systemImage: "apple.terminal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Detail", selection: detailSelection) {
                        Text("Full").tag(DetailLevel.full)
                        Text("Folded").tag(DetailLevel.folded)
                        Text("Digest").tag(DetailLevel.digest)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
        }
        .task(id: LocateKey(liveID: connection.liveID, ref: agent?.agentSession)) {
            await locateTranscript()
        }
        .task(id: FeedKey(liveID: connection.liveID, location: location, window: feed.window)) {
            guard let client = connection.client, let location else { return }
            await feed.follow(location, client: client)
        }
        .task(id: PromptKey(liveID: connection.liveID, watching: blocked && pendingAsk == nil)) {
            await watchScreenPrompt()
        }
        .onChange(of: agent?.stateChangeSeq, initial: true) {
            if let agent { connection.markSeen(agent) }
        }
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
    }

    private var subtitle: String {
        if let link = connection.statusText { return link }
        guard let agent else { return "Exited" }
        let workspace = connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.label
        return [agent.agentStatus.label, workspace].compactMap { $0 }.joined(separator: " · ")
    }

    private var stepRunning: Bool {
        feed.conversation.items.contains {
            if case .tool(let tool) = $0 { tool.state == .running } else { false }
        }
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
            ContentUnavailableView("Agent exited", systemImage: "moon.zzz", description: Text("This agent is no longer running in herdr."))
        } else if let reason = locateFailure ?? feed.state.unavailableReason {
            ContentUnavailableView {
                Label("No conversation", systemImage: "text.bubble")
            } description: {
                Text(reason)
            } actions: {
                NavigationLink("Open Terminal", value: Route.terminal(connection.address(paneID: paneID)))
            }
        } else if feed.state == .loading, connection.snapshot != nil {
            ProgressView()
        } else if feed.state == .live, feed.conversation.items.isEmpty {
            ContentUnavailableView("New conversation", systemImage: "text.bubble",
                                   description: Text("Send a message to get started."))
        }
    }

    // MARK: Bottom bar

    /// The question the agent is blocked on, when its transcript says what it asked.
    private var pendingAsk: AskActivity? {
        guard blocked else { return nil }
        return feed.conversation.pendingAsk
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let ask = pendingAsk {
                AskPanel(ask: ask, answering: answering, paneID: paneID, terminalAddress: connection.address(paneID: paneID)) { replies in
                    Task { await answer(ask, with: replies) }
                }
                .id(ask.toolCallId)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if blocked, let prompt = screenPrompt {
                PermissionCard(prompt: prompt, choosing: choosing, paneID: paneID, terminalAddress: connection.address(paneID: paneID)) { label in
                    Task { await choose(label, on: prompt) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if blocked {
                NeedsYouBanner(paneID: paneID, terminalAddress: connection.address(paneID: paneID))
            }
            MessageComposer(draft: $draft, attachments: $attachments, sending: sending, focus: $composerFocused) { Task { await sendDraft() } }
                .disabled(!connection.isLive || agent == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.smooth, value: pendingAsk?.toolCallId)
        .animation(.smooth, value: screenPrompt)
    }

    private func sendDraft() async {
        let text = draft
        guard !sending, connection.isLive, agent != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await deliverDraft(text, attachments: attachments, connection: connection, pane: paneID,
                                   agent: true, retention: settings.attachmentRetention) { updated in
                attachments = updated
            }
            draft = ""
            attachments = []
            sentCount += 1
        } catch {
            sendError = "The message wasn't delivered completely. Your draft and attachments are still here. \(error.localizedDescription)"
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
        guard let client = connection.client, let session = connection.activeSession,
              let ref = agent?.agentSession else { return }
        for attempt in 1...4 {
            let failure: String
            do {
                location = try await client.locateTranscript(ref, pane: paneID, session: session)
                if location != nil { locateFailure = nil; return }
                failure = "The agent's transcript isn't on the host."
            } catch {
                failure = "The agent's transcript couldn't be found."
            }
            guard attempt < 4 else { locateFailure = failure; return }
            guard (try? await Task.sleep(for: .seconds(2 * attempt))) != nil else { return }
        }
    }

    /// Reads the agent's screen while it is blocked with no transcript question, so a
    /// permission prompt can be answered here. Stops as soon as the agent moves on.
    private func watchScreenPrompt() async {
        guard blocked, pendingAsk == nil, let client = connection.client,
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
        model.navigationPath.append(route)
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
        case .item(.user(_, let text, let images), _): UserBubble(text: text, imageCount: images)
        case .item(.assistant(_, let text), let finished):
            HStack(alignment: .firstTextBaseline) {
                AssistantText(text: text)
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

private struct UserBubble: View {
    let text: String
    let imageCount: Int

    /// omp and Claude put "[Image #1, 1568x1047]" where a pasted image went; the label says it already.
    private var shown: String {
        guard imageCount > 0 else { return text }
        return text.replacing(/\[Image #\d+(?:, \d+x\d+)?\]\s*/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if imageCount > 0 {
                    Label(imageCount == 1 ? "Image" : "\(imageCount) images", systemImage: "photo")
                        .font(.caption)
                }
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
    @State private var expanded = false

    var body: some View {
        HStack {
            if outbound { Spacer(minLength: 44) }
            VStack(alignment: outbound ? .trailing : .leading, spacing: 6) {
                Label("\(outbound ? "to" : "from") \(peer)", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption).foregroundStyle(.secondary)
                Text(AssistantText.markdown(text))
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
}

private struct AssistantText: View {
    let text: String

    var body: some View {
        Text(Self.markdown(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
        if let values = answer.perQuestion[question.question] { return values.joined(separator: ", ") }
        return (answer.selected + [answer.custom].compactMap { $0 }).joined(separator: ", ")
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
/// questions). A typed "Other" answer replaces the selection. Long text clamps with "More".
private struct AskPanel: View {
    let ask: AskActivity
    let answering: Bool
    let paneID: String
    let terminalAddress: PaneAddress
    let onSubmit: ([QuestionReply]) -> Void

    @State private var page = 0
    @State private var replies: [QuestionReply]
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    init(ask: AskActivity, answering: Bool, paneID: String, terminalAddress: PaneAddress, onSubmit: @escaping ([QuestionReply]) -> Void) {
        self.ask = ask; self.answering = answering; self.paneID = paneID
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
                if !question.multi {
                    otherField
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
        let chosen = trimmedOther.isEmpty && replies[page].selected.contains(option.label)
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
                    if !trimmedOther.isEmpty { replies[page] = QuestionReply(custom: trimmedOther) }
                    page -= 1
                    other = replies[page].custom ?? ""
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
        other = ""
        if multi {
            if let index = replies[page].selected.firstIndex(of: label) {
                replies[page].selected.remove(at: index)
            } else {
                replies[page].selected.append(label)
            }
        } else {
            replies[page] = QuestionReply(selected: [label])
        }
    }

    private func advance() {
        if !trimmedOther.isEmpty {
            replies[page] = QuestionReply(custom: trimmedOther)
            otherFocused = false
        } else if replies[page].selected.isEmpty {
            return
        }
        if isLastPage {
            onSubmit(replies)
        } else {
            page += 1
            other = replies[page].custom ?? ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.title, systemImage: AgentStatus.blocked.symbol)
                .font(.headline).foregroundStyle(AgentStatus.blocked.tint)
            if !prompt.context.isEmpty {
                Text(prompt.context.joined(separator: "\n")).font(.caption.monospaced())
                    .lineLimit(10).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            }
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        if index == 0 { button(option).buttonStyle(.glassProminent) }
                        else { button(option).buttonStyle(.glass) }
                    }
                }
            }
            NavigationLink(value: Route.terminal(terminalAddress)) {
                Text("Open Terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).disabled(choosing != nil)
        }
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
