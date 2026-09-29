import Foundation
import HerdrAPI
import Testing

/// omp's `<system-notice>` deliveries: background command output and subagent results.
@Suite struct BackgroundJobTests {
    private func call(_ id: String, _ command: String) -> String {
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"\#(id)","name":"bash","arguments":{"command":"\#(command)"}}]}}"#
    }
    private func started(_ id: String, job: String) -> String {
        #"{"type":"message","message":{"role":"toolResult","toolCallId":"\#(id)","toolName":"bash","details":{"async":{"state":"running","jobId":"\#(job)","type":"bash"}},"content":[{"type":"text","text":"Backgrounded as job \#(job); its output is injected later."}]}}"#
    }
    private func delivered(_ content: String, jobs: [(String, String)]) -> String {
        let list = jobs.map { #"{"jobId":"\#($0.0)","type":"bash","label":"\#($0.1)"}"# }.joined(separator: ",")
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: content, options: .fragmentsAllowed), as: UTF8.self)
        return #"{"type":"custom_message","customType":"async-result","display":true,"content":\#(text),"details":{"jobs":[\#(list)]}}"#
    }
    private func parse(_ lines: [String]) -> Conversation {
        var reader = TranscriptReader(format: .omp)
        var conversation = Conversation()
        conversation.apply(reader.append(Array((lines.joined(separator: "\n") + "\n").utf8)))
        return conversation
    }
    private func tools(_ c: Conversation) -> [ToolActivity] {
        c.items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }
    }

    @Test func outputArrivesAsARowWhereItWasDelivered() {
        let c = parse([
            call("a", "make"), started("a", job: "bg_6"),
            delivered("<system-notice>\nBackground job bg_6 has completed. Resume your work using the result below.\nok\nWall time: 2 seconds\n</system-notice>", jobs: [("bg_6", "make")]),
        ])
        #expect(tools(c).map(\.summary) == ["make", "Finished make"])
        #expect(tools(c).map(\.output) == ["Backgrounded as job bg_6; its output is injected later.", "ok\nWall time: 2 seconds"])
    }

    @Test func severalJobsSplitByTheirHeaders() {
        let content = "<system-notice>\n2 background jobs have completed. Resume your work using the results below.\n\n── Job bg_2 (curl a) ──\n(no output)\n\n── Job bg_1 (curl b) ──\nbody b\n</system-notice>"
        let c = parse([delivered(content, jobs: [("bg_2", "curl a"), ("bg_1", "curl b")])])
        #expect(tools(c).map(\.summary) == ["Finished curl a", "Finished curl b"])
        #expect(tools(c).map(\.output) == ["(no output)", "body b"])
    }

    @Test func mixedDeliveriesKeepBothKinds() {
        let spawn = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"s","name":"task","arguments":{"tasks":[{"name":"One"}]}}]}}"#
        let content = "<system-notice>\n2 background jobs have completed.\n\n── Job One (task) ──\n<task-result id=\"One\" status=\"completed\">done</task-result>\n\n── Job bg_1 (ls) ──\na\n</system-notice>"
        let c = parse([spawn, delivered(content, jobs: [("bg_1", "ls")])])
        #expect(c.items.compactMap { if case .subagentResult(_, let a) = $0 { a.summary } else { nil } } == ["done"])
        #expect(tools(c).last?.output == "a")
    }

    @Test func redactedThinkingShowsNothing() {
        let c = parse([#"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"x"},{"type":"thinking","thinking":"","thinkingSignature":"y"},{"type":"text","text":"Done."}]}}"#])
        #expect(c.items.map(\.id).count == 1)
        if case .assistant(_, let text) = c.items.first { #expect(text == "Done.") } else { Issue.record("expected the reply") }
    }

    @Test func structuredResultsShowTheirProse() {
        let spawn = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"s","name":"task","arguments":{"tasks":[{"name":"One"},{"name":"Two"}]}}]}}"#
        let whole = "<task-result id=\"One\" status=\"completed\"><output>\n{\n  \"review\": \"Looks right.\",\n  \"ok\": true\n}\n</output></task-result>"
        let cut = "<task-result id=\"Two\" status=\"completed\"><output>\n{\n  \"status\": \"ok\",\n  \"summary\": \"First \\\"line\\\"\\nsecond, cut sh"
        let c = parse([spawn, delivered("<system-notice>\n" + whole + cut, jobs: [])])
        let summaries = c.items.compactMap { if case .subagentResult(_, let activity) = $0 { activity.summary } else { nil } }
        #expect(summaries == ["Looks right.", "First \"line\"\nsecond, cut sh"])
    }
}
