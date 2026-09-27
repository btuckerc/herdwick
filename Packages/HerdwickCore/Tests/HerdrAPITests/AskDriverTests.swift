import Foundation
import Testing
@testable import HerdrAPI

/// Visible text captured from the real agents with `pane.read --source visible`.
private func screen(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Screens"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct ScreenPromptTests {
    @Test func ompApprovalsAndPlan() throws {
        for (fixture, tool) in [("omp-approval", "bash"), ("omp-approval-write", "write")] {
            let prompt = try #require(ScreenPrompt.parse(screen(fixture)))
            #expect(prompt.title == "Allow \(tool)?")
            #expect(prompt.options.map(\.label) == ["Approve", "Deny"])
            #expect(prompt.cursor == 0)
            #expect(prompt.context.contains(where: { $0.hasPrefix(tool == "bash" ? "Command:" : "Path:") }))
        }
        let plan = try #require(ScreenPrompt.parse(screen("omp-plan-review")))
        #expect(plan.title == "Plan Review")
        #expect(plan.contextMayBeTruncated)
        #expect(plan.context.first == "Approach")
        #expect(plan.options.map(\.label) == ["Approve and execute", "Approve and compact context",
                                            "Approve and keep context (~10k / 200k)", "Refine plan", "Save and quit"])
        #expect(plan.cursor == 0)
    }
    @Test func ompSingleQuestion() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("omp-single")))
        #expect(prompt.style == .ompAsk)
        #expect(prompt.title == "Which colour should the sheep be?")
        #expect(prompt.tabs.isEmpty)
        #expect(prompt.options.map(\.label) == ["Red", "Green", "Blue", "Other (type your own)"])
        #expect(prompt.options.map(\.detail) == ["warm", "grass", "sky", nil])
        #expect(prompt.options.last?.isOther == true)
        #expect(prompt.cursor == 1)
    }

    @Test func ompTabsAreNotPartOfTheQuestion() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("omp-multiq")))
        #expect(prompt.tabs == ["size", "drink"])
        #expect(prompt.title == "Which size?")
        #expect(prompt.options.map(\.label) == ["Small", "Medium", "Large", "Other (type your own)"])
        #expect(prompt.cursor == 1)
    }

    @Test func ompCustomAnswerBoxAndReview() throws {
        let custom = try #require(ScreenPrompt.parse(try screen("omp-custom")))
        #expect(custom.phase == .customInput)
        #expect(custom.title == "Which drink?")
        let review = try #require(ScreenPrompt.parse(try screen("omp-review")))
        #expect(review.phase == .review)
        #expect(review.options.map(\.isSubmit) == [true])
        #expect(review.cursor == 0)
        #expect(review.context == ["1. size: Large", "2. drink: “Sparkling water”"])
    }

    /// A pane smaller than the prompt: omp cuts the question and scrolls the options.
    @Test func ompScrolledOptionsInASmallPane() throws {
        let top = try #require(ScreenPrompt.parse(try screen("omp-scrolled-top")))
        #expect(top.title.hasSuffix("can hammer a host tha…"))
        #expect(top.options.map(\.label) == ["Keep current exponential backoff unchanged",
                                             "Exponential backoff with jitter, 4-second cap",
                                             "Fixed one-second retries, then back off"])
        #expect(top.cursor == 1)
        #expect(PromptDriver.rows(top, retry) == [0, 1, 2])
        #expect(PromptDriver.matches(top, retry))
        let end = try #require(ScreenPrompt.parse(try screen("omp-scrolled-end")))
        #expect(end.options.map(\.label) == ["Fixed one-second retries, then back off",
                                             "Retry immediately on each network change",
                                             "Other (type your own)"])
        #expect(end.options.first?.detail == "The first five attempts run a second apart, then fall back to the 8-second cadence.")
        #expect(PromptDriver.rows(end, retry) == [2, 3, 4])
        #expect(PromptDriver.matches(end, retry))
    }

    /// A label cut short that more than one option starts with is not guessed at.
    @Test func ambiguousWindowMatchesNothing() {
        let deploy = AskQuestion(id: "d", question: "Where?", options: [AskOption(label: "Deploy staging"), AskOption(label: "Deploy production")])
        let cut = ScreenPrompt(style: .ompAsk, title: "Where?", options: [.init(label: "Deploy…")], cursor: 0)
        #expect(PromptDriver.rows(cut, deploy) == nil)
        let whole = ScreenPrompt(style: .ompAsk, title: "Where?", options: [.init(label: "Deploy…"), .init(label: "Other (type your own)", isOther: true)], cursor: 0)
        #expect(PromptDriver.rows(whole, deploy) == [1, 2])
    }

    /// Only a label the pane cut short (`…`) may stand for a longer one: a complete "Deploy"
    /// is a different option from "Deploy production".
    @Test func uncutLabelMustMatchInFull() {
        let deploy = AskQuestion(id: "d", question: "Where?", options: [AskOption(label: "Deploy production"), AskOption(label: "Wait")])
        let other = ScreenPrompt.Option(label: "Other (type your own)", isOther: true)
        let whole = ScreenPrompt(style: .ompAsk, title: "Where?", options: [.init(label: "Deploy"), .init(label: "Wait"), other], cursor: 0)
        #expect(PromptDriver.rows(whole, deploy) == nil)
        let cut = ScreenPrompt(style: .ompAsk, title: "Where?", options: [.init(label: "Deploy pro…"), .init(label: "Wait"), other], cursor: 0)
        #expect(PromptDriver.rows(cut, deploy) == [0, 1, 2])
    }

    @Test func claudeQuestionWithTabs() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("claude-ask-q1")))
        #expect(prompt.style == .claudeAsk)
        #expect(prompt.tabs == ["Color", "Toppings"])
        #expect(prompt.title == "Which color?")
        #expect(prompt.options.map(\.label) == ["Red", "Green", "Blue", "Type something."])
        #expect(prompt.options.first?.detail == "A classic bold color.")
        #expect(prompt.options.last?.isOther == true)
        #expect(prompt.cursor == 0)
    }

    @Test func claudeCheckboxesAndSubmitRow() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("claude-ask-q2")))
        #expect(prompt.title == "Which toppings?")
        #expect(prompt.options.map(\.label) == ["Cheese", "Olives", "Basil", "Type something", "Submit"])
        #expect(prompt.options.map(\.checked) == [false, false, false, false, nil])
        #expect(prompt.options.last?.isSubmit == true)
    }

    @Test func claudeReviewAndSingleQuestion() throws {
        let review = try #require(ScreenPrompt.parse(try screen("claude-ask-review")))
        #expect(review.phase == .review)
        #expect(review.options.map(\.label) == ["Submit answers", "Cancel"])
        let single = try #require(ScreenPrompt.parse(try screen("claude-ask-single")))
        #expect(single.tabs == ["Pet"])
        #expect(single.title == "Pick a pet")
        #expect(single.options.map(\.label) == ["Cat", "Dog", "Type something."])
        let typed = try #require(ScreenPrompt.parse(try screen("claude-ask-other")))
        #expect(typed.options.map(\.label) == ["Cat", "Dog", "Hamster"])
        #expect(typed.cursor == 2)
    }

    @Test func claudePermissions() throws {
        let bash = try #require(ScreenPrompt.parse(try screen("claude-perm-bash")))
        #expect(bash.style == .choice)
        #expect(bash.title == "Do you want to proceed?")
        #expect(bash.context == ["Bash command", "date > when.txt && cat when.txt", "Write current date to when.txt and display it"])
        #expect(bash.options.map(\.label) == ["Yes", "Yes, and always allow access to /tmp/hw-agents/work from this project", "No"])
        #expect(bash.cursor == 0)
        let edit = try #require(ScreenPrompt.parse(try screen("claude-perm-edit")))
        #expect(edit.title == "Do you want to make this edit to notes.md?")
        #expect(edit.context.first == "Edit file")
        #expect(edit.options.count == 3)
    }

    @Test func codexApproval() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("codex-approval-exec")))
        #expect(prompt.style == .choice)
        #expect(prompt.title == "Would you like to run the following command?")
        #expect(prompt.context == ["Environment: local",
                                   "Reason: Do you want to allow network access to run this curl request to example.com?",
                                   "$ curl -sI https://example.com | head -1"])
        #expect(prompt.options.map(\.label) == [
            "Yes, proceed",
            "Yes, and don't ask again for commands that start with `curl -sI https://example.com`",
            "No, and tell Codex what to do differently",
        ])
    }

    /// With history filling the screen there is no blank gap above the prompt; nothing from
    /// the transcript may leak into the prompt's details.
    @Test func codexApprovalBelowHistory() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("codex-approval-history")))
        #expect(prompt.title == "Would you like to run the following command?")
        #expect(prompt.context == ["Environment: local", "Reason: Allow network access to fetch example.org?",
                                   "$ curl -sI https://example.org | head -1"])
        #expect(prompt.options.first?.label == "Yes, proceed")
    }

    @Test func plainTranscriptIsNoPrompt() {
        #expect(ScreenPrompt.parse("❯ Run the tests\n\n● 1. First step\n  2. Second step\n") == nil)
    }
}

// MARK: - Driver

private let labels = ["Red", "Green (Recommended)", "Blue", "Other (type your own)"]

/// The omp ask box with the cursor on row `cursor`. With `window`, only rows `top..<top+window`
/// show, with a scrollbar and the question cut short, as in a pane too small for the prompt.
private func askBox(cursor: Int, question: String, top: Int = 0, window: Int? = nil) -> String {
    let scrolled = window != nil
    let title = scrolled ? String(question.prefix(12)) + "…" : question
    var lines = ["╭─ Ask ─╮", "│ \(title) │", "├───────┤"]
    for (index, label) in labels.enumerated() where index >= top && index < top + (window ?? labels.count) {
        let bar = scrolled ? (index == top ? " █" : " │") : ""
        lines.append(index == cursor ? "│ \u{F054} \u{F10C} \(label)\(bar) │" : "│   \u{F10C} \(label)\(bar) │")
    }
    lines += ["├───────┤", "│ Enter select · ↑/↓ move · Esc cancel │", "╰───────╯"]
    return lines.joined(separator: "\n")
}

/// Behaves like omp's single-question ask: arrows move, Enter on an option closes the box,
/// Enter on "Other" opens the custom-answer box, whose Enter closes it.
private final class FakeOmp: PromptIO, @unchecked Sendable {
    var cursor = 1; var question: String; var keys: [String] = []; var typed: [String] = []
    var confirmed = true; var stuck = false; var closed = false; var customBox = false
    var window: Int?; var top = 0
    init(question: String = "Which colour should the sheep be?", window: Int? = nil) {
        self.question = question; self.window = window
    }
    func readVisible() async throws -> String {
        if closed { return "❯ \n" }
        if customBox { return "╭─ Custom answer: \(question) ─╮\n│ > │\n╰──╯" }
        return askBox(cursor: cursor, question: question, top: top, window: window)
    }
    func send(keys: [String]) async throws {
        self.keys += keys
        guard !stuck else { return }
        for key in keys {
            switch key {
            case "down": cursor = min(cursor + 1, labels.count - 1)
            case "up": cursor = max(cursor - 1, 0)
            case "enter" where customBox: customBox = false; closed = true
            case "enter" where cursor == labels.count - 1: customBox = true
            case "enter": closed = true
            default: break
            }
            if let window { top = min(max(top, cursor - window + 1), cursor) }
        }
    }
    func type(_ text: String) async throws { typed.append(text) }
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool { confirmed }
}

private let sheep = AskActivity(toolCallId: "x", questions: [
    AskQuestion(id: "q", question: "Which colour should the sheep be?",
                options: [AskOption(label: "Red"), AskOption(label: "Green"), AskOption(label: "Blue")]),
])

private let retry = AskQuestion(id: "retry_policy", question: "Reconnects to one host keep failing a few times in a row before succeeding, and the current backoff of 0.5, 1, 2, 4, then 8 seconds makes the inbox sit on \"Reconnecting…\" for a long time. I can change how quickly and how often the supervisor retries, but faster retries cost battery and can hammer a host that is really down. Which retry policy should the reconnect use?", options: [
    AskOption(label: "Keep current exponential backoff unchanged"),
    AskOption(label: "Exponential backoff with jitter, 4-second cap"),
    AskOption(label: "Fixed one-second retries, then back off"),
    AskOption(label: "Retry immediately on each network change"),
], recommended: 1)

@Suite struct PromptDriverTests {
    private let fast = Duration.milliseconds(200)

    @Test func movesOneKeyAtATimeAndConfirms() async throws {
        let io = FakeOmp()
        try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Blue"])], io: io, settle: fast)
        #expect(io.keys == ["down", "enter"])
        let up = FakeOmp()
        try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Red"])], io: up, settle: fast)
        #expect(up.keys == ["up", "enter"])
    }

    @Test func questionMismatchSendsNothing() async {
        let io = FakeOmp(question: "Wrong colour should the sheep be?")
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Blue"])], io: io, settle: fast)
        }
        #expect(io.keys.isEmpty)
    }

    @Test func changedOptionsSendNothing() async {
        let io = FakeOmp()
        let stale = AskActivity(toolCallId: "x", questions: [
            AskQuestion(id: "q", question: sheep.questions[0].question, options: [AskOption(label: "Red"), AskOption(label: "Pink")]),
        ])
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.answer(stale, replies: [QuestionReply(selected: ["Red"])], io: io, settle: fast)
        }
        #expect(io.keys.isEmpty)
    }

    @Test func cursorThatDoesNotMoveNeverPressesEnter() async {
        let io = FakeOmp(); io.stuck = true
        await #expect(throws: PromptDriverError.cursorLost) {
            try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Blue"])], io: io, settle: fast)
        }
        #expect(!io.keys.contains("enter"))
    }

    @Test func otherOpensTheBoxTypesAndSubmits() async throws {
        let io = FakeOmp()
        try await PromptDriver.answer(sheep, replies: [QuestionReply(custom: "Purple")], io: io, settle: fast)
        #expect(io.typed == ["Purple"])
        #expect(io.keys == ["down", "down", "enter", "enter"])
    }

    @Test func unverifiedRepliesSendNothing() async {
        let io = FakeOmp()
        await #expect(throws: PromptDriverError.unsupported) {
            try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Red", "Blue"])], io: io, settle: fast)
        }
        #expect(io.keys.isEmpty)
    }

    @Test func notConfirmed() async {
        let io = FakeOmp(); io.confirmed = false
        await #expect(throws: PromptDriverError.notConfirmed) {
            try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Green"])], io: io, settle: fast)
        }
    }

    /// Only two rows fit: moving scrolls the list, so rows are followed by label, not position.
    @Test func scrolledListIsFollowedByLabel() async throws {
        let io = FakeOmp(window: 2)
        try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Blue"])], io: io, settle: fast)
        #expect(io.keys == ["down", "enter"])
        let other = FakeOmp(window: 2)
        try await PromptDriver.answer(sheep, replies: [QuestionReply(custom: "Purple")], io: other, settle: fast)
        #expect(other.typed == ["Purple"])
        #expect(other.keys == ["down", "down", "enter", "enter"])
    }
}

/// Replays real screens, advancing only when the expected input is sent.
private final class PromptReplay: PromptIO, @unchecked Sendable {
    var visible: String
    var steps: [(String, String)]
    var confirmed: Bool
    var confirmations = 0
    init(_ visible: String, steps: [(String, String)], confirmed: Bool = true) {
        self.visible = visible; self.steps = steps; self.confirmed = confirmed
    }
    func readVisible() async throws -> String { visible }
    func send(keys: [String]) async throws {
        for key in keys { try advance(key) }
    }
    func type(_ text: String) async throws { try advance("type:" + text) }
    private func advance(_ input: String) throws {
        guard let step = steps.first, step.0 == input else { throw PromptDriverError.unexpectedScreen }
        steps.removeFirst()
        visible = step.1
    }
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool {
        confirmations += 1
        return confirmed
    }
}

@Suite struct OmpRichPromptTests {
    @Test func multiCustomPreservesChecksAndNoteAndRequiresResult() async throws {
        let initial = try screen("omp-rich-multi")
        let noted = try screen("omp-rich-noted")
        let checked = noted.replacingOccurrences(of: " Apple", with: " Apple")
        let pear = checked.replacingOccurrences(of: " ", with: "  ")
            .replacingOccurrences(of: "   Pear", with: "  Pear")
        let other = pear.replacingOccurrences(of: "  Pear", with: "   Pear")
            .replacingOccurrences(of: "   Other", with: "  Other")
        let noteBox = try screen("omp-rich-note")
        let customBox = try screen("omp-rich-custom")
        let review = try screen("omp-rich-review")
        let ask = AskActivity(toolCallId: "rich", questions: [
            AskQuestion(id: "toppings", question: "Choose toppings",
                        options: [.init(label: "Apple"), .init(label: "Pear")], multi: true)
        ])
        for confirmed in [true, false] {
            let io = PromptReplay(initial, steps: [
                ("n", noteBox), ("type:Keep the peel", noteBox), ("enter", noted),
                ("space", checked), ("down", pear), ("down", other), ("enter", customBox),
                ("type:Banana", customBox), ("enter", review), ("enter", "Working…")
            ], confirmed: confirmed)
            if confirmed {
                try await PromptDriver.answer(ask, replies: [.init(selected: ["Apple"], custom: "Banana", note: "Keep the peel")],
                                              io: io, settle: .zero)
            } else {
                await #expect(throws: PromptDriverError.notConfirmed) {
                    try await PromptDriver.answer(ask, replies: [.init(selected: ["Apple"], custom: "Banana", note: "Keep the peel")],
                                                  io: io, settle: .zero)
                }
            }
            #expect(io.steps.isEmpty)
            #expect(io.confirmations == 1)
        }
    }

    @Test func choicesRevalidateEveryMove() async throws {
        for name in ["omp-approval", "omp-approval-write", "omp-plan-review"] {
            let first = try screen(name)
            let expected = try #require(ScreenPrompt.parse(first))
            let label = expected.options[1].label
            let second = first.replacingOccurrences(of: " " + expected.options[0].label, with: "  " + expected.options[0].label)
                .replacingOccurrences(of: "  " + label, with: " " + label)
            let io = PromptReplay(first, steps: [("down", second), ("enter", "Working…")])
            try await PromptDriver.choose(label, on: expected, io: io, settle: .zero)
            #expect(io.steps.isEmpty)
            #expect(io.confirmations == 0)
        }
    }

    @Test func changedApprovalContextNeverSends() async throws {
        let first = try screen("omp-approval-write")
        let expected = try #require(ScreenPrompt.parse(first))
        let io = PromptReplay(first.replacingOccurrences(of: "b.txt", with: "secret.txt"), steps: [])
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.choose("Approve", on: expected, io: io, settle: .zero)
        }
    }
}
