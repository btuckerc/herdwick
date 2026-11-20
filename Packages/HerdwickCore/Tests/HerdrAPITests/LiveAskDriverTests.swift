import Foundation
import Testing
import HerdrTestSupport
@testable import HerdrAPI

/// Drives real omp asks (single, multi, mixed; default and 48-column panes) and checks the
/// transcript logged each result. Opt-in with `HERDWICK_LIVE=1`; needs omp logged in for
/// `claude-haiku` and spends a few model calls. Runs only in a throwaway `herdwick-test-ask-*` session.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDWICK_LIVE"] == "1"), .serialized, .timeLimit(.minutes(12)))
struct LiveAskDriverTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    @Test func ompQuestionShapesAtDefaultAndNarrowSizes() async throws {
        let session = "herdwick-test-ask-\(UInt32.random(in: 0...UInt32.max))"
        try await client.startServer(session: session)
        let herdr = try await client.resolveHerdrPath()
        var failure: (any Error)?
        do {
            let root = try await client.createWorkspace(label: "ask-driver", cwd: "/tmp", session: session).rootPane.id
            _ = try await HerdrClient.collect(try await LocalProcessRunner().exec("\(herdr) --session \(session) agent start ask-test --kind omp --pane \(root) --timeout 60000 -- --model claude-haiku"))
            let cases: [(String, String)] = [
                ("default single", "Use the ask tool exactly once. Ask one single-select question: id 'color', header 'Color', question 'Which color?', options Red, Green, Blue, recommended index 1. Stop and wait for my answer."),
                ("default multi", "Use the ask tool exactly once. Ask one question: id 'fruit', header 'Fruit', question 'Which fruit?', options Apple, Banana, Cherry, multi true. Stop and wait for my answer."),
                ("default mixed", "Use the ask tool exactly once. Ask 2 questions: id 'color', header 'Color', question 'Which color?', single-select options Red, Green, Blue, recommended index 1; id 'toppings', header 'Toppings', question 'Which toppings?', options Cheese, Olives, Basil, multi true. Stop and wait for my answer."),
                ("narrow single", "Use the ask tool exactly once. Ask one single-select question: id 'color', header 'Color', question 'Which color?', options Red, Green, Blue, recommended index 1. Stop and wait for my answer."),
                ("narrow multi", "Use the ask tool exactly once. Ask one question: id 'fruit', header 'Fruit', question 'Which fruit?', options Apple, Banana, Cherry, multi true. Stop and wait for my answer."),
                ("narrow mixed", "Use the ask tool exactly once. Ask 2 questions: id 'color', header 'Color', question 'Which color?', single-select options Red, Green, Blue, recommended index 1; id 'toppings', header 'Toppings', question 'Which toppings?', options Cheese, Olives, Basil, multi true. Stop and wait for my answer."),
                ("narrow rich Other", "Use ask exactly once. Ask one single-select question, id target, header Deploy, question '## Deployment 🐑\\n\\nWhere should the **api** service run with `--safe` enabled? Choose a target after reviewing the migration.', options: 'Staging cluster in us-east-1 behind the existing load balancer with mirrored traffic for an hour' (description 'No production writes.', preview 'deploy --safe\\ncheck status'), 'Production canary 🚀', 'Local only'. Recommended index 0. Wait for my answer."),
                ("wide rich Other", "Use ask exactly once. Ask one single-select question, id target, header Deploy, question '## Deployment 🐑\\n\\nWhere should the **api** service run with `--safe` enabled? Choose a target after reviewing the migration.', options: 'Staging cluster in us-east-1 behind the existing load balancer with mirrored traffic for an hour' (description 'No production writes.', preview 'deploy --safe\\ncheck status'), 'Production canary 🚀', 'Local only'. Recommended index 0. Wait for my answer."),
            ]
            for (offset, item) in cases.enumerated() {
                if offset == 3 {
                    let terminal = try await client.terminal(pane: root, session: session, cols: 48, rows: 40, control: true)
                    try await terminal.send(.resize(cols: 48, rows: 40))
                    await terminal.close()
                }
                if item.0 == "wide rich Other" {
                    let terminal = try await client.terminal(pane: root, session: session, cols: 120, rows: 40, control: true)
                    try await terminal.send(.resize(cols: 120, rows: 40))
                    await terminal.close()
                }
                if offset > 0 { try await waitForIdle(pane: root, session: session) }
                try await client.sendText(item.1, pane: root, submit: true, session: session)
                let (ask, path) = try await pendingAsk(pane: root, session: session)
                // The transcript logs the ask before omp draws it.
                var visible = ""
                var shown: ScreenPrompt?
                for _ in 0..<20 {
                    visible = try await client.readPane(root, session: session).text
                    if let prompt = ScreenPrompt.parse(visible), prompt.phase == .question { shown = prompt; break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard shown != nil else {
                    let url = URL(fileURLWithPath: "/tmp/\(session)-unparsed-\(offset).txt")
                    try Data(visible.utf8).write(to: url)
                    print("LIVE_UNPARSED \(item.0) saved=\(url.path)\n\(visible)")
                    throw PromptDriverError.noPrompt
                }
                let replies = ask.questions.map { question -> QuestionReply in
                    if item.0.contains("Other") { return QuestionReply(custom: "Use \"blue\" 🐑\nthen verify --safe") }
                    return QuestionReply(selected: question.multi ? Array(question.options.prefix(2).map { $0.label }) : [question.options[0].label])
                }
                let io = HerdrPromptIO(client: client, pane: root, session: session) { callID, timeout in
                    let deadline = ContinuousClock.now + timeout
                    while ContinuousClock.now < deadline {
                        if Self.hasResult(path: path, toolCallID: callID) { return true }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return false
                }
                do {
                    try await PromptDriver.answer(ask, replies: replies, io: io, settle: .seconds(5), confirmTimeout: .seconds(20))
                } catch {
                    let failed = try await client.readPane(root, session: session).text
                    let url = URL(fileURLWithPath: "/tmp/\(session)-\(offset).txt")
                    try Data(failed.utf8).write(to: url)
                    print("LIVE_FAIL \(item.0): \(error); screen saved at \(url.path)\n\(failed)")
                    throw error
                }
                let after = try await client.readPane(root, session: session).text
                #expect(ScreenPrompt.parse(after) == nil)
                #expect(Self.hasResult(path: path, toolCallID: ask.toolCallId))
                print("LIVE_PASS \(item.0): transcript toolResult and no prompt")
            }
        } catch { failure = error }
        _ = try? await HerdrClient.collect(try await LocalProcessRunner().exec("\(herdr) --session \(session) server stop >/dev/null 2>&1; \(herdr) session delete \(session) >/dev/null 2>&1"))
        if let failure { throw failure }
    }

    @Test func ompToolApprovalIsAnswerableAndReportsBlocked() async throws {
        let session = "herdwick-test-approval-\(UInt32.random(in: 0...UInt32.max))"
        try await client.startServer(session: session)
        let herdr = try await client.resolveHerdrPath()
        var failure: (any Error)?
        do {
            let pane = try await client.createWorkspace(label: "approval-driver", cwd: "/tmp", session: session).rootPane.id
            _ = try await HerdrClient.collect(try await LocalProcessRunner().exec("\(herdr) --session \(session) agent start approval-test --kind omp --pane \(pane) --timeout 60000 -- --model claude-haiku --approval-mode always-ask"))
            try await client.sendText("Use bash exactly once to run printf herdwick-approval-test. Do nothing else.", pane: pane, submit: true, session: session)
            let deadline = ContinuousClock.now + .seconds(60)
            var shown: ScreenPrompt?
            while ContinuousClock.now < deadline {
                if let prompt = ScreenPrompt.parse(try await client.readPane(pane, session: session).text), prompt.style == .choice {
                    shown = prompt; break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            let prompt = try #require(shown)
            #expect(prompt.options.map(\.label) == ["Approve", "Approve bash for this session", "Deny"])
            let before = try await client.snapshot(session: session)
            let agent = try #require(before.agents.first { $0.paneID == pane })
            #expect(agent.agentStatus == .blocked)
            let path = try #require(agent.agentSession?.transcriptPath)
            let io = HerdrPromptIO(client: client, pane: pane, session: session) { _, _ in false }
            do {
                try await PromptDriver.choose("Approve", on: prompt, io: io, settle: .seconds(5))
            } catch {
                let failed = try await client.readPane(pane, session: session).text
                let url = URL(fileURLWithPath: "/tmp/\(session)-approval.txt")
                try Data(failed.utf8).write(to: url)
                print("LIVE_APPROVAL_FAILURE \(error) saved=\(url.path)\n\(failed)")
                throw error
            }
            try await waitForIdle(pane: pane, session: session)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var reader = TranscriptReader(format: .omp)
            var conversation = Conversation()
            conversation.apply(reader.append(Array(data)))
            #expect(conversation.items.contains {
                if case .tool(let tool) = $0 { return tool.state == .succeeded }
                return false
            })
        } catch { failure = error }
        _ = try? await HerdrClient.collect(try await LocalProcessRunner().exec("\(herdr) --session \(session) server stop >/dev/null 2>&1; \(herdr) session delete \(session) >/dev/null 2>&1"))
        if let failure { throw failure }
    }

    private func pendingAsk(pane: String, session: String) async throws -> (AskActivity, String) {
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            let snapshot = try await client.snapshot(session: session)
            guard let agent = snapshot.agents.first(where: { $0.paneID == pane }),
                  let path = agent.agentSession?.transcriptPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                try await Task.sleep(for: .milliseconds(200)); continue
            }
            var reader = TranscriptReader(format: .omp)
            var conversation = Conversation()
            conversation.apply(reader.append(Array(data)))
            if let ask = conversation.pendingAsk { return (ask, path) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let visible = try? await client.readPane(pane, session: session).text
        if let visible {
            let url = URL(fileURLWithPath: "/tmp/\(session)-no-prompt.txt")
            try? Data(visible.utf8).write(to: url)
            print("LIVE_NO_PROMPT session=\(session) pane=\(pane) screen saved=\(url.path)\n\(visible)")
        }
        throw PromptDriverError.noPrompt
    }

    private func waitForIdle(pane: String, session: String) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            let snapshot = try await client.snapshot(session: session)
            if snapshot.agents.first(where: { $0.paneID == pane })?.agentStatus == .idle { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw PromptDriverError.noPrompt
    }

    private static func hasResult(path: String, toolCallID: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "toolResult",
                  message["toolCallId"] as? String == toolCallID else { continue }
            return true
        }
        return false
    }
}
