import HerdrAPI
import SwiftUI

/// Answers given from a Needs You row (the inbox, the iPad Overview's cards), by agent: under
/// way, then the receipt until the row moves on. One per window, so an answer given in the
/// Overview shows its receipt in the sidebar too (round 6: the Overview repeated the sidebar's
/// question without a way to answer it).
@MainActor @Observable
final class InlineAnswers {
    private var entries: [PaneAddress: InlineAnswer] = [:]
    /// Bumps with each confirmed answer, for its haptic.
    private(set) var feedback: AnswerFeedback?
    /// The last answer that failed, for the inbox's alert, which clears it.
    var failure: Failure?

    struct Failure: Equatable {
        let id = UUID()
        let title: String
        let message: String
        /// The thread to finish it in.
        let open: Route
    }

    subscript(address: PaneAddress) -> InlineAnswer? { entries[address] }
    var isEmpty: Bool { entries.isEmpty }

    /// What `thread`'s row can answer in place: an approval herdr's screen probe confirmed
    /// (choice prompts with a yes among them), else an ask the inbox already holds the
    /// transcript for (`ConversationRegistry.parsed`) that is one question with a single pick
    /// among one to three options. One under way keeps its prompt until its receipt has shown.
    /// Typing an answer, several picks or several questions stay in the thread. Select mode
    /// shows it inert (`SessionView.rows`).
    func choices(for thread: Thread) -> (choices: InlineChoices, prompt: ScreenPrompt?, ask: AskActivity?)? {
        if let answer = entries[thread.address] {
            if let prompt = answer.prompt { return (.approval(prompt), prompt, nil) }
            if let ask = answer.ask, let question = ask.questions.first { return (.ask(question), nil, ask) }
            return nil
        }
        let connection = thread.connection
        guard connection.isLive else { return nil }
        let prompt = connection.wait(thread.agent)?.prompt
        // A lasting grant counts too (Claude's "Yes, I trust this folder" has no plain yes); it
        // is confirmed before it's given, as everywhere.
        if let prompt, prompt.style == .choice, prompt.phase == .question,
           prompt.options.contains(where: { [.approve, .scope].contains(PromptOptionKind(label: $0.label)) }) {
            return (.approval(prompt), prompt, nil)
        }
        guard connection.presentedStatus(thread.agent) == .blocked, prompt?.style != .choice,
              let ask = connection.conversations.parsed(host: connection.identity, agent: thread.agent)?.pendingAsk,
              ask.questions.count == 1, let question = ask.questions.first, !question.multi,
              (1...3).contains(question.options.count) else { return nil }
        return (.ask(question), nil, ask)
    }

    /// Answers `thread`'s approval or ask with `label`, as its thread's card would.
    func answer(_ label: String, prompt: ScreenPrompt?, ask: AskActivity?, in thread: Thread, decisionLog: DecisionLog, saved: Bool) {
        if let prompt { approve(label, on: prompt, in: thread, decisionLog: decisionLog, saved: saved) }
        else if let ask { answer(label, ask, in: thread, decisionLog: decisionLog, saved: saved) }
    }

    /// Drives an authenticated notification answer through the same verified prompt driver and
    /// durable decision receipt as an inline answer. Past `deadline` it writes nothing more.
    func answerFromNotification(_ label: String, prompt: ScreenPrompt?, ask: AskActivity?,
                                in thread: Thread, decisionLog: DecisionLog, deadline: ContinuousClock.Instant) async throws {
        let connection = thread.connection
        let address = thread.address
        guard connection.isLive, let client = connection.client else { throw HerdrError.noResponse }
        if let prompt {
            let io = DeadlineIO(base: HerdrPromptIO(client: client, pane: address.paneID, session: address.session) { _, _ in false },
                                deadline: deadline)
            try await PromptDriver.choose(label, on: prompt, io: io)
            let receipt = PromptOptionKind.receipt(for: label)
            decisionLog.record(key: DecisionLog.key(address: address, transcriptPath: connection.activity[address.paneID]?.transcript?.path),
                               afterItemID: nil, receipt: receipt, detail: prompt.shownSubject,
                               detailMayBeCut: prompt.contextMayBeTruncated, saved: true)
        } else if let ask {
            let entry = connection.conversations.entry(host: connection.identity, pane: address.paneID, agent: thread.agent)
            guard let location = entry.location else { throw PromptDriverError.unsupported }
            let feed = entry.feed
            let viewer = UUID()
            connection.conversations.activate(entry, viewer: viewer)
            let follow = feed.isFollowing ? nil : Task {
                await feed.follow(location, client: client, host: connection.identity, follower: viewer)
            }
            defer {
                follow?.cancel()
                connection.conversations.deactivate(entry, viewer: viewer)
            }
            let io = DeadlineIO(base: HerdrPromptIO(client: client, pane: address.paneID, session: address.session) { id, timeout in
                await feed.waitForResult(of: id, timeout: timeout)
            }, deadline: deadline)
            try await PromptDriver.answer(ask, replies: [QuestionReply(custom: label)], io: io)
            let receipt = "Answered “\(label)”"
            decisionLog.record(key: DecisionLog.key(address: address, transcriptPath: location.path),
                               afterItemID: ask.toolCallId, receipt: receipt, detail: nil, saved: true)
        } else {
            throw PromptDriverError.unsupported
        }
        connection.refreshActivity()
    }

    /// A prompt's terminal that refuses every key once the action's time is up or it was cancelled.
    private struct DeadlineIO: PromptIO {
        let base: any PromptIO
        let deadline: ContinuousClock.Instant

        private func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CancellationError() }
        }
        func readVisible() async throws -> String { try check(); return try await base.readVisible() }
        func send(keys: [String]) async throws { try check(); try await base.send(keys: keys) }
        func type(_ text: String) async throws { try check(); try await base.type(text) }
        func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool {
            try await base.waitForResult(toolCallId: toolCallId, timeout: timeout)
        }
    }

    /// Picks an option on the agent's screen, as the thread's card does; the prompt leaving the
    /// screen is the proof.
    private func approve(_ label: String, on prompt: ScreenPrompt, in thread: Thread, decisionLog: DecisionLog, saved: Bool) {
        guard let client = thread.connection.client else { return }
        let address = thread.address
        run(InlineAnswer(prompt: prompt, ask: nil, label: label, rank: inboxRank(thread)), in: thread,
            receipt: PromptOptionKind.receipt(for: label), detail: prompt.shownSubject, detailMayBeCut: prompt.contextMayBeTruncated,
            transcript: thread.connection.activity[address.paneID]?.transcript?.path,
            decisionLog: decisionLog, saved: saved) {
            let io = HerdrPromptIO(client: client, pane: address.paneID, session: address.session) { _, _ in false }
            try await PromptDriver.choose(label, on: prompt, io: io)
        }
    }

    /// Answers an ask with the thread's driver, which checks the screen shows this question
    /// before each key. The agent logging the answer is the proof, so the transcript is
    /// followed meanwhile, as an open thread follows it.
    private func answer(_ label: String, _ ask: AskActivity, in thread: Thread, decisionLog: DecisionLog, saved: Bool) {
        let connection = thread.connection
        let address = thread.address
        let entry = connection.conversations.entry(host: connection.identity, pane: address.paneID, agent: thread.agent)
        guard let client = connection.client, let location = entry.location else { return }
        run(InlineAnswer(prompt: nil, ask: ask, label: label, rank: inboxRank(thread)), in: thread,
            receipt: "Answered “\(label)”", detail: nil, transcript: location.path, after: ask.toolCallId,
            decisionLog: decisionLog, saved: saved) {
            let feed = entry.feed
            let viewer = UUID()
            connection.conversations.activate(entry, viewer: viewer)
            let follow = feed.isFollowing ? nil : Task {
                await feed.follow(location, client: client, host: connection.identity, follower: viewer)
            }
            defer {
                follow?.cancel()
                connection.conversations.deactivate(entry, viewer: viewer)
            }
            let io = HerdrPromptIO(client: client, pane: address.paneID, session: address.session) { id, timeout in
                await feed.waitForResult(of: id, timeout: timeout)
            }
            try await PromptDriver.answer(ask, replies: [QuestionReply(selected: [label])], io: io)
        }
    }

    /// The row holds its place saying what's under way, then its receipt, which the thread
    /// keeps as a decision line.
    private func run(_ answer: InlineAnswer, in thread: Thread, receipt: String, detail: String?, detailMayBeCut: Bool = false,
                     transcript: String?, after item: String? = nil, decisionLog: DecisionLog, saved: Bool,
                     drive: @escaping @MainActor () async throws -> Void) {
        let address = thread.address
        guard entries[address] == nil else { return }
        entries[address] = answer
        let title = thread.agent.conversationTitle
        let route: Route = thread.agent.hasTranscript ? .conversation(address) : .terminal(address)
        Task {
            do {
                try await drive()
                entries[address]?.receipt = receipt
                decisionLog.record(key: DecisionLog.key(address: address, transcriptPath: transcript),
                                   afterItemID: item, receipt: receipt, detail: detail, detailMayBeCut: detailMayBeCut, saved: saved)
                feedback = AnswerFeedback(denied: PromptOptionKind(label: answer.label) == .deny)
                AccessibilityNotification.Announcement("\(receipt) · \(title)").post()
                thread.connection.refreshActivity()
                // The receipt holds a moment, and until the status stops changing: an agent that
                // picks up and soon finishes would take the row to Working, then on to Done (round 6).
                // Longer with VoiceOver or at accessibility sizes (round 43: sb#3, at large text
                // the receipt was gone before it could be read).
                let lingers = UIAccessibility.isVoiceOverRunning || UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
                await Self.settle(address, in: thread.connection, holding: .seconds(lingers ? 2.5 : 0.8))
            } catch {
                failure = Failure(title: "Couldn't Answer \(title)", message: PromptDriverError.message(for: error), open: route)
            }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.15) : .snappy) { entries[address] = nil }
        }
    }

    /// Returns once `holding` has passed and the agent's shown status has held for 0.4 s, or
    /// 1 s after that at most (round 7: 3 s let a row move 4.7 s after the answer, under a
    /// reader already on the next one; round 8: at 1.2 s + 1.5 s the list still moved for 4.7 s).
    private static func settle(_ address: PaneAddress, in connection: HostConnection, holding: Duration) async {
        func status() -> AgentStatus? {
            connection.snapshot?.agents.first { $0.paneID == address.paneID }.map(connection.presentedStatus)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + holding + .seconds(1)
        var last = status(), since = start
        while clock.now < deadline,
              start.duration(to: clock.now) < holding || since.duration(to: clock.now) < .milliseconds(400) {
            try? await Task.sleep(for: .milliseconds(150))
            let now = status()
            if now != last { last = now; since = clock.now }
        }
    }
}

/// What a Needs You row can answer in place: a screen approval, or an ask's one question.
enum InlineChoices {
    case approval(ScreenPrompt)
    case ask(AskQuestion)
}

/// An inline answer under way or just confirmed: the approval or ask it answers (kept on the
/// row after the screen moves on), the option chosen, the row's rank when it was chosen (its
/// place until it settles) and, once confirmed, the receipt ("Approved").
struct InlineAnswer {
    let prompt: ScreenPrompt?
    let ask: AskActivity?
    let label: String
    let rank: InboxRank
    var receipt: String?
}

/// A confirmed inline answer, for its haptic: a light tap for Deny, success otherwise.
struct AnswerFeedback: Equatable {
    let id = UUID()
    let denied: Bool
}
