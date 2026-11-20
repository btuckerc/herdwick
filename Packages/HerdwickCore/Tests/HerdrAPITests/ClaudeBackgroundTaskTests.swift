import Foundation
import HerdrAPI
import Testing

/// Claude Code 2.1's background tasks: a `run_in_background` Bash call answers with
/// `toolUseResult.backgroundTaskId`, and a `<task-notification>` (a user record when it wakes
/// the agent, a `queued_command` attachment when it lands mid-turn) says it ended.
@Suite struct ClaudeBackgroundTaskTests {
    private func call(_ id: String, _ command: String) -> String {
        #"{"type":"assistant","uuid":"a-\#(id)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)","run_in_background":true}}],"stop_reason":"tool_use"}}"#
    }
    private func launched(_ id: String, task: String) -> String {
        #"{"type":"user","uuid":"r-\#(id)","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"\#(task)"},"message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"Command running in background with ID: \#(task). Output is being written to: /tmp/t/\#(task).output.","is_error":false}]}}"#
    }
    private func notified(_ task: String, call: String, status: String, summary: String, attachment: Bool = false) -> String {
        let body = "<task-notification>\n<task-id>\(task)</task-id>\n<tool-use-id>\(call)</tool-use-id>\n<output-file>/tmp/t/\(task).output</output-file>\n<status>\(status)</status>\n<summary>\(summary)</summary>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed), as: UTF8.self)
        if attachment {
            return #"{"type":"attachment","uuid":"n-\#(task)","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":\#(text)}}"#
        }
        return #"{"type":"user","uuid":"n-\#(task)","turnOrigin":"task_notification","promptSource":"system","message":{"role":"user","content":\#(text)}}"#
    }
    private func parse(_ lines: [String]) -> Conversation {
        var reader = TranscriptReader(format: .claude)
        var conversation = Conversation()
        conversation.apply(reader.append(Array((lines.joined(separator: "\n") + "\n").utf8)))
        return conversation
    }
    private func tools(_ c: Conversation) -> [ToolActivity] {
        c.items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }
    }
    private func users(_ c: Conversation) -> [String] {
        c.items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } }
    }

    @Test func aWakeNotificationSettlesItsStepAndAddsARowNotAMessage() {
        let c = parse([call("toolu_1", "swift test"), launched("toolu_1", task: "b7hvp3pus"),
                       notified("b7hvp3pus", call: "toolu_1", status: "completed",
                                summary: #"Background command "mise exec -- swift test 2&gt;&amp;1 | tail" completed (exit code 0)"#)])
        #expect(users(c).isEmpty)
        #expect(c.backgroundCommands.isEmpty)
        #expect(tools(c).first?.background == .finished)
        // Named as its launch was: the command (no description given).
        #expect(tools(c).last?.summary == "Finished swift test")
        #expect(tools(c).last?.state == .succeeded)
    }

    @Test func runningUntilNotified() {
        let c = parse([call("toolu_1", "make"), launched("toolu_1", task: "bx")])
        #expect(c.backgroundCommands == ["make"])
        #expect(tools(c).first?.background == .running("bx"))
    }

    @Test func aMidTurnAttachmentAndAFailureCount() {
        let c = parse([call("toolu_1", "make"), launched("toolu_1", task: "bx"),
                       notified("bx", call: "toolu_1", status: "failed", summary: #"Background command "make" failed with exit code 2"#, attachment: true)])
        #expect(c.backgroundCommands.isEmpty)
        #expect(tools(c).first?.background == .failed)
        #expect(tools(c).last?.summary == "Failed make")
        #expect(tools(c).last?.state == .failed)
    }

    @Test func aMonitorEventIsANoticeAndEndsNothing() {
        let body = "<task-notification>\n<task-id>bm</task-id>\n<summary>Monitor event: \"wan\"</summary>\n<event>internet-up</event>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed), as: UTF8.self)
        let c = parse([call("toolu_1", "make"), launched("toolu_1", task: "bx"),
                       #"{"type":"user","uuid":"m","turnOrigin":"task_notification","message":{"role":"user","content":\#(text)}}"#])
        #expect(c.backgroundCommands == ["make"])
        #expect(users(c).isEmpty)
        let notices = c.items.compactMap { if case .notice(_, let text, _) = $0 { text } else { nil } }
        #expect(notices == ["Monitor event: \"wan\"\ninternet-up"])
    }

    @Test func councilSeatsReadAsModelAndRun() {
        let launch = #"{"type":"assistant","uuid":"a","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_s","name":"Bash","input":{"command":"R=~/x; agent-run ask --model fable --name 2026-11-20-app-fable-r1 --repo $R/tree --brief $R/b.md --timeout 1800","description":"Run Fable seat","run_in_background":true}}],"stop_reason":"tool_use"}}"#
        let described = #"{"type":"assistant","uuid":"b","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_d","name":"Bash","input":{"command":"make all","description":"Build everything","run_in_background":true}}],"stop_reason":"tool_use"}}"#
        let c = parse([launch, launched("toolu_s", task: "bs"), described, launched("toolu_d", task: "bd"),
                       notified("bs", call: "toolu_s", status: "completed", summary: #"Background command "Run Fable seat" completed (exit code 0)"#)])
        #expect(c.backgroundCommands == ["Build everything"])
        #expect(tools(c).last?.summary == "Finished fable · 2026-11-20-app-fable-r1")
    }

    @Test func aResultWhoseCallIsInEarlierHistoryStillOpens() {
        let c = parse([#"{"type":"user","uuid":"r","message":{"role":"user","content":[{"tool_use_id":"toolu_gone","type":"tool_result","content":"line 1\nline 2","is_error":false}]}}"#])
        #expect(tools(c).map(\.summary) == ["Result of an earlier step"])
        #expect(tools(c).first?.output == "line 1\nline 2")
    }

    @Test func aPersonQuotingANotificationKeepsTheirMessage() {
        let body = "<task-notification>\n<task-id>bx</task-id>\n<status>completed</status>\n<summary>x</summary>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed), as: UTF8.self)
        let c = parse([#"{"type":"user","uuid":"h","turnOrigin":"human","message":{"role":"user","content":\#(text)}}"#])
        #expect(users(c) == [body])
        #expect(tools(c).isEmpty)
    }

    @Test func aDeliveryWithoutItsCallIdStillSettlesTheStep() {
        let body = "<task-notification>\n<task-id>bx</task-id>\n<status>completed</status>\n<summary>Background command \"make\" completed (exit code 0)</summary>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed), as: UTF8.self)
        let c = parse([call("toolu_1", "make"), launched("toolu_1", task: "bx"),
                       #"{"type":"attachment","uuid":"q","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":\#(text)}}"#])
        #expect(tools(c).first?.background == .finished)
        #expect(c.backgroundCommands.isEmpty)
    }

    @Test func apiRequestCopiesAreNotRows() {
        let blob = #"{"type":"api-request-blob","sessionId":"s","timestamp":"2026-11-20T07:45:14.681Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        let c = parse([call("toolu_1", "make"), blob, launched("toolu_1", task: "bx")])
        #expect(c.items.count == 1)
        #expect(!c.items.contains { if case .raw = $0 { true } else { false } })
    }

    @Test func compactionSaysWhatWasKept() {
        let c = parse([#"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto","preTokens":301376,"postTokens":20092},"uuid":"c"}"#])
        let notices = c.items.compactMap { if case .notice(_, let text, .compaction) = $0 { text } else { nil } }
        #expect(notices == ["Context compacted · 301k → 20k tokens"])
    }

    @Test func effortIsTheReplysOwn() {
        var reader = TranscriptReader(format: .claude)
        var c = Conversation()
        let line = #"{"type":"assistant","uuid":"a","effort":"high","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}"#
        c.apply(records: reader.appendRecords(Array((line + "\n").utf8)))
        #expect(c.thinkingLevel == "high")
        #expect(c.modelID == "claude-opus-5-5")
    }

    @Test func aMessageTypedMidTurnShowsAndSeveralEndsSettleTogether() {
        let typed = #"{"type":"attachment","uuid":"qp","attachment":{"type":"queued_command","prompt":"also check X","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true}}"#
        let both = "<task-notification>\n<task-id>ba</task-id>\n<status>completed</status>\n<summary>Background command \"a\" completed (exit code 0)</summary>\n</task-notification>\n<task-notification>\n<task-id>bb</task-id>\n<status>failed</status>\n<summary>Background command \"b\" failed with exit code 1</summary>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: both, options: .fragmentsAllowed), as: UTF8.self)
        let c = parse([call("toolu_a", "a"), launched("toolu_a", task: "ba"), call("toolu_b", "b"), launched("toolu_b", task: "bb"), typed,
                       #"{"type":"user","uuid":"w","turnOrigin":"task_notification","message":{"role":"user","content":\#(text)}}"#])
        #expect(users(c) == ["also check X"])
        #expect(c.backgroundCommands.isEmpty)
        #expect(tools(c).suffix(2).map(\.summary) == ["Finished a", "Failed b"])
    }

    @Test func aMessageTypedMidTurnKeepsTheRunningStep() {
        let running = #"{"type":"assistant","uuid":"a","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_r","name":"Bash","input":{"command":"swift test"}}],"stop_reason":"tool_use"}}"#
        let typed = #"{"type":"attachment","uuid":"qp","attachment":{"type":"queued_command","prompt":"also X","commandMode":"prompt","origin":{"kind":"human"}}}"#
        let c = parse([running, typed])
        #expect(c.runningTools.map(\.id) == ["toolu_r"])
        #expect(users(c) == ["also X"])
    }

    @Test func aMixedBatchKeepsItsNotice() {
        let both = "<task-notification>\n<task-id>bm</task-id>\n<summary>Monitor event: \"wan\"</summary>\n<event>up</event>\n</task-notification>\n<task-notification>\n<task-id>bx</task-id>\n<status>completed</status>\n<summary>Background command \"make\" completed (exit code 0)</summary>\n</task-notification>"
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: both, options: .fragmentsAllowed), as: UTF8.self)
        let c = parse([call("toolu_1", "make"), launched("toolu_1", task: "bx"),
                       #"{"type":"user","uuid":"w","turnOrigin":"task_notification","message":{"role":"user","content":\#(text)}}"#])
        #expect(c.backgroundCommands.isEmpty)
        let notices = c.items.compactMap { if case .notice(_, let t, _) = $0 { t } else { nil } }
        #expect(notices == ["Monitor event: \"wan\"\nup"])
    }
}
