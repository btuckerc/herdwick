import Foundation
import Testing
@testable import HerdrAPI

/// Visible text captured from the real agents with `pane.read --source visible`.
private func screen(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Screens"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct ScreenPromptTests {
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

/// The omp ask box with the cursor on row `cursor`.
private func askBox(cursor: Int, question: String) -> String {
    var lines = ["╭─ Ask ─╮", "│ \(question) │", "├───────┤"]
    for (index, label) in labels.enumerated() {
        lines.append(index == cursor ? "│ \u{F054} \u{F10C} \(label) │" : "│   \u{F10C} \(label) │")
    }
    lines += ["├───────┤", "│ Enter select · ↑/↓ move · Esc cancel │", "╰───────╯"]
    return lines.joined(separator: "\n")
}

/// Behaves like omp's single-question ask: arrows move, Enter on an option closes the box,
/// Enter on "Other" opens the custom-answer box, whose Enter closes it.
private final class FakeOmp: PromptIO, @unchecked Sendable {
    var cursor = 1; var question: String; var keys: [String] = []; var typed: [String] = []
    var confirmed = true; var stuck = false; var closed = false; var customBox = false
    init(question: String = "Which colour should the sheep be?") { self.question = question }
    func readVisible() async throws -> String {
        if closed { return "❯ \n" }
        if customBox { return "╭─ Custom answer: \(question) ─╮\n│ > │\n╰──╯" }
        return askBox(cursor: cursor, question: question)
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
        }
    }
    func type(_ text: String) async throws { typed.append(text) }
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool { confirmed }
}

private let sheep = AskActivity(toolCallId: "x", questions: [
    AskQuestion(id: "q", question: "Which colour should the sheep be?",
                options: [AskOption(label: "Red"), AskOption(label: "Green"), AskOption(label: "Blue")]),
])

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
}
