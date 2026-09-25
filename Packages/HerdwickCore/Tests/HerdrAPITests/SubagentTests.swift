import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

@Suite struct SubagentTests {
    private let spawn = #"{"type":"message","timestamp":"2026-09-25T09:20:08.120Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"spawn","name":"task","arguments":{"tasks":[{"name":"One","agent":"scout"},{"name":"Two","agent":"nous"}]}}]}}"#
    private let waitCall = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"wait","name":"wait","arguments":{}}]}}"#
    private let waitResult = #"{"type":"message","message":{"role":"toolResult","toolCallId":"wait","details":{"jobs":[{"id":"One","status":"failed","errorText":"stopped","durationMs":2000},{"id":"Two","status":"running"}]}}}"#
    private let completed = #"{"type":"custom_message","customType":"async-result","display":true,"content":"<task-result duration=\"1m4s\" status=\"completed\" agent=\"scout\" id=\"One\">first</task-result><task-result id=\"Two\" duration=\"2s\" agent=\"nous\" status=\"completed\">second</task-result>"}"#
    private let cancelled = #"{"type":"custom_message","customType":"async-result","display":true,"content":"<task-result status=\"cancelled\" id=\"One\">stopped</task-result>"}"#

    private func parse(_ lines: [String], format: TranscriptFormat = .omp) -> Conversation {
        var reader = TranscriptReader(format: format)
        var conversation = Conversation()
        conversation.apply(reader.append(Array((lines.joined(separator: "\n") + "\n").utf8)))
        return conversation
    }
    private func results(_ conversation: Conversation) -> [SubagentActivity] {
        conversation.items.compactMap { if case .subagentResult(_, let activity) = $0 { activity } else { nil } }
    }

    @Test func multiSpawnWorking() throws {
        let c = parse([spawn])
        #expect(c.workingSubagents.map(\.id) == ["One", "Two"])
        #expect(c.subagents(spawnedBy: "spawn").map(\.agentType) == ["scout", "nous"])
        #expect(results(c).isEmpty)
        // The tray's elapsed time counts from the spawning record.
        let spawnedAt = try #require(c.workingSubagents.first?.spawnedAt)
        #expect(abs(spawnedAt.timeIntervalSince1970 - 1_790_328_008.12) < 0.001)
    }
    /// Shapes from a live omp `wait`: the job says "failed" but its task-result says cancelled,
    /// and the readable text is the abort reason or the output's JSON summary.
    @Test func waitJobTextsUnwrapTaskResults() {
        let wait = #"{"type":"message","message":{"role":"toolResult","toolCallId":"wait","details":{"jobs":[{"id":"One","status":"failed","durationMs":"3797","errorText":"<task-result id=\"One\" agent=\"scout\" status=\"cancelled\" duration=\"3.8s\">\n<meta lines=\"4\" size=\"197B\" />\n<abort-reason>No bash tool.</abort-reason>\n</task-result>"},{"id":"Two","status":"completed","resultText":"<task-result id=\"Two\" agent=\"nous\" status=\"completed\" duration=\"45.2s\">\n<meta lines=\"5\" size=\"235B\" />\n<output>\n{\n  \"summary\": \"Ran it.\"\n}\n</output>\n</task-result>"}]}}}"#
        let c = parse([spawn, waitCall, wait])
        #expect(results(c).map(\.state) == [.cancelled, .completed])
        #expect(results(c).map(\.summary) == ["No bash tool.", "Ran it."])
        #expect(results(c).map(\.duration) == ["3.8s", "45.2s"])
    }
    @Test func multipleTagsAndDigest() {
        let c = parse([spawn, completed])
        #expect(c.workingSubagents.isEmpty)
        #expect(results(c).map(\.state) == [.completed, .completed])
        #expect(results(c).map(\.duration) == ["1m4s", "2s"])
        #expect(results(c).map(\.summary) == ["first", "second"])
        #expect(c.items(at: .digest).map(\.id) == ["subagent-One", "subagent-Two"])
    }
    @Test func waitAndAsyncDedupe() {
        let waiting = parse([spawn, waitCall, waitResult])
        #expect(waiting.workingSubagents.map(\.id) == ["Two"])
        #expect(results(waiting).first?.state == .failed("stopped"))
        #expect(results(waiting).first?.duration == "2s")
        let c = parse([spawn, waitCall, waitResult, completed, completed])
        #expect(results(c).map(\.id) == ["One", "Two"])
        #expect(results(c).map(\.state) == [.completed, .completed])
    }
    @Test func cancelledWinsInEitherOrder() {
        for lines in [[spawn, cancelled, waitCall, waitResult], [spawn, waitCall, waitResult, cancelled]] {
            let c = parse(lines)
            #expect(results(c).map(\.state) == [.cancelled])
            #expect(c.workingSubagents.map(\.id) == ["Two"])
        }
    }
    @Test func assistantAndOtherNoticesCannotCompleteAgents() {
        let quoted = #"{"type":"message","message":{"role":"assistant","content":"<task-result id=\"One\" status=\"completed\">quoted</task-result>"}}"#
        let c = parse([spawn, quoted, completed.replacingOccurrences(of: "async-result", with: "other")])
        #expect(c.workingSubagents.map(\.id) == ["One", "Two"])
        #expect(results(c).isEmpty)
    }
    @Test func reconcileOnlyWorkingChildren() {
        var c = parse([spawn])
        c.reconcile(childStates: ["One": .active, "Two": .missing])
        #expect(c.workingSubagents.map(\.id) == ["One", "Two"])
        c.reconcile(childStates: ["One": .exited, "Two": .tombstoned])
        c.reconcile(childStates: ["One": .tombstoned, "Two": .exited])
        #expect(results(c).map(\.state) == [.completed, .cancelled])
        #expect(c.workingSubagents.isEmpty)
    }
    @Test func transcriptPaths() {
        #expect(SubagentTranscript.path(parentPath: "/sessions/a.b.jsonl", format: .omp, subagentID: "One") == "/sessions/a.b/One.jsonl")
        #expect(SubagentTranscript.path(parentPath: "/projects/a.b.jsonl", format: .claude, subagentID: "abc") == "/projects/a.b/subagents/agent-abc.jsonl")
        #expect(SubagentTranscript.path(parentPath: "/sessions/a.jsonl", format: .codex, subagentID: "One") == nil)
    }
    @Test func claudeAsyncLaunchThenComplete() {
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"call","name":"Agent","input":{"name":"Research","description":"fallback","subagent_type":"Explore"}}]}}"#
        let launch = #"{"type":"user","toolUseResult":{"status":"async_launched","agentId":"abc"},"message":{"content":[{"type":"tool_result","tool_use_id":"call","content":"launched"}]}}"#
        let finish = #"{"type":"user","toolUseResult":{"status":"completed","agentId":"abc","content":[{"type":"text","text":"answer"}]},"message":{"content":[{"type":"tool_result","tool_use_id":"call","content":"done"}]}}"#
        let working = parse([call, launch], format: .claude)
        #expect(working.workingSubagents.map(\.id) == ["abc"])
        #expect(working.subagents.first?.name == "Research")
        #expect(working.subagents.first?.agentType == "Explore")
        let done = parse([call, launch, finish], format: .claude)
        #expect(done.workingSubagents.isEmpty)
        #expect(results(done).map(\.summary) == ["answer"])
        #expect(results(done).map(\.state) == [.completed])
    }
    @Test func codexSpawnAndClose() {
        let call = #"{"type":"response_item","payload":{"type":"function_call","call_id":"call","name":"spawn_agent","arguments":"{\"agent_type\":\"worker\"}"}}"#
        let result = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call","output":"{\"agent_id\":\"abc\"}"}}"#
        let close = #"{"type":"response_item","payload":{"type":"function_call","call_id":"close","name":"close_agent","arguments":"{\"id\":\"abc\"}"}}"#
        #expect(parse([call, result], format: .codex).workingSubagents.map(\.id) == ["abc"])
        let done = parse([call, result, close], format: .codex)
        #expect(done.workingSubagents.isEmpty)
        #expect(results(done).map(\.state) == [.cancelled])
    }
}

@Suite struct ChildTranscriptProbeTests {
    @Test func probesRealChildFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active ' child.jsonl")
        let exited = directory.appendingPathComponent("exited.jsonl")
        let stopped = directory.appendingPathComponent("stopped.jsonl")
        try Data("{\"type\":\"session\"}\n".utf8).write(to: active)
        try Data("{\"type\":\"custom\",\"customType\":\"session_exit\",\"data\":{\"reason\":\"dispose\"}}\n".utf8).write(to: exited)
        try Data().write(to: URL(fileURLWithPath: stopped.path + ".tombstone"))
        let client = HerdrClient(runner: LocalProcessRunner())
        let states = try await client.childTranscriptStates([
            "Active": active.path, "Exited": exited.path, "Stopped": stopped.path,
            "Missing": directory.appendingPathComponent("missing.jsonl").path
        ])
        #expect(states == ["Active": .active, "Exited": .exited, "Stopped": .tombstoned, "Missing": .missing])
    }

    /// omp creates its transcript on the first message, so a just-started agent has none yet.
    @Test func missingTranscriptReadsAsEmpty() async throws {
        let client = HerdrClient(runner: LocalProcessRunner())
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl").path
        let slice = try await client.readFileTail(path: path, from: 0, limit: 4096)
        #expect(slice.fileSize == 0 && slice.bytes.isEmpty)
        try Data("abcdef".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tail = try await client.readFileTail(path: path, from: 2, limit: 3)
        #expect(tail.fileSize == 6 && tail.bytes == Array("cde".utf8))
    }
}
