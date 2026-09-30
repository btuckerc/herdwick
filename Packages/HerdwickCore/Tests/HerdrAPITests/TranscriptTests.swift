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
    @Test func claudeArrayHarnessFilteringRetainsResultsAndRealImages() {
        var reader = TranscriptReader(format: .claude)
        let harness = #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>internal</system-reminder>"},{"type":"tool_result","tool_use_id":"call","content":"done"}]}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"internal"}]}}"#
        let image = #"{"type":"user","uuid":"image","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aA=="}}]}}"#
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let entries = reader.append(Array(([harness, meta, image, interrupted].joined(separator: "\n") + "\n").utf8))
        let messages = entries.compactMap { if case .message(let message) = $0 { message } else { nil } }
        #expect(messages.map(\.role) == [.toolResult, .user])
        #expect(messages.first?.text == "done")
        #expect(messages.last?.images.count == 1)
        #expect(entries.contains(.notice("[Request interrupted by user]")))
    }

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
    @Test func bytewiseRecordsPreserveUTF8AndSkippedPrefixOffsets() {
        let line = #"{"type":"message","id":"u","message":{"role":"user","content":"hé🐑"}}"# + "\n"
        var reader = TranscriptReader()
        var entries: [TranscriptEntry] = []
        for byte in line.utf8 { entries += reader.append([byte]) }
        #expect(entries == [.message(.init(id: "u", role: .user, text: "hé🐑"))])
        #expect(reader.consumedBytes == line.utf8.count)
        var mid = TranscriptReader(startsMidFile: true)
        #expect(mid.append(Array("discard".utf8)).isEmpty)
        #expect(mid.consumedBytes == 7)
        #expect(mid.append(Array(("tail\n" + line).utf8)) == entries)
        #expect(mid.consumedBytes == 12 + line.utf8.count)
    }

    @Test func toolOutputCapPreservesEmptyLinesAtBoundary() {
        for count in [0, 1, 199, 200, 201, 1000] {
            let text = Array(repeating: "", count: count).joined(separator: "\n") + "end\n"
            var conversation = Conversation()
            conversation.apply([.toolStarted(id: "call", name: "bash"),
                .message(.init(id: "result", role: .toolResult, text: text, toolCallId: "call"))])
            #expect(conversation.tools.first?.output == text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).joined(separator: "\n"))
        }
    }

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

    /// omp images are blob references resolved beside `sessions`; tool results carry theirs.
    @Test func imagesStayReferencesAndToolResultsKeepThem() throws {
        let hash = String(repeating: "ab", count: 32)
        let conversation = conversation([
            #"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"blob:sha256:\#(hash)","mimeType":"image/webp"}]}}"#,
            #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"shot.png"}}]}}"#,
            #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"},{"type":"image","data":"blob:sha256:short"}]}}"#,
        ])
        guard case .user(_, _, let images) = try #require(conversation.items.first) else { Issue.record("no user row"); return }
        let image = try #require(images.first)
        #expect(image.source == .blob(hash) && image.mimeType == "image/webp" && image.inlineData == nil)
        #expect(image.blobPath(transcript: "/home/u/.omp/agent/sessions/--repo--/2026.jsonl") == "/home/u/.omp/agent/blobs/" + hash)
        #expect(image.blobPath(transcript: "/home/u/.omp/agent/sessions/--repo--/2026/Child.jsonl") == "/home/u/.omp/agent/blobs/" + hash)
        guard case .tool(let tool) = conversation.items.last else { Issue.record("no tool row"); return }
        #expect(tool.images.count == 1)
        #expect(tool.images.first?.inlineData == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
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
        let started = #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"write-1","toolName":"write"}}"#
        let result = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"write-1","content":"sent"}}"#
        let resultConversation = conversation([call, started, result])
        #expect(resultConversation.items == [.peerMessage(id: "write-1", peer: "Helper", text: "A reply", outbound: true)])
    }
    @Test func digestPreservesAsksAndLastFailedToolWhileOtherLevelsStayUnfiltered() {
        let waiting = conversation([Line.user, Line.assistant, Line.askStart])
        #expect(waiting.items(at: .digest).contains { if case .ask = $0 { true } else { false } })
        let failed = conversation([Line.bash, Line.bashStart, Line.bashResult, Line.user])
        #expect(failed.items(at: .digest).contains { if case .tool(let tool) = $0 { tool.state == .failed } else { false } })
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

/// Background work in omp's director loops: `bash` with `async`, `wait`, and the later delivery.
@Suite("Steps") struct StepTests {
    private static let bench = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"bash","arguments":{"command":"npm run bench","async":true}}]}}"#
    private static let benchResult = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"b1","toolName":"bash","content":[{"type":"text","text":"Backgrounded as job bg_1."}],"details":{"async":{"state":"running","jobId":"bg_1","type":"bash"}}}}"#
    private static let wait = #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"toolCall","id":"w1","name":"wait","arguments":{}}]}}"#
    private static let waitResult = ###"{"type":"message","id":"r2","message":{"role":"toolResult","toolCallId":"w1","toolName":"wait","content":[{"type":"text","text":"## Completed (1)"}],"details":{"op":"wait","jobs":[{"id":"bg_1","type":"bash","status":"completed","label":"npm run bench","resultText":"p99=4.2ms"}]}}}"###
    private static let delivery = #"{"type":"custom_message","customType":"async-result","content":"<system-notice>Background job bg_1 has completed.\np99=4.2ms</system-notice>","details":{"jobs":[{"jobId":"bg_1","type":"bash","label":"npm run bench"}]}}"#

    private func jobs(_ c: Conversation) -> [ToolActivity] {
        c.items.compactMap { if case .tool(let tool) = $0, tool.name == "job" { tool } else { nil } }
    }

    @Test func waitNamesBackgroundWorkAndItsResultIsTheOnlyDeliveryShownOnce() {
        let waiting = conversation([Self.bench, Self.benchResult, Self.wait])
        #expect(waiting.waitingOn == ["npm run bench"])
        #expect(StepRun(waiting.items, waitingOn: waiting.waitingOn).running == "Waiting on npm run bench")

        // The wait can be the only place the output arrives…
        let waited = conversation([Self.bench, Self.benchResult, Self.wait, Self.waitResult])
        #expect(waited.waitingOn.isEmpty)
        #expect(jobs(waited).map(\.output) == ["p99=4.2ms"])
        // …and omp's own delivery after it doesn't show it twice, whichever comes first.
        #expect(jobs(conversation([Self.bench, Self.benchResult, Self.wait, Self.waitResult, Self.delivery])).count == 1)
        #expect(jobs(conversation([Self.bench, Self.benchResult, Self.wait, Self.delivery, Self.waitResult])).count == 1)
    }

    @Test func aBackgroundedTaskIsASubagentNotABackgroundCommand() {
        let call = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"task","arguments":{"tasks":[{"name":"Council"}]}}]}}"#
        let result = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"t1","toolName":"task","content":[{"type":"text","text":"Spawned agent `Council`."}],"details":{"async":{"state":"running","jobId":"Council","type":"task"}}}}"#
        #expect(conversation([call, result]).backgroundCommands.isEmpty)
        #expect(conversation([Self.bench, Self.benchResult]).backgroundCommands == ["npm run bench"])
    }

    @Test func undeliveredBriefIsAnError() {
        let call = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"m1","name":"write","arguments":{"path":"agent://Gone","content":"Hi"}}]}}"#
        let result = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"m1","toolName":"write","content":[{"type":"text","text":"No agent named Gone."}],"isError":true}}"#
        #expect(conversation([call, result]).items.last == .notice(id: "m1-undelivered", text: "Not delivered to Gone: No agent named Gone.", kind: .error))
    }

    @Test func runLabelCountsWhatItDidWithErrorsLeading() {
        func tool(_ name: String, _ summary: String, _ state: ToolActivity.State = .succeeded) -> ConversationItem {
            .tool(ToolActivity(id: UUID().uuidString, name: name, summary: summary, state: state))
        }
        let mixed = StepRun([tool("read", "src/a.swift"), tool("grep", "TODO"), tool("edit", "src/a.swift"), tool("edit", "src/a.swift"),
                             tool("bash", "swift test", .failed), tool("bash", "swift build"),
                             .peerMessage(id: "p", peer: "Helper", text: "Go", outbound: true)])
        #expect(mixed.failure == "1 error")
        #expect(mixed.label == "2 edits · 1 read · 1 command · 1 search · 1 message")
        // Every line is counted (the failed call as the error), so no separate step count.
        #expect(!mixed.showsSteps)
        // One call or a few read the same way as many: counts, never a file or command name.
        let lone = StepRun([tool("edit", "src/a.swift")])
        #expect(lone.label == "1 edit")
        #expect(!lone.showsSteps)
        #expect(StepRun([tool("bash", "swift build"), .thinking(id: "t", text: "hm")]).label == "1 command")
        #expect(StepRun([tool("read", "a.swift"), tool("read", "b.swift"), tool("grep", "x")]).label == "2 reads · 1 search")
        // A wait a message interrupted, a process stopped and waits alone aren't failures, edits or news.
        let control = StepRun([tool("wait", "wait", .failed), tool("write", "proc://tail/kill"), tool("wait", "wait")])
        #expect(control.failure == nil)
        #expect(control.label == "Stopped tail")
        // A running command reads by its name, not its flags and redirections.
        #expect(StepRun([tool("read", "a.swift"), tool("eval", "Plot p99", .running),
                         tool("bash", "npm run bench -- --rps 2000 > /tmp/soak.log", .running)]).running == "Running npm run bench +1")
    }

    @Test func onlyALoneBriefPairsWithTheNextWordFromThatAgent() {
        func brief(_ id: String, _ peer: String) -> ConversationItem { .peerMessage(id: id, peer: peer, text: "Review", outbound: true) }
        func reply(_ id: String, _ peer: String) -> ConversationItem { .peerMessage(id: id, peer: peer, text: "GO", outbound: false) }
        let result = ConversationItem.subagentResult(id: "r", activity: SubagentActivity(id: "Lock", name: "Lock", state: .completed, summary: "Done"))
        let answered = [brief("b1", "Council"), brief("b2", "Lock"), reply("x1", "Council"), result,
                        // Two briefs before one answer, and an answer to nothing, stay apart.
                        brief("b3", "Council"), brief("b4", "Council"), reply("x2", "Council"), reply("x3", "Council")].answeredBriefs()
        #expect(answered.mapValues(\.id) == ["x1": "b1", "r": "b2"])
    }

    @Test func catchUpCountsWhatFollowedTheLastSeenItem() {
        let said = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Starting."}]}}"#
        let write = #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"toolCall","id":"w1","name":"write","arguments":{"path":"src/b.swift","content":"x"}}]}}"#
        let wrote = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"w1","toolName":"write","content":[{"type":"text","text":"Wrote."}]}}"#
        let test = #"{"type":"message","id":"a3","message":{"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"swift test"}}]}}"#
        let failed = #"{"type":"message","id":"r2","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","content":[{"type":"text","text":"1 failure"}],"isError":true}}"#
        let c = conversation([said, write, wrote, test, failed])
        let up = c.catchUp(after: "a1")
        #expect([up?.items, up?.edits, up?.replies, up?.failures, up?.images] == [2, 1, 0, 1, 0])
        #expect(c.catchUp(after: "t1") == nil)
        #expect(c.editCount == 1)
        #expect(c.recordedEdits.map(\.path) == ["src/b.swift"])
    }

    @Test func aNamedFileResolvesToTheNewestPathATouchedIt() {
        let read = #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/tmp/old/a.png"}}]}}"#
        let copy = #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"scp mini:/tmp/shots/a.png '/tmp/shots/a.png'"}}]}}"#
        let copied = #"{"type":"message","id":"r2","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","content":[{"type":"text","text":"/tmp/shots/notes.md"}]}}"#
        let write = #"{"type":"message","id":"a3","message":{"role":"assistant","content":[{"type":"toolCall","id":"c3","name":"write","arguments":{"path":"src/Views/b.swift","content":"x"}}]}}"#
        let fetch = #"{"type":"message","id":"a4","message":{"role":"assistant","content":[{"type":"toolCall","id":"c4","name":"bash","arguments":{"command":"curl -O https://example.com/c.png"}}]}}"#
        let ranged = #"{"type":"message","id":"a5","message":{"role":"assistant","content":[{"type":"toolCall","id":"c5","name":"read","arguments":{"path":"src/Views/d.swift:42-60"}}]}}"#
        let c = conversation([read, copy, copied, write, fetch, ranged])
        #expect(c.touchedFile("a.png")?.path == "/tmp/shots/a.png")
        #expect(c.touchedFile("/tmp/old/a.png")?.path == "/tmp/old/a.png")
        // A full path is only itself, never a longer path ending in it.
        #expect(c.touchedFile("/shots/a.png") == nil)
        #expect(c.touchedFile("notes.md")?.path == "/tmp/shots/notes.md")
        #expect(c.touchedFile("Views/b.swift")?.path == "src/Views/b.swift")
        // A URL isn't a file on the host; a read's line selector isn't part of its path.
        #expect(c.touchedFile("c.png") == nil)
        #expect(c.touchedFile("d.swift")?.path == "src/Views/d.swift")
        #expect(c.touchedFile("b.png") == nil)
        #expect(c.touchedFile("s/b.swift") == nil)
    }
}
