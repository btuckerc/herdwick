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
    @Test func ompTabsUseHeadersWhenPresent() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("omp-live-mixed")))
        let ask = AskActivity(toolCallId: "live", questions: [
            .init(id: "color", header: "Color", question: "Which color?",
                  options: [.init(label: "Red"), .init(label: "Green"), .init(label: "Blue")]),
            .init(id: "toppings", header: "Toppings", question: "Which toppings?",
                  options: [.init(label: "Cheese"), .init(label: "Olives"), .init(label: "Basil")], multi: true),
        ])
        #expect(prompt.tabs == ["Color", "Toppings"])
        #expect(PromptDriver.belongs(prompt, to: ask))
        #expect(PromptDriver.matches(prompt, ask.questions[0]))
        let other = AskActivity(toolCallId: "other", questions: [
            .init(id: "shade", header: "Shade", question: "Which color?", options: ask.questions[0].options),
            ask.questions[1],
        ])
        #expect(!PromptDriver.belongs(prompt, to: other))
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

    /// Six questions in a 56-column pane: the tab row wraps onto three lines.
    @Test func ompWrappedTabRowIsNotPartOfTheQuestion() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("omp-narrow-tabs")))
        #expect(prompt.tabs == ["deploy-target", "database-engine", "migration-window", "retry-policy", "test-coverage", "release-notes"])
        #expect(prompt.title == "Where should the api service deploy first?")
        #expect(PromptDriver.matches(prompt, deployTarget))
    }

    /// omp shows the question as rendered markdown and continues a long label on the line below.
    @Test func renderedMarkdownAndWrappedLabelMatchTheTranscript() throws {
        let prompt = try #require(ScreenPrompt.parse(try screen("omp-wrapped-label")))
        #expect(prompt.options.first?.label == "Staging cluster in us-east-1 behind the existing load balancer, with traffic mirrored from production for an")
        #expect(PromptDriver.rows(prompt, deployTarget) == [0, 1, 2, 3])
        #expect(PromptDriver.matches(prompt, deployTarget))
        let other = AskQuestion(id: "d", question: deployTarget.question, options: [AskOption(label: "Staging cluster in us-east-1 behind the existing load balancer, with traffic mirrored from production for an afternoon")] + deployTarget.options.dropFirst())
        #expect(!PromptDriver.matches(prompt, other))
        #expect(PromptDriver.comparable("Use **[the docs](https://x.dev)** &amp; `make  test`") == PromptDriver.comparable("Use the docs & make test"))
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
        #expect(review.context.contains("● Which color?"))
        #expect(review.context.contains("→ Blue"))
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

    @Test func claudeTrustFolder() throws {
        let trust = try #require(ScreenPrompt.parse(try screen("claude-trust-folder")))
        #expect(trust.style == .choice)
        #expect(trust.title == "Trust this folder?")
        #expect(trust.subject == "/home/alex/src/new-app")
        #expect(trust.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(trust.cursor == 0)
        // A path too long for the pane wraps; the grant is for all of it. No path, no prompt.
        let wrapped = try screen("claude-trust-folder").replacingOccurrences(of: " /home/alex/src/new-app\n", with: " /home/alex/src/clients/acme/servi\n ces/new-app\n")
        #expect(ScreenPrompt.parse(wrapped)?.subject == "/home/alex/src/clients/acme/services/new-app")
        // Wrapped at a space, the screen reads "MyApp"; the pane's folder says what it is.
        let spaced = try screen("claude-trust-folder").replacingOccurrences(of: " /home/alex/src/new-app\n", with: " /home/alex/src/My\n App\n")
        let parsed = try #require(ScreenPrompt.parse(spaced))
        let resolved = try #require(parsed.trustResolved(cwd: "/home/alex/src/My App"))
        #expect(resolved.folder == "/home/alex/src/My App")
        // Still the screen's own prompt, so the driver recognizes it when answering.
        #expect(resolved.representsSameWait(as: parsed))
        let home = try screen("claude-trust-folder").replacingOccurrences(of: " /home/alex/src/new-app\n", with: " ~/src/new-app\n")
        #expect(ScreenPrompt.parse(home)?.trustResolved(cwd: "/home/alex/src/new-app")?.folder == "/home/alex/src/new-app")
        #expect(ScreenPrompt.parse(home)?.trustResolved(cwd: "/srv/other/src/new-app") == nil)
        #expect(parsed.trustResolved(cwd: "/home/alex/src/Other") == nil)
        // Unwrapped, the screen's spacing is the folder's: "Team A" isn't "TeamA".
        let single = try screen("claude-trust-folder").replacingOccurrences(of: " /home/alex/src/new-app\n", with: " /home/alex/TeamA\n")
        #expect(ScreenPrompt.parse(single)?.trustResolved(cwd: "/home/alex/Team A") == nil)
        #expect(ScreenPrompt.parse(single)?.trustResolved(cwd: "/home/alex/TeamA")?.folder == "/home/alex/TeamA")
        #expect(parsed.trustResolved(cwd: nil) == nil)
        // An old check scrolled above a newer prompt is not the live question.
        let stale = try screen("claude-trust-folder") + "\nalex@studio:~/src/new-app$ make\n Continue?\n ❯ 1. Yes\n   2. No\n"
        #expect(ScreenPrompt.parse(stale)?.title != "Trust this folder?")
        let unnamed = try screen("claude-trust-folder").replacingOccurrences(of: " /home/alex/src/new-app\n", with: "")
        #expect(ScreenPrompt.parse(unnamed)?.title != "Trust this folder?")
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
/// Enter on "Other" opens the custom-answer box, whose Enter closes it. With `lag`, each key
/// shows up only after that many more reads, as the real screen trails the keys.
private final class FakeOmp: PromptIO, @unchecked Sendable {
    var cursor = 1; var question: String; var keys: [String] = []; var typed: [String] = []
    var confirmed = true; var stuck = false; var closed = false; var customBox = false
    var window: Int?; var top = 0; var lag = 0
    private var stale: [String] = []
    init(question: String = "Which colour should the sheep be?", window: Int? = nil) {
        self.question = question; self.window = window
    }
    func readVisible() async throws -> String {
        stale.isEmpty ? render() : stale.removeFirst()
    }
    private func render() -> String {
        if closed { return "❯ \n" }
        if customBox { return "╭─ Custom answer: \(question) ─╮\n│ > │\n╰──╯" }
        return askBox(cursor: cursor, question: question, top: top, window: window)
    }
    func send(keys: [String]) async throws {
        self.keys += keys
        guard !stuck else { return }
        for key in keys {
            stale += Array(repeating: render(), count: lag)
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
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool {
        if !confirmed { try await Task.sleep(for: timeout) }
        return confirmed
    }
}

private let sheep = AskActivity(toolCallId: "x", questions: [
    AskQuestion(id: "q", question: "Which colour should the sheep be?",
                options: [AskOption(label: "Red"), AskOption(label: "Green"), AskOption(label: "Blue")]),
])

/// A real omp ask (18.4.4): markdown in questions, a label longer than a phone-width row.
private let sixQuestions = AskActivity(toolCallId: "six", questions: [
    AskQuestion(id: "deploy-target", question: "Where should the `api` service deploy first?", options: [
        AskOption(label: "Staging cluster in us-east-1 behind the existing load balancer, with traffic mirrored from production for an hour"),
        AskOption(label: "Production canary at 5%"), AskOption(label: "Local only")]),
    AskQuestion(id: "database-engine", question: "Which database should the **ledger** use?",
                options: [AskOption(label: "Postgres 18"), AskOption(label: "SQLite with WAL"), AskOption(label: "FoundationDB")]),
    AskQuestion(id: "migration-window", question: "When should the migration run?",
                options: [AskOption(label: "Tonight"), AskOption(label: "Saturday morning"), AskOption(label: "Next sprint")]),
    AskQuestion(id: "retry-policy", question: "How should `RetryPolicy` back off?",
                options: [AskOption(label: "Exponential with jitter"), AskOption(label: "Fixed 2 s"), AskOption(label: "No retries")]),
    AskQuestion(id: "test-coverage", question: "Which test suites must pass before merge?",
                options: [AskOption(label: "Unit"), AskOption(label: "Integration"), AskOption(label: "Snapshot")], multi: true),
    AskQuestion(id: "release-notes", question: "Who writes the release notes?",
                options: [AskOption(label: "Me"), AskOption(label: "The agent"), AskOption(label: "Skip them")]),
])
private let deployTarget = sixQuestions.questions[0]

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

    /// The screen trails the keys, so reads right after Enter can still show the text box.
    @Test(arguments: [0, 2])
    func otherOpensTheBoxTypesAndSubmits(lag: Int) async throws {
        let io = FakeOmp(); io.lag = lag
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
            try await PromptDriver.answer(sheep, replies: [QuestionReply(selected: ["Green"])], io: io, settle: fast,
                                          confirmTimeout: .milliseconds(600))
        }
        #expect(io.keys == ["enter"])
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

/// Replays real screens, advancing only when the expected input is sent. `blanks[input]` reads
/// after that input show no prompt, as a frame caught mid-redraw does. With `resultWhenDone`,
/// the agent logs its result only once every step has been sent.
private final class PromptReplay: PromptIO, @unchecked Sendable {
    var visible: String
    var steps: [(String, String)]
    var confirmed: Bool
    var confirmations = 0
    var blanks: [String: Int] = [:]
    var resultWhenDone = false
    private var pendingBlanks = 0
    init(_ visible: String, steps: [(String, String)], confirmed: Bool = true) {
        self.visible = visible; self.steps = steps; self.confirmed = confirmed
    }
    func readVisible() async throws -> String {
        guard pendingBlanks == 0 else { pendingBlanks -= 1; return "Working…" }
        return visible
    }
    func send(keys: [String]) async throws {
        for key in keys { try advance(key) }
    }
    func type(_ text: String) async throws { try advance("type:" + text) }
    private func advance(_ input: String) throws {
        guard let step = steps.first, step.0 == input else { throw PromptDriverError.unexpectedScreen }
        steps.removeFirst()
        visible = step.1
        pendingBlanks = blanks[input] ?? 0
    }
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool {
        confirmations += 1
        let logged = confirmed && (!resultWhenDone || steps.isEmpty)
        if !logged { try await Task.sleep(for: timeout) }
        return logged
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
                                                  io: io, settle: .zero, confirmTimeout: .milliseconds(300))
                }
            }
            #expect(io.steps.isEmpty)
            #expect(io.confirmations == 1)
        }
        // A review page recording anything else is never submitted: another note, a note the
        // replies don't carry, more or less of a note than they do (shown whole), or Other
        // text they didn't send.
        for reply in [QuestionReply(selected: ["Apple"], custom: "Banana", note: "Eat the peel"),
                      QuestionReply(selected: ["Apple"], custom: "Banana", note: nil),
                      QuestionReply(selected: ["Apple"], custom: "Banana", note: "Keep"),
                      QuestionReply(selected: ["Apple"], custom: "Banana", note: "Keep the peel; do not deploy"),
                      QuestionReply(selected: ["Apple"], custom: nil, note: "Keep the peel")] {
            let io = PromptReplay(try screen("omp-rich-review"), steps: [])
            await #expect(throws: PromptDriverError.unexpectedScreen) {
                try await PromptDriver.answer(ask, replies: [reply], io: io, settle: .zero)
            }
            #expect(io.confirmations == 0)
        }
        // Another ask whose id ends the same (`pings` in `toppings`) doesn't own this review.
        let suffix = AskActivity(toolCallId: "suffix", questions: [
            AskQuestion(id: "pings", question: "Choose toppings", options: ask.questions[0].options, multi: true)
        ])
        let io = PromptReplay(try screen("omp-rich-review"), steps: [])
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.answer(suffix, replies: [.init(selected: ["Apple"], custom: "Banana", note: "Keep the peel")],
                                          io: io, settle: .zero)
        }
        #expect(io.confirmations == 0)
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
@Suite struct AskResumeTests {
    @Test(arguments: ["omp-review", "claude-ask-review"])
    func resumesFromReviewAndChecksRecordedAnswers(name: String) async throws {
        let ask: AskActivity
        let replies: [QuestionReply]
        if name == "omp-review" {
            ask = AskActivity(toolCallId: "review", questions: [
                .init(id: "size", question: "Which size?", options: [.init(label: "Small"), .init(label: "Medium"), .init(label: "Large")]),
                .init(id: "drink", question: "Which drink?", options: [.init(label: "Tea"), .init(label: "Coffee")]),
            ])
            replies = [.init(selected: ["Large"]), .init(custom: "Sparkling water")]
        } else {
            ask = AskActivity(toolCallId: "review", questions: [
                .init(id: "color", header: "Color", question: "Which color?", options: [.init(label: "Red"), .init(label: "Green"), .init(label: "Blue")]),
                .init(id: "toppings", header: "Toppings", question: "Which toppings?", options: [.init(label: "Cheese"), .init(label: "Olives"), .init(label: "Basil")], multi: true),
            ])
            replies = [.init(selected: ["Blue"]), .init(selected: ["Cheese", "Basil"])]
        }
        let io = PromptReplay(try screen(name), steps: [("enter", "Working…")])
        try await PromptDriver.answer(ask, replies: replies, io: io, settle: .zero)
        #expect(io.steps.isEmpty)
        #expect(io.confirmations == 1)

        let wrong = PromptReplay(try screen(name), steps: [])
        var wrongReplies = replies
        wrongReplies[wrongReplies.count - 1] = .init(selected: name == "omp-review" ? ["Tea"] : ["Olives"])
        await #expect(throws: PromptDriverError.unexpectedScreen) {
            try await PromptDriver.answer(ask, replies: wrongReplies, io: wrong, settle: .zero)
        }
        #expect(wrong.steps.isEmpty)
        let mismatched = name == "omp-review"
            ? try screen(name).replacingOccurrences(of: "size    drink", with: "wrong    drink")
            : try screen(name).replacingOccurrences(of: "☒ Color", with: "☒ Wrong")
        let wrongAsk = PromptReplay(mismatched, steps: [])
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.answer(ask, replies: replies, io: wrongAsk, settle: .zero)
        }
        #expect(wrongAsk.steps.isEmpty)
    }

    @Test func resumesFromOmpReviewWithHeaderLabels() async throws {
        let ask = AskActivity(toolCallId: "headers", questions: [
            .init(id: "color", header: "Color", question: "Which color?",
                  options: [.init(label: "Red"), .init(label: "Green"), .init(label: "Blue")]),
            .init(id: "toppings", header: "Toppings", question: "Which toppings?",
                  options: [.init(label: "Cheese"), .init(label: "Olives"), .init(label: "Basil")], multi: true),
        ])
        let io = PromptReplay(try screen("omp-live-mixed-review"), steps: [("enter", "Working…")])
        try await PromptDriver.answer(ask, replies: [.init(selected: ["Red"]), .init(selected: ["Cheese", "Olives"])],
                                      io: io, settle: .zero)
        #expect(io.steps.isEmpty)
        #expect(io.confirmations == 1)
        // An earlier single-question ask doesn't own another ask's review, though its one
        // answer agrees: Submit would send the other question's answer too.
        let single = AskActivity(toolCallId: "single", questions: [ask.questions[0]])
        let other = PromptReplay(try screen("omp-live-mixed-review"), steps: [])
        await #expect(throws: PromptDriverError.questionMismatch) {
            try await PromptDriver.answer(single, replies: [.init(selected: ["Red"])], io: other, settle: .zero)
        }
        #expect(other.confirmations == 0)
    }

    @Test func resumesFromSecondQuestion() async throws {
        let ask = AskActivity(toolCallId: "later", questions: [
            .init(id: "size", question: "Which size?", options: [.init(label: "Small"), .init(label: "Medium"), .init(label: "Large")]),
            .init(id: "drink", question: "Which drink?", options: [.init(label: "Tea"), .init(label: "Coffee")]),
        ])
        let io = PromptReplay(try screen("omp-q2"), steps: [("enter", "Working…")])
        try await PromptDriver.answer(ask, replies: [.init(selected: ["Large"]), .init(selected: ["Coffee"])],
                                      io: io, settle: .zero)
        #expect(io.steps.isEmpty)
        #expect(io.confirmations == 1)
    }

    /// Enter on the last question, then frames with no prompt while omp draws the review page:
    /// the blank frames are not the end, and the review is still submitted.
    @Test func blankFramesBeforeTheReviewStillSubmit() async throws {
        let ask = AskActivity(toolCallId: "blank", questions: [
            .init(id: "size", question: "Which size?", options: [.init(label: "Small"), .init(label: "Medium"), .init(label: "Large")]),
            .init(id: "drink", question: "Which drink?", options: [.init(label: "Tea"), .init(label: "Coffee")]),
        ])
        let review = try screen("omp-review").replacingOccurrences(of: "“Sparkling water”", with: "Coffee")
        let io = PromptReplay(try screen("omp-q2"), steps: [("enter", review), ("enter", "Working…")])
        io.blanks = ["enter": 3]; io.resultWhenDone = true
        try await PromptDriver.answer(ask, replies: [.init(selected: ["Large"]), .init(selected: ["Coffee"])],
                                      io: io, settle: .zero)
        #expect(io.steps.isEmpty)
    }
}

extension ScreenPromptTests {
    @Test func currentOmpApprovalActionsAreAllSelectableRows() async throws {
        for (name, labels, initial) in [
            ("omp-approval-session", ["Approve", "Approve bash for this session", "Deny"], 0),
            ("omp-approval-cached-write", ["Approve Directory: /tmp", "Approve File", "Approve Once", "Deny"], 2),
        ] {
            let visible = try screen(name)
            let prompt = try #require(ScreenPrompt.parse(visible))
            #expect(prompt.options.map(\.label) == labels)
            #expect(prompt.cursor == initial)
            #expect(prompt.contextMayBeTruncated)
            #expect(!prompt.context.contains { $0.contains("Ctrl+") })
            // Replay every real action, including Deny after the newly added approval rows.
            for target in labels.indices {
                var cursor = initial
                var steps: [(String, String)] = []
                while cursor != target {
                    let next = cursor + (target > cursor ? 1 : -1)
                    let moved = visible.replacingOccurrences(of: " " + labels[initial], with: "  " + labels[initial])
                        .replacingOccurrences(of: "  " + labels[next], with: " " + labels[next])
                    steps.append((target > cursor ? "down" : "up", moved))
                    cursor = next
                }
                steps.append(("enter", "Working…"))
                let io = PromptReplay(visible, steps: steps)
                try await PromptDriver.choose(labels[target], on: prompt, io: io, settle: .zero)
                #expect(io.steps.isEmpty)
            }
        }
    }

    @Test func liveMarkdownHeadingPreviewAndEmojiMatchTranscript() throws {
        let url = try #require(Bundle.module.url(forResource: "omp-matrix-transcript", withExtension: "jsonl", subdirectory: "Screens"))
        var reader = TranscriptReader(format: .omp)
        var conversation = Conversation()
        conversation.apply(reader.append(Array(try Data(contentsOf: url))))
        let ask = try #require(conversation.pendingAsk)
        let prompt = try #require(ScreenPrompt.parse(screen("omp-matrix-wide")))
        #expect(PromptDriver.belongs(prompt, to: ask))
        #expect(PromptDriver.matches(prompt, ask.questions[0]))
        #expect(PromptDriver.rows(prompt, ask.questions[0]) == [0, 1, 2, 3])
        #expect(ask.questions[0].options[0].preview == "deploy --safe\ncheck status")
        #expect(prompt.options[0].detail?.contains("check status") == true)
        var changed = prompt
        changed.title += " Run immediately."
        #expect(!PromptDriver.matches(changed, ask.questions[0]))
    }

    @Test func approvalDetailChangesAreNotTheSameWait() throws {
        let visible = try screen("claude-perm-bash")
        let prompt = try #require(ScreenPrompt.parse(visible))
        var changed = prompt
        changed.options[0].detail = "An additional dangerous action"
        #expect(!prompt.representsSameWait(as: changed))
        changed = prompt
        changed.cursor = 1
        #expect(prompt.representsSameWait(as: changed))
    }
}

extension ScreenPromptTests {
    @Test func completedApprovalScreenIsNotStillAPrompt() throws {
        #expect(ScreenPrompt.parse(try screen("omp-approval-after")) == nil)
    }
}
