import Foundation
import HerdrAPI
import Testing

/// Record shapes copied from omp 18.3 session files.
private enum Line {
    static let title = #"{"type":"title","v":1,"title":"Pick a colour","source":"auto","updatedAt":"2026-09-24T03:33:27.930Z","pad":"      "}"#
    static let model = #"{"type":"model_change","id":"570d88be","parentId":null,"model":"anthropic/claude-haiku"}"#
    static let user = #"{"type":"message","id":"u1","parentId":"570d88be","message":{"role":"user","content":[{"type":"text","text":"Ask me which colour"}]}}"#
    static let assistant = #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Use the ask tool.","thinkingSignature":"x"},{"type":"text","text":"Let me ask."},{"type":"toolCall","id":"toolu_ask","name":"ask","arguments":{"questions":[{"id":"colour","header":"Colour","question":"Which colour?","options":[{"label":"Red","description":"warm"},{"label":"Green"},{"label":"Blue"}],"recommended":1}]}}]}}"#
    static let askStart = #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"toolu_ask","toolName":"ask"},"id":"c1","parentId":"a1"}"#
    static let askResult = #"{"type":"message","id":"r1","parentId":"c1","message":{"role":"toolResult","toolCallId":"toolu_ask","toolName":"ask","content":[{"type":"text","text":"User selected: Blue"}],"details":{"question":"Which colour?","options":["Red","Green","Blue"],"multi":false,"selectedOptions":["Blue"]},"isError":false}}"#
    static let bash = #"{"type":"message","id":"a2","parentId":"r1","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_bash","name":"bash","arguments":{"command":"swift build\necho done"}}]}}"#
    static let bashStart = #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"toolu_bash","toolName":"bash"},"id":"c2","parentId":"a2"}"#
    static let bashResult = #"{"type":"message","id":"r2","parentId":"c2","message":{"role":"toolResult","toolCallId":"toolu_bash","toolName":"bash","content":[{"type":"text","text":"error: nope"}],"isError":true}}"#
}

private func conversation(_ lines: [String]) -> Conversation {
    var reader = TranscriptReader()
    var conversation = Conversation()
    conversation.apply(reader.append(Array((lines.joined(separator: "\n") + "\n").utf8)))
    return conversation
}

/// A whole transcript file captured from a real agent session.
private func recorded(_ name: String, _ format: TranscriptFormat) throws -> Conversation {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Screens"))
    var reader = TranscriptReader(format: format)
    var conversation = Conversation()
    conversation.apply(reader.append(Array(try Data(contentsOf: url))))
    return conversation
}

private extension Conversation {
    var tools: [ToolActivity] { items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } } }
    var asks: [AskActivity] { items.compactMap { if case .ask(let ask) = $0 { ask } else { nil } } }
    var users: [String] { items.compactMap { if case .user(_, let text, _) = $0 { text } else { nil } } }
    var notices: [String] { items.compactMap { if case .notice(_, let text, _) = $0 { text } else { nil } } }
}

@Suite("Claude Code and Codex transcripts")
struct AgentTranscriptTests {
    @Test func claudeSessionReadsAsAConversation() throws {
        let claude = try recorded("claude-transcript", .claude)
        #expect(claude.users.count == 4)
        #expect(claude.users.first?.hasPrefix("Use the AskUserQuestion tool once") == true)

        #expect(claude.asks.count == 2)
        let pair = try #require(claude.asks.first)
        #expect(pair.questions.map(\.question) == ["Which color?", "Which toppings?"])
        #expect(pair.questions.map(\.multi) == [false, true])
        #expect(pair.answer?.perQuestion == ["Which color?": ["Blue"], "Which toppings?": ["Cheese", "Basil"]])
        let pet = try #require(claude.asks.last)
        #expect(pet.answer?.custom == "Hamster")
        #expect(pet.answer?.cancelled == false)

        #expect(claude.tools.map(\.name) == ["Bash", "Write", "Edit"])
        #expect(claude.tools.map(\.state) == [.succeeded, .succeeded, .failed])
        #expect(claude.tools.first?.summary == "date > when.txt && cat when.txt")
        #expect(claude.notices.contains { $0.hasPrefix("[Request interrupted by user") })
    }

    @Test func codexRolloutReadsAsAConversation() throws {
        let codex = try recorded("codex-transcript", .codex)
        #expect(codex.users.count >= 1)
        #expect(!codex.users.contains { $0.hasPrefix("<environment_context>") })
        let exec = try #require(codex.tools.first)
        #expect(exec.name == "exec_command")
        #expect(exec.summary == "curl -sI https://example.com | head -1")
        #expect(exec.state == .succeeded)
        #expect(exec.output?.hasPrefix("HTTP/2 200") == true)
        guard case .shell(let command, _, let exit) = exec.detail else { Issue.record("not a shell step"); return }
        #expect(command == "curl -sI https://example.com | head -1")
        #expect(exit == 0)
        #expect(codex.items.contains { if case .thinking = $0 { true } else { false } })
        #expect(codex.users.last?.hasPrefix("Now use apply_patch") == true)
    }

    /// Claude Code replaced TodoWrite with TaskCreate/TaskUpdate: ids come back in results.
    @Test func claudeTaskCallsFoldIntoOnePlan() throws {
        let claude = try recorded("claude-tasks", .claude)
        let boards = claude.tools.map { tool -> [TodoItem] in if case .todo(let items) = tool.detail { items } else { [] } }
        #expect(boards.first == [TodoItem(text: "Read the spec", state: .pending)])
        #expect(boards.last == [TodoItem(text: "Read the spec", state: .done),
                                TodoItem(text: "Write the parser", state: .active),
                                TodoItem(text: "Ship it", state: .pending)])
    }
}

@Suite("Transcript") struct TranscriptTests {
    @Test func holdsBackPartialLinesAndCountsConsumedBytes() {
        var reader = TranscriptReader()
        let bytes = Array((Line.title + "\n" + Line.user).utf8)
        #expect(reader.append(Array(bytes[..<10])).isEmpty)
        #expect(reader.consumedBytes == 0)
        #expect(reader.append(Array(bytes[10...])) == [.title("Pick a colour")])
        #expect(reader.consumedBytes == Line.title.utf8.count + 1)
        let rest = reader.append([0x0A])
        #expect(rest.count == 1)
        #expect(reader.consumedBytes == bytes.count + 1)
    }

    @Test func midFileReadSkipsTheCutLineAndKeepsGoingPastGarbage() {
        var reader = TranscriptReader(startsMidFile: true)
        let entries = reader.append(Array("ed\":1}\nnot json\n\(Line.model)\n".utf8))
        #expect(entries.count == 2)
        #expect(entries.first == .malformed("not json"))
        #expect(entries.last == .metadata(type: "model_change"))
    }

    @Test func askIsPendingUntilItsResultArrives() throws {
        let waiting = conversation([Line.title, Line.model, Line.user, Line.assistant, Line.askStart])
        #expect(waiting.title == "Pick a colour")
        #expect(waiting.items.map(\.id) == ["u1", "a1-thinking", "a1", "toolu_ask"])
        let ask = try #require(waiting.pendingAsk)
        #expect(ask.questions.first?.options.map(\.label) == ["Red", "Green", "Blue"])
        #expect(ask.questions.first?.recommended == 1)

        let answered = conversation([Line.user, Line.assistant, Line.askStart, Line.askResult])
        #expect(answered.pendingAsk == nil)
        guard case .ask(let done) = answered.item(id: "toolu_ask") else { Issue.record("ask missing"); return }
        #expect(done.answer == AskAnswer(text: "User selected: Blue", selected: ["Blue"], perQuestion: ["Which colour?": ["Blue"]]))
    }

    @Test func toolStartAndCallMergeIntoOneRowWithItsResult() {
        let started = conversation([Line.bashStart])
        #expect(started.items == [.tool(ToolActivity(id: "toolu_bash", name: "bash", summary: "bash"))])

        let finished = conversation([Line.bash, Line.bashStart, Line.bashResult])
        #expect(finished.items == [.tool(ToolActivity(id: "toolu_bash", name: "bash", summary: "swift build",
                                                      arguments: #"{"command":"swift build\necho done"}"#,
                                                      state: .failed, output: "error: nope"))])
    }

    @Test func digestKeepsTurningPointsAsksPeersNoticesAndTailTools() {
        var conversation = Conversation()
        conversation.apply([
            .message(.init(id: "u1", role: .user, text: "start")),
            .message(.init(id: "a1", role: .assistant, text: "brief one")),
            .message(.init(id: "a2", role: .assistant, text: "brief two")),
            .message(.init(id: "x1", role: .assistant, text: "## Heading\nbody")),
            .message(.init(id: "u2", role: .user, text: "next")),
            .peerMessage(id: "p1", peer: "sheep", text: "hello", outbound: false),
            .compaction(summary: "compressed"),
            .message(.init(id: "a3", role: .assistant, text: "intermediate reply")),
            .message(.init(id: "a5", role: .assistant, text: "final follow-up")),
            .message(.init(id: "a4", role: .assistant, text: "", thinking: "private thought")),
            .toolStarted(id: "running", name: "bash")
        ])
        let digest = conversation.items(at: .digest)
        #expect(digest.contains { if case .assistant(let id, _) = $0 { id == "a2" || id == "x1" || id == "a5" } else { false } })
        #expect(!digest.contains { if case .assistant(let id, _) = $0 { id == "a3" } else { false } })
        #expect(digest.contains { if case .notice(_, _, .compaction) = $0 { true } else { false } })
        #expect(digest.contains { if case .tool(let tool) = $0 { tool.id == "running" } else { false } })
        #expect(!digest.contains { if case .assistant(let id, _) = $0 { id == "a1" } else { false } })
        #expect(!digest.contains { if case .thinking = $0 { true } else { false } })
    }

    @Test func ircIncomingPreservesDetailsAndFallback() {
        let line = #"{"type":"custom_message","customType":"irc:incoming","display":true,"id":"m1","content":"fallback body","details":{"id":"msg-1","from":"alex","message":"hello"}}"#
        var reader = TranscriptReader()
        #expect(reader.append(Array((line + "\n").utf8)) == [.peerMessage(id: "msg-1", peer: "alex", text: "hello", outbound: false)])
        let fallback = #"{"type":"custom_message","customType":"irc:incoming","display":true,"id":"m2","content":"fallback body"}"#
        #expect(reader.append(Array((fallback + "\n").utf8)) == [.peerMessage(id: "m2", peer: "unknown", text: "fallback body", outbound: false)])
    }
    @Test func recordedIrcIncomingUsesPeerDetails() throws {
        let transcript = try recorded("omp-irc-incoming", .omp)
        #expect(transcript.items == [.peerMessage(id: "msg-42", peer: "Helper", text: "Hello from a peer.", outbound: false)])
    }

    @Test func agentWriteIsPeerMessageAndItsResultIsAbsorbed() {
        let call = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"write-1","name":"write","arguments":{"path":"agent://Helper","content":"A reply"}}]}}"#
        let result = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"write-1","content":"sent"}}"#
        let resultConversation = conversation([call, result])
        #expect(resultConversation.items == [.peerMessage(id: "write-1", peer: "Helper", text: "A reply", outbound: true)])
    }
    @Test func digestPreservesAsksAndLastFailedToolWhileOtherLevelsStayUnfiltered() {
        let waiting = conversation([Line.user, Line.assistant, Line.askStart])
        #expect(waiting.items(at: .digest).contains { if case .ask = $0 { true } else { false } })
        let failed = conversation([Line.bash, Line.bashStart, Line.bashResult, Line.user])
        #expect(failed.items(at: .digest).contains { if case .tool(let tool) = $0 { tool.state == .failed } else { false } })
        #expect(failed.items(at: .full) == failed.items)
        #expect(failed.items(at: .folded) == failed.items)
    }

    @Test func unknownRecordsSurviveAsRawRows() {
        let future = #"{"type":"hologram","id":"h1"}"#
        let items = conversation([future]).items
        guard case .raw(_, let type, let text) = items.first else { Issue.record("raw row missing"); return }
        #expect(type == "hologram")
        #expect(text == future)
    }
}
