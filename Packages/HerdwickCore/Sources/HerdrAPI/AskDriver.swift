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
    public var note: String?
    public init(selected: [String] = [], custom: String? = nil, note: String? = nil) {
        self.selected = selected; self.custom = custom; self.note = note
    }
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
    /// A reply this driver hasn't verified against the agent.
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
///   Enter submits while retaining checked options; `n` edits a note and returns to the question.
///   Several questions (or any checkboxes) end on a "Review answers" page.
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
            if !question.multi {
                guard reply.selected.count + (custom ? 1 : 0) == 1 else { throw PromptDriverError.unsupported }
            }
        }

        var screen = try await current(io)
        guard screen.style != .choice else { throw PromptDriverError.noPrompt }
        guard belongs(screen, to: ask) else { throw PromptDriverError.questionMismatch }
        if screen.style != .ompAsk && zip(ask.questions, replies).contains(where: {
            ($0.0.multi && $0.1.custom != nil) || $0.1.note != nil
        }) { throw PromptDriverError.unsupported }
        if screen.phase == .review { return try await submit(review: screen, ask, replies: replies, io: io, settle: settle, confirmTimeout: confirmTimeout) }
        guard screen.phase == .question else { throw PromptDriverError.noPrompt }
        let initial = ask.questions.indices.filter { matches(screen, ask.questions[$0]) }
        guard initial.count == 1, let first = initial.first else { throw PromptDriverError.questionMismatch }
        var answered = first - 1
        for _ in 0..<(ask.questions.count + 2) {
            guard belongs(screen, to: ask) else { throw PromptDriverError.questionMismatch }
            switch screen.phase {
            case .review:
                guard answered == ask.questions.count - 1 else { throw PromptDriverError.unexpectedScreen }
                return try await submit(review: screen, ask, replies: replies, io: io, settle: settle, confirmTimeout: confirmTimeout)
            case .customInput, .noteInput:
                throw PromptDriverError.unexpectedScreen
            case .question:
                let candidates = ask.questions.indices.filter { matches(screen, ask.questions[$0]) }
                guard candidates.count == 1, let index = candidates.first else {
                    throw answered < 0 ? PromptDriverError.questionMismatch : PromptDriverError.unexpectedScreen
                }
                guard index == answered + 1 else { throw PromptDriverError.unexpectedScreen }
                try await answer(ask.questions[index], with: replies[index], belongingTo: ask, on: screen, io: io, settle: settle)
                answered = index
            }
            // Wait for the prompt to settle past the question just answered. The screen lags the
            // keys: the next reads can still show the free-text box closing, or a frame drawn
            // halfway that parses as no prompt or an unknown question.
            let question = ask.questions[answered]
            let last = answered == ask.questions.count - 1
            let moved = try await awaitScreen(io, timeout: settle) { next in
                guard let next else { return last }
                switch next.phase {
                case .review: return true
                case .customInput, .noteInput: return false
                case .question: return !matches(next, question) && ask.questions.contains { matches(next, $0) }
                }
            }
            guard let moved else { throw PromptDriverError.unexpectedScreen }
            guard let next = moved else {
                return try await finish(ask, replies: replies, io: io, settle: settle, confirmTimeout: confirmTimeout)
            }
            screen = next
        }
        throw PromptDriverError.unexpectedScreen
    }

    /// Submits a review page that shows exactly these replies.
    private static func submit<IO: PromptIO>(review screen: ScreenPrompt, _ ask: AskActivity, replies: [QuestionReply], io: IO,
                                             settle: Duration, confirmTimeout: Duration) async throws {
        guard reviewAgrees(screen, with: ask, replies: replies),
              let submit = screen.options.firstIndex(where: { $0.isSubmit || $0.label == "Submit answers" })
        else { throw PromptDriverError.unexpectedScreen }
        _ = try await move(to: submit, on: screen, io: io, settle: settle) {
            belongs($0, to: ask) && reviewAgrees($0, with: ask, replies: replies) ? $0.cursor : nil
        }
        try await io.send(keys: ["enter"])
        try await confirm(ask, io: io, timeout: confirmTimeout)
    }

    /// After the last question the prompt looked closed, but a frame caught mid-redraw reads as
    /// no prompt too, and the review page may only be drawing. Until the agent logs the result,
    /// keep looking: a review page of this ask showing these answers is still submitted. Taking
    /// the blank frame as the end is what left asks on "Review answers" for the user to submit.
    private static func finish<IO: PromptIO>(_ ask: AskActivity, replies: [QuestionReply], io: IO,
                                             settle: Duration, confirmTimeout: Duration) async throws {
        let deadline = ContinuousClock.now + confirmTimeout
        while ContinuousClock.now < deadline {
            let poll = min(.milliseconds(250), deadline - ContinuousClock.now)
            if try await io.waitForResult(toolCallId: ask.toolCallId, timeout: poll) { return }
            if let screen = ScreenPrompt.parse(try await io.readVisible()), screen.phase == .review, belongs(screen, to: ask),
               ContinuousClock.now < deadline {
                return try await submit(review: screen, ask, replies: replies, io: io, settle: settle,
                                        confirmTimeout: max(.seconds(1), deadline - ContinuousClock.now))
            }
        }
        throw PromptDriverError.notConfirmed
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
        _ = try await move(to: target, on: screen, io: io, settle: settle) { sameChoice($0, screen) ? $0.cursor : nil }
        // A newly painted approval can precede its input handler becoming ready. Live omp
        // drops an immediate Enter on the already-selected row. Give that first frame time
        // to settle, then revalidate both the entire choice and the selected logical row.
        try await Task.sleep(for: .milliseconds(500))
        let ready = try await current(io)
        guard sameChoice(ready, expected), ready.cursor == target else { throw PromptDriverError.questionMismatch }
        try await io.send(keys: ["enter"])
        let gone = try await awaitScreen(io, timeout: confirmTimeout) { next in
            guard let next else { return true }
            return !sameChoice(next, expected)
        }
        guard gone != nil else { throw PromptDriverError.notConfirmed }
    }

    // MARK: One question

    /// Rows are logical: the question's options, then the agent's free-text row, then Claude's
    /// `Submit` row. A pane smaller than the prompt shows only some of them (omp scrolls its
    /// list), so every step locates the cursor by what the rows say, not where they sit.
    private static func answer<IO: PromptIO>(_ question: AskQuestion, with reply: QuestionReply, belongingTo ask: AskActivity,
                                             on screen: ScreenPrompt, io: IO, settle: Duration) async throws {
        let other = question.options.count
        func index(of label: String) throws -> Int {
            guard let index = question.options.firstIndex(where: { $0.label == label }) else { throw PromptDriverError.optionNotFound }
            return index
        }
        func move(to target: Int, on screen: ScreenPrompt) async throws -> ScreenPrompt {
            try await PromptDriver.move(to: target, on: screen, io: io, settle: settle) {
                belongs($0, to: ask) && matches($0, question) ? cursorRow($0, question) : nil
            }
        }
        var screen = screen
        if let note = reply.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard screen.style == .ompAsk else { throw PromptDriverError.unsupported }
            let target = try reply.selected.first.map(index(of:)) ?? other
            screen = try await move(to: target, on: screen)
            try await io.send(keys: ["n"])
            let box = try await awaitScreen(io, timeout: settle) { $0?.phase == .noteInput }
            guard box != nil else { throw PromptDriverError.unexpectedScreen }
            try await io.type(note)
            try await io.send(keys: ["enter"])
            let returned = try await awaitScreen(io, timeout: settle) {
                guard let next = $0 else { return false }
                return next.phase == .question && matches(next, question) && cursorRow(next, question) == target
            }
            guard let returned, let next = returned else { throw PromptDriverError.unexpectedScreen }
            screen = next
        }

        guard question.multi else {
            if let custom = reply.custom, reply.selected.isEmpty {
                let there = try await move(to: other, on: screen)
                guard let cursor = there.cursor, there.options[cursor].isOther else { throw PromptDriverError.unsupported }
                switch screen.style {
                case .ompAsk:
                    try await io.send(keys: ["enter"])
                    let box = try await awaitScreen(io, timeout: settle) { $0?.phase == .customInput }
                    guard box != nil else { throw PromptDriverError.unexpectedScreen }
                    try await io.type(custom)
                case .claudeAsk:
                    // Typing replaces "Type something." in place; the cursor stays on that row.
                    try await io.type(custom)
                    let prefix = String(custom.normalizedSpace.prefix(12))
                    let typed = try await awaitScreen(io, timeout: settle) { next in
                        guard let next, let cursor = next.cursor else { return false }
                        return next.options[cursor].number == other + 1 && next.options[cursor].label.hasPrefix(prefix)
                    }
                    guard typed != nil else { throw PromptDriverError.unexpectedScreen }
                case .choice:
                    throw PromptDriverError.unexpectedScreen
                }
                try await io.send(keys: ["enter"])
                return
            }
            _ = try await move(to: try index(of: reply.selected[0]), on: screen)
            try await io.send(keys: ["enter"])
            return
        }

        var current = screen
        let toggle = screen.style == .ompAsk ? "space" : "enter"
        for (target, option) in question.options.enumerated() {
            let want = reply.selected.contains(option.label)
            // A row scrolled out of view shows its box once the cursor reaches it.
            if checked(current, target, question) == nil { current = try await move(to: target, on: current) }
            guard let have = checked(current, target, question) else { throw PromptDriverError.unexpectedScreen }
            guard want != have else { continue }
            current = try await move(to: target, on: current)
            try await io.send(keys: [toggle])
            let toggled = try await awaitScreen(io, timeout: settle) { next in
                guard let next else { return false }
                return cursorRow(next, question) == target && checked(next, target, question) == want
            }
            guard let toggled, let next = toggled else { throw PromptDriverError.cursorLost }
            current = next
        }
        switch screen.style {
        case .ompAsk:
            if let custom = reply.custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current = try await move(to: other, on: current)
                guard let cursor = current.cursor, current.options[cursor].isOther else { throw PromptDriverError.unsupported }
                try await io.send(keys: ["enter"])
                let box = try await awaitScreen(io, timeout: settle) { $0?.phase == .customInput }
                guard box != nil else { throw PromptDriverError.unexpectedScreen }
                try await io.type(custom)
                // omp advances directly to review, retaining the checked options.
                try await io.send(keys: ["enter"])
                return
            }
            // Enter on "Other" would open its text box instead of confirming.
            if cursorRow(current, question) == other { current = try await move(to: 0, on: current) }
        case .claudeAsk:
            current = try await move(to: other + 1, on: current)
            guard let cursor = current.cursor, current.options[cursor].isSubmit else { throw PromptDriverError.unexpectedScreen }
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
    /// `locate` names the row the cursor is on; nil when the screen isn't the expected prompt.
    private static func move<IO: PromptIO>(to target: Int, on screen: ScreenPrompt, io: IO, settle: Duration,
                                           locate: (ScreenPrompt) -> Int?) async throws -> ScreenPrompt {
        guard var cursor = locate(screen) else { throw PromptDriverError.cursorLost }
        var current = screen
        while cursor != target {
            let down = target > cursor
            let expected = cursor + (down ? 1 : -1)
            try await io.send(keys: [down ? "down" : "up"])
            let landed = try await awaitScreen(io, timeout: settle) { next in
                guard let next else { return false }
                return locate(next) == expected
            }
            guard let landed, let next = landed else { throw PromptDriverError.cursorLost }
            current = next; cursor = expected
        }
        return current
    }

    private static func confirm<IO: PromptIO>(_ ask: AskActivity, io: IO, timeout: Duration) async throws {
        guard try await io.waitForResult(toolCallId: ask.toolCallId, timeout: timeout) else {
            throw PromptDriverError.notConfirmed
        }
    }

    /// The screen is asking `question`: its title, and rows that are the transcript's options
    /// in order. A title cut short (`…`) or wrapped, and a label cut short, match as a prefix.
    static func matches(_ screen: ScreenPrompt, _ question: AskQuestion) -> Bool {
        guard titleMatches(screen.title, question.question) else { return false }
        return rows(screen, question)?.isEmpty == false
    }

    private static func titleMatches(_ shown: String, _ expected: String) -> Bool {
        let cut = shown.hasSuffix("…")
        let title = comparable(cut ? String(shown.dropLast()) : shown)
        let expected = comparable(expected)
        return !title.isEmpty && (title == expected || (cut && expected.hasPrefix(title)))
    }

    /// The logical row of each visible row (options, then the free-text row, then Claude's
    /// `Submit`), or nil unless they are a consecutive run of `question`'s rows that only one
    /// window fits. omp scrolls a list taller than the pane, so the first visible row need not
    /// be the first option; a label cut short ("Deploy…") could be more than one, and a guess
    /// would press Enter on the wrong answer.
    static func rows(_ screen: ScreenPrompt, _ question: AskQuestion) -> [Int]? {
        let count = question.options.count
        guard !screen.options.isEmpty else { return nil }
        func fits(_ first: Int) -> Bool {
            screen.options.indices.allSatisfy { index in
                let option = screen.options[index], row = first + index
                if option.isSubmit { return row == count + 1 }
                // Claude numbers its rows; the free-text row shows whatever was typed into it.
                if let number = option.number, number - 1 != row { return false }
                if row == count { return option.isOther || option.number != nil }
                return row < count && !option.isOther && labelMatches(option, question.options[row].label)
            }
        }
        let windows = (0...(count + 1)).filter(fits)
        guard windows.count == 1, let first = windows.first else { return nil }
        return Array(first..<(first + screen.options.count))
    }

    private static func cursorRow(_ screen: ScreenPrompt, _ question: AskQuestion) -> Int? {
        guard let cursor = screen.cursor, let rows = rows(screen, question), rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    /// Whether option `row`'s box is ticked; nil when it isn't on screen.
    private static func checked(_ screen: ScreenPrompt, _ row: Int, _ question: AskQuestion) -> Bool? {
        guard let rows = rows(screen, question), let index = rows.firstIndex(of: row) else { return nil }
        return screen.options[index].checked
    }

    /// A label matches in full, or as the start of the option when the pane cut it short.
    /// One too long for its row continues on the indented lines under it, ahead of any description.
    private static func labelMatches(_ option: ScreenPrompt.Option, _ label: String) -> Bool {
        let shown = comparable(plain(option.label))
        let label = comparable(plain(label))
        guard !shown.isEmpty else { return false }
        if shown == label { return true }
        if option.label.hasSuffix("…") {
            let start = shown.dropLast()
            return !start.isEmpty && label.hasPrefix(start)
        }
        guard label.hasPrefix(shown), let detail = option.detail else { return false }
        return comparable(plain(option.label + " " + detail)).hasPrefix(label)
    }

    private static func plain(_ label: String) -> String {
        label.replacingOccurrences(of: " (Recommended)", with: "")
    }

    /// Transcript text as the agent's screen shows it, for comparing the two. omp renders a
    /// question and its labels as markdown: emphasis and code markers dropped, a link as its
    /// text, entities decoded, paragraphs run together. Both sides lose markup and spacing.
    static func comparable(_ text: String) -> String {
        var text = text.replacing(/(?m)^ {0,3}#{1,6} +/, with: "")
            .replacing(/(?m)^ *(```|~~~)[^\n]*$/, with: "")
            .replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text.unicodeScalars.removeAll { $0.properties.isWhitespace || "*_`~\\<>".unicodeScalars.contains($0) }
        return text
    }

    private static func sameChoice(_ a: ScreenPrompt, _ b: ScreenPrompt) -> Bool {
        a.style == .choice && b.style == .choice && a.representsSameWait(as: b)
    }
    /// A tab row, when present, identifies the ask independently of the active question.
    /// This is essential when resuming from a later question or its review page. Only a
    /// single question may show none (omp's single-select); any tab shown must match.
    static func belongs(_ screen: ScreenPrompt, to ask: AskActivity) -> Bool {
        if ask.questions.count == 1 && screen.tabs.isEmpty { return true }
        guard screen.tabs.count == ask.questions.count else { return false }
        return zip(screen.tabs, ask.questions).allSatisfy { tab, question in
            let expected = question.header ?? question.id
            return comparable(tab) == comparable(expected)
        }
    }

    /// Review pages show the answers already entered. Never submit one unless every recorded
    /// answer agrees with the replies the app is about to claim it sent.
    private static func reviewAgrees(_ screen: ScreenPrompt, with ask: AskActivity,
                                     replies: [QuestionReply]) -> Bool {
        guard screen.phase == .review, screen.context.count >= ask.questions.count else { return false }
        for (question, reply) in zip(ask.questions, replies) {
            let expectedAnswers = reply.selected + (reply.custom.map { [$0] } ?? [])
            guard !expectedAnswers.isEmpty else { return false }
            let recorded: String
            switch screen.style {
            case .ompAsk:
                let identifier = question.header ?? question.id
                // The whole row label (`1. toppings:`), so one id can't match inside another.
                let label = comparable(identifier) + ":"
                guard let row = screen.context.firstIndex(where: { comparable($0).replacing(/^\d+\./, with: "", maxReplacements: 1).hasPrefix(label) }),
                      let colon = screen.context[row].firstIndex(of: ":") else { return false }
                let line = screen.context[row]
                recorded = String(line[line.index(after: colon)...])
                // A note shows on the next row; one there that the replies don't carry (or a
                // different one) means the page records something else. Only a row cut short
                // with "…" may show less than the reply's note.
                let next = screen.context.indices.contains(row + 1) ? comparable(screen.context[row + 1]) : ""
                let cut = next.hasSuffix("…")
                let shown = next.hasPrefix("Note:") ? String(next.dropFirst(5)).replacingOccurrences(of: "…", with: "") : nil
                let note = reply.note.map(comparable).flatMap { $0.isEmpty ? nil : $0 }
                switch (note, shown) {
                case (nil, nil): break
                case let (note?, shown?) where note == shown || (cut && !shown.isEmpty && note.hasPrefix(shown)): break
                default: return false
                }
                // Text typed into "Other" shows as `Other: …`; none was sent, so none may be recorded.
                if reply.custom == nil && comparable(recorded).contains("Other:") { return false }
            case .claudeAsk:
                guard let index = screen.context.indices.first(where: {
                    comparable(screen.context[$0]).contains(comparable(question.question))
                }), screen.context.indices.contains(index + 1) else { return false }
                recorded = screen.context[index + 1].replacingOccurrences(of: "→", with: "")
            case .choice:
                return false
            }
            let answer = comparable(recorded)
            guard expectedAnswers.allSatisfy({ containsAnswer(answer, $0) }) else { return false }
            let unselected = question.options.map(\.label).filter { !reply.selected.contains($0) }
            guard !unselected.contains(where: { containsAnswer(answer, $0) }) else { return false }
        }
        return true
    }

    private static func containsAnswer(_ answer: String, _ label: String) -> Bool {
        let label = comparable(label)
        guard !label.isEmpty else { return false }
        var search = answer.startIndex..<answer.endIndex
        while let match = answer.range(of: label, range: search) {
            let before = match.lowerBound == answer.startIndex ? nil : answer[..<match.lowerBound].last
            let after = match.upperBound == answer.endIndex ? nil : answer[match.upperBound]
            if answerBoundary(before) && answerBoundary(after) { return true }
            search = match.upperBound..<answer.endIndex
        }
        return false
    }

    private static func answerBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return [",", ":", "“", "”", "\"", "'"].contains(character)
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
