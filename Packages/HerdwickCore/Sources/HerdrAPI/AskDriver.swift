import Foundation

/// The terminal an agent's prompt lives in.
public protocol PromptIO: Sendable {
    func readVisible() async throws -> String
    func send(keys: [String]) async throws
    func type(_ text: String) async throws
    /// Whether the agent logged a result for `toolCallId` within `timeout`: the only proof
    /// that an answer typed into its prompt was taken.
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool
}

/// The answer to one question of an ask: chosen option labels, or free text for "Other".
public struct QuestionReply: Sendable, Equatable {
    public var selected: [String]
    public var custom: String?
    public init(selected: [String] = [], custom: String? = nil) { self.selected = selected; self.custom = custom }
}

public enum PromptDriverError: Error, Equatable {
    /// Nothing on the agent's screen to answer.
    case noPrompt
    /// The screen shows a different question than the transcript.
    case questionMismatch
    /// The screen's options differ from the transcript's, or the choice isn't among them.
    case optionNotFound
    /// A key didn't move the cursor or toggle the box the way it should have.
    case cursorLost
    /// The prompt went somewhere the driver didn't expect, so it stopped.
    case unexpectedScreen
    /// A reply this driver hasn't verified against the agent (e.g. free text on a multi-select).
    case unsupported
    /// Every key landed but the agent never logged the answer.
    case notConfirmed
}

/// Answers an agent's own terminal prompt one key at a time, re-reading the screen after
/// every key and stopping the moment it doesn't match what the transcript says is there.
///
/// Key sequences, verified live (omp 18.3, Claude Code 2.1, Codex 0.157):
/// - omp: ↑/↓ move; Enter picks a radio option (and advances to the next question); Space
///   toggles a box, Enter confirms the question; Enter on "Other" opens a text box whose
///   Enter submits; several questions (or any checkboxes) end on a "Review answers" page.
/// - Claude: ↑/↓ move; Enter picks a numbered option; on checkboxes Enter toggles and the
///   `Submit` row confirms; typing on "Type something." replaces it with the text; several
///   questions end on "Review your answers" → "Submit answers".
/// - Choice prompts: ↑/↓ to the option, Enter.
public enum PromptDriver {
    public static func answer<IO: PromptIO>(_ ask: AskActivity, replies: [QuestionReply], io: IO,
                                             settle: Duration = .seconds(2),
                                             confirmTimeout: Duration = .seconds(10)) async throws {
        guard replies.count == ask.questions.count, !ask.questions.isEmpty else { throw PromptDriverError.unsupported }
        for (question, reply) in zip(ask.questions, replies) {
            let labels = Set(question.options.map(\.label))
            guard reply.selected.allSatisfy(labels.contains) else { throw PromptDriverError.optionNotFound }
            let custom = reply.custom.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            if question.multi {
                guard !custom else { throw PromptDriverError.unsupported }
            } else {
                guard reply.selected.count + (custom ? 1 : 0) == 1 else { throw PromptDriverError.unsupported }
            }
        }

        var screen = try await current(io)
        guard screen.style != .choice, screen.phase == .question else { throw PromptDriverError.noPrompt }
        guard matches(screen, ask.questions[0]) else { throw PromptDriverError.questionMismatch }

        var answered = -1
        for _ in 0..<(ask.questions.count + 2) {
            switch screen.phase {
            case .review:
                guard answered == ask.questions.count - 1,
                      let submit = screen.options.firstIndex(where: { $0.isSubmit || $0.label == "Submit answers" })
                else { throw PromptDriverError.unexpectedScreen }
                _ = try await move(to: submit, on: screen, io: io, settle: settle)
                try await io.send(keys: ["enter"])
                return try await confirm(ask, io: io, timeout: confirmTimeout)
            case .customInput:
                throw PromptDriverError.unexpectedScreen
            case .question:
                guard let index = ask.questions.firstIndex(where: { matches(screen, $0) }) else {
                    throw PromptDriverError.questionMismatch
                }
                guard index == answered + 1 else { throw PromptDriverError.unexpectedScreen }
                try await answer(ask.questions[index], with: replies[index], on: screen, io: io, settle: settle)
                answered = index
            }
            // Wait for the prompt to leave the question just answered.
            let question = ask.questions[answered]
            let moved = try await awaitScreen(io, timeout: settle) { next in
                guard let next else { return true }
                return next.phase != .question || !matches(next, question)
            }
            guard let moved else { throw PromptDriverError.unexpectedScreen }
            guard let next = moved else {
                guard answered == ask.questions.count - 1 else { throw PromptDriverError.unexpectedScreen }
                return try await confirm(ask, io: io, timeout: confirmTimeout)
            }
            screen = next
        }
        throw PromptDriverError.unexpectedScreen
    }

    /// Picks `label` on a numbered choice prompt (a permission or approval) that still looks
    /// like `expected`, then waits for the prompt to leave the screen.
    public static func choose<IO: PromptIO>(_ label: String, on expected: ScreenPrompt, io: IO,
                                             settle: Duration = .seconds(2),
                                             confirmTimeout: Duration = .seconds(6)) async throws {
        let screen = try await current(io)
        guard screen.style == .choice else { throw PromptDriverError.noPrompt }
        guard sameChoice(screen, expected) else { throw PromptDriverError.questionMismatch }
        guard let target = screen.options.firstIndex(where: { $0.label == label }) else {
            throw PromptDriverError.optionNotFound
        }
        _ = try await move(to: target, on: screen, io: io, settle: settle)
        try await io.send(keys: ["enter"])
        let gone = try await awaitScreen(io, timeout: confirmTimeout) { next in
            guard let next else { return true }
            return !sameChoice(next, expected)
        }
        guard gone != nil else { throw PromptDriverError.notConfirmed }
    }

    // MARK: One question

    private static func answer<IO: PromptIO>(_ question: AskQuestion, with reply: QuestionReply, on screen: ScreenPrompt,
                                             io: IO, settle: Duration) async throws {
        let rows = screen.options.indices.filter { !screen.options[$0].isSubmit }
        let otherRow = rows.count > question.options.count ? rows[question.options.count] : nil
        func row(of label: String) throws -> Int {
            guard let index = question.options.firstIndex(where: { $0.label == label }) else { throw PromptDriverError.optionNotFound }
            return rows[index]
        }

        guard question.multi else {
            if let custom = reply.custom, reply.selected.isEmpty {
                guard let otherRow else { throw PromptDriverError.unsupported }
                _ = try await move(to: otherRow, on: screen, io: io, settle: settle)
                switch screen.style {
                case .ompAsk:
                    try await io.send(keys: ["enter"])
                    let box = try await awaitScreen(io, timeout: settle) { $0?.phase == .customInput }
                    guard box != nil else { throw PromptDriverError.unexpectedScreen }
                    try await io.type(custom)
                case .claudeAsk:
                    try await io.type(custom)
                    let prefix = String(custom.normalizedSpace.prefix(12))
                    let typed = try await awaitScreen(io, timeout: settle) { next in
                        guard let next, next.options.indices.contains(otherRow) else { return false }
                        return next.options[otherRow].label.hasPrefix(prefix)
                    }
                    guard typed != nil else { throw PromptDriverError.unexpectedScreen }
                case .choice:
                    throw PromptDriverError.unexpectedScreen
                }
                try await io.send(keys: ["enter"])
                return
            }
            _ = try await move(to: try row(of: reply.selected[0]), on: screen, io: io, settle: settle)
            try await io.send(keys: ["enter"])
            return
        }

        var current = screen
        let toggle = screen.style == .ompAsk ? "space" : "enter"
        for (index, option) in question.options.enumerated() {
            let target = rows[index]
            let want = reply.selected.contains(option.label)
            guard let have = current.options[target].checked else { throw PromptDriverError.unexpectedScreen }
            guard want != have else { continue }
            current = try await move(to: target, on: current, io: io, settle: settle)
            try await io.send(keys: [toggle])
            let toggled = try await awaitScreen(io, timeout: settle) { next in
                guard let next, next.options.indices.contains(target) else { return false }
                return next.options[target].checked == want
            }
            guard let toggled, let next = toggled else { throw PromptDriverError.cursorLost }
            current = next
        }
        switch screen.style {
        case .ompAsk:
            // Enter on "Other" would open its text box instead of confirming.
            if current.cursor == otherRow { current = try await move(to: rows[0], on: current, io: io, settle: settle) }
        case .claudeAsk:
            guard let submit = current.options.firstIndex(where: \.isSubmit) else { throw PromptDriverError.unexpectedScreen }
            current = try await move(to: submit, on: current, io: io, settle: settle)
        case .choice:
            throw PromptDriverError.unexpectedScreen
        }
        try await io.send(keys: ["enter"])
    }

    // MARK: Screen

    private static func current<IO: PromptIO>(_ io: IO) async throws -> ScreenPrompt {
        guard let screen = ScreenPrompt.parse(try await io.readVisible()) else { throw PromptDriverError.noPrompt }
        return screen
    }

    /// Re-reads until `done` holds for the parsed prompt (nil when none is showing).
    /// Returns the matching read (`.some(nil)` when the prompt closed), or nil on timeout.
    private static func awaitScreen<IO: PromptIO>(_ io: IO, timeout: Duration,
                                                  _ done: (ScreenPrompt?) -> Bool) async throws -> ScreenPrompt?? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let screen = ScreenPrompt.parse(try await io.readVisible())
            if done(screen) { return .some(screen) }
            if ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Moves the cursor one row per key, checking every step landed where it should.
    private static func move<IO: PromptIO>(to target: Int, on screen: ScreenPrompt, io: IO,
                                           settle: Duration) async throws -> ScreenPrompt {
        guard var cursor = screen.cursor else { throw PromptDriverError.cursorLost }
        var current = screen
        var steps = 0
        while cursor != target {
            guard steps <= screen.options.count else { throw PromptDriverError.cursorLost }
            let down = target > cursor
            let expected = cursor + (down ? 1 : -1)
            try await io.send(keys: [down ? "down" : "up"])
            let landed = try await awaitScreen(io, timeout: settle) { next in
                guard let next else { return false }
                return next.cursor == expected && next.title == screen.title
            }
            guard let landed, let next = landed else { throw PromptDriverError.cursorLost }
            current = next; cursor = expected; steps += 1
        }
        return current
    }

    private static func confirm<IO: PromptIO>(_ ask: AskActivity, io: IO, timeout: Duration) async throws {
        guard try await io.waitForResult(toolCallId: ask.toolCallId, timeout: timeout) else {
            throw PromptDriverError.notConfirmed
        }
    }

    /// The screen is asking `question`, with the transcript's options in order.
    static func matches(_ screen: ScreenPrompt, _ question: AskQuestion) -> Bool {
        let title = screen.title.normalizedSpace, expected = question.question.normalizedSpace
        guard !title.isEmpty, title == expected || expected.hasPrefix(title) || title.hasPrefix(expected) else { return false }
        let labels = screen.options.filter { !$0.isSubmit }.prefix(question.options.count).map { plain($0.label) }
        return labels == question.options.map { plain($0.label) }
    }

    private static func plain(_ label: String) -> String {
        label.replacingOccurrences(of: " (Recommended)", with: "").normalizedSpace
    }

    private static func sameChoice(_ a: ScreenPrompt, _ b: ScreenPrompt) -> Bool {
        a.style == b.style && a.title == b.title && a.context == b.context && a.options.map(\.label) == b.options.map(\.label)
    }
}

public struct HerdrPromptIO: PromptIO {
    private let client: HerdrClient
    private let pane: String
    private let session: String
    private let result: @Sendable (String, Duration) async throws -> Bool
    public init(client: HerdrClient, pane: String, session: String,
                result: @escaping @Sendable (String, Duration) async throws -> Bool) {
        self.client = client; self.pane = pane; self.session = session; self.result = result
    }
    public func readVisible() async throws -> String { try await client.readPane(pane, session: session).text }
    public func send(keys: [String]) async throws { try await client.sendKeys(keys, pane: pane, session: session) }
    public func type(_ text: String) async throws { try await client.sendText(text, pane: pane, submit: false, session: session) }
    public func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool { try await result(toolCallId, timeout) }
}
