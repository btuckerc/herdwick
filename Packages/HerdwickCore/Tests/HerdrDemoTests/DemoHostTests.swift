import Foundation
import Testing
import HerdrAPI
@testable import HerdrDemo

/// The demo host must satisfy the real `HerdrClient`, or the in-app demo and every
/// marketing capture break. These tests drive it only through the client.
@Suite struct DemoHostTests {
    @Test func bundledScenariosLoadAndPreviewStartsFromStudio() async throws {
        let studio = try DemoScenario.bundled("studio")
        let preview = try DemoScenario.bundled("preview")
        _ = try DemoScenario.bundled("replied")
        #expect(preview.host == studio.host)
        #expect(preview.duration >= 15 && preview.duration <= 28, "App Store previews run 15–30 s")

        let client = HerdrClient(runner: DemoHost(scenario: preview))
        let snapshot = try await client.snapshot(session: "main")
        #expect(snapshot.agents.first { $0.paneID == "p1" }?.agentStatus == .working, "setup runs before the clock")
    }

    @Test func servesSessionsAndMirrorsTimelineStatusChanges() async throws {
        let scenario = try Fixture.scenario(timeline: #"[{"t": 0.05, "do": "status", "pane": "p1", "status": "blocked"}]"#)
        let host = DemoHost(scenario: scenario)
        let client = HerdrClient(runner: host)
        #expect(try await client.sessions().map(\.name) == ["main"])
        #expect(try await client.ping(session: "main").protocolVersion == 22)

        var snapshots = client.mirror(session: "main").makeAsyncIterator()
        guard case .preview(let preview) = try await snapshots.next() else { Issue.record("expected a preview first"); return }
        #expect(preview.agents.map(\.agentStatus) == [.working])
        guard case .live(let first) = try await snapshots.next() else { Issue.record("expected a live snapshot next"); return }
        #expect(first.agents.map(\.agentStatus) == [.working])
        host.startClock()
        let next = try #require(try await snapshots.next())
        #expect(next.snapshot.agents.map(\.agentStatus) == [.blocked])
        let refreshed = try #require(try await snapshots.next())
        #expect(refreshed.snapshot.workspaces.first?.agentStatus == .blocked, "the snapshot re-derives the roll-up")
    }

    @Test func sendingToAPaneRunsItsTriggerAndRepaintsTheTerminal() async throws {
        let scenario = try Fixture.scenario(timeline: #"""
            [{"on": "send_input", "pane": "p1", "then": [{"after": 0.05, "do": "screen", "pane": "p1", "screen": "after.screen"}]}]
            """#)
        let client = HerdrClient(runner: DemoHost(scenario: scenario))
        let terminal = try await client.terminal(pane: "p1", session: "main", cols: 20, rows: 4, control: false)
        var messages = terminal.messages.makeAsyncIterator()
        guard case .frame(let before) = try await messages.next() else { Issue.record("no first frame"); return }
        #expect(before.width == 20 && before.height == 4 && before.full)
        #expect(String(decoding: before.bytes, as: UTF8.self).contains("before"))

        try await client.sendText("yes", pane: "p1", submit: true, session: "main")
        guard case .frame(let after) = try await messages.next() else { Issue.record("no repaint"); return }
        #expect(after.seq > before.seq)
        #expect(String(decoding: after.bytes, as: UTF8.self).contains("after"))

        try await terminal.send(.resize(cols: 30, rows: 6))
        guard case .frame(let resized) = try await messages.next() else { Issue.record("no resize repaint"); return }
        #expect(resized.width == 30 && resized.height == 6)
        await terminal.close()
    }

    @Test func dropEndsTheMirrorAndRefusesCommandsUntilItRecovers() async throws {
        let scenario = try Fixture.scenario(timeline: #"[{"t": 0.05, "do": "drop", "for": 0.3}]"#)
        let host = DemoHost(scenario: scenario)
        let client = HerdrClient(runner: host)
        var snapshots = client.mirror(session: "main").makeAsyncIterator()
        _ = try await snapshots.next()
        _ = try await snapshots.next()
        host.startClock()
        await #expect(throws: (any Error).self) { _ = try await snapshots.next() }
        await #expect(throws: CommandError.channelClosed) { _ = try await client.snapshot(session: "main") }
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await client.snapshot(session: "main").agents.count == 1)
    }

    @Test func dropAfterReadyHoldsTheLinkDownOnceLive() async throws {
        let host = DemoHost(scenario: try Fixture.scenario(timeline: "[]"), dropAfterReady: true)
        let client = HerdrClient(runner: host)
        var snapshots = client.mirror(session: "main").makeAsyncIterator()
        _ = try await snapshots.next()
        _ = try await snapshots.next()
        await #expect(throws: (any Error).self) { _ = try await snapshots.next() }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: CommandError.channelClosed) { _ = try await client.sessions() }
    }

    @Test func rejectsStepsNamingUnknownPanes() throws {
        #expect(throws: DemoError.self) {
            _ = try Fixture.scenario(timeline: #"[{"t": 1, "do": "status", "pane": "p9", "status": "done"}]"#)
        }
    }

    @Test(.timeLimit(.minutes(1))) func transcriptsReadFollowAndAppendThroughClient() async throws {
        let scenario = try DemoScenario.bundled("studio")
        let client = HerdrClient(runner: DemoHost(scenario: scenario))
        let snapshot = try await client.snapshot(session: "main")
        let ref = try #require(snapshot.agents.first { $0.paneID == "p1" }?.agentSession)
        let location = try #require(try await client.locateTranscript(ref, pane: "p1", session: "main"))
        let initial = try await client.readFileTail(path: location.path, from: 0, limit: 100_000)
        #expect(initial.fileSize == initial.bytes.count)
        let slice = try await client.readFileTail(path: location.path, from: 13, limit: 27)
        #expect(slice.bytes == Array(initial.bytes[13..<40]))
        #expect(slice.fileSize == initial.fileSize)
        #expect(try await client.readFileTail(path: location.path, from: initial.fileSize + 10, limit: 40).bytes.isEmpty)
        #expect(try await client.readFileTail(path: "/missing.jsonl", from: 0, limit: 40).fileSize == 0)

        var stream = client.followFile(path: location.path, from: 13).makeAsyncIterator()
        #expect(try await stream.next() == Array(initial.bytes.dropFirst(13)))
        var reader = TranscriptReader()
        var conversation = Conversation()
        conversation.apply(reader.append(initial.bytes))
        let ask = try #require(conversation.pendingAsk)
        let prompt = try #require(ScreenPrompt.parse(try await client.readPane("p1", session: "main").text))
        #expect(prompt.title == ask.questions[0].question)
        #expect(prompt.options.map(\.label) == ask.questions[0].options.map(\.label))

        try await PromptDriver.answer(ask, replies: [.init(selected: ["Run migrations, then deploy"])],
                                      io: DemoPromptIO(client: client, path: location.path))
        conversation.apply(reader.append(try #require(try await stream.next())))
        #expect(conversation.pendingAsk == nil)
        conversation.apply(reader.append(try #require(try await stream.next())))
        #expect(conversation.items.last?.id == "deploy-final")
        let finished = try await client.readFileTail(path: location.path, from: initial.fileSize, limit: 100_000)
        var finishedReader = TranscriptReader()
        #expect(finishedReader.append(finished.bytes).contains { if case .message(let message) = $0 { message.id == "deploy-final" } else { false } })
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await client.snapshot(session: "main").agents.first { $0.paneID == "p1" }?.agentStatus == .done)
    }

    @Test(.timeLimit(.minutes(1))) func timelineAppendAndChildTranscripts() async throws {
        let scenario = try Fixture.scenario(timeline: #"[{"t":0.01,"do":"append","pane":"p1","records":"reply.jsonl"}]"#, transcript: true)
        let host = DemoHost(scenario: scenario)
        let client = HerdrClient(runner: host)
        let path = DemoScenario.transcriptPath("p1")
        let head = try await client.readFileTail(path: path, from: 0, limit: 1000)
        var stream = client.followFile(path: path, from: head.fileSize).makeAsyncIterator()
        host.startClock()
        let appended = try #require(try await stream.next())
        #expect(String(decoding: appended, as: UTF8.self) == "{\"type\":\"title\",\"title\":\"After\"}\n")

        let studio = HerdrClient(runner: DemoHost(scenario: try .bundled("studio")))
        let parent = DemoScenario.transcriptPath("p5")
        let active = try #require(SubagentTranscript.path(parentPath: parent, format: .omp, subagentID: "boundary-tests"))
        let exited = try #require(SubagentTranscript.path(parentPath: parent, format: .omp, subagentID: "redis-check"))
        #expect(try await studio.childTranscriptStates(["active": active, "exited": exited, "gone": "/gone.jsonl"]) == ["active": .active, "exited": .exited, "gone": .missing])
        var reader = TranscriptReader()
        var conversation = Conversation()
        conversation.apply(reader.append(try await studio.readFileTail(path: parent, from: 0, limit: 100_000).bytes))
        #expect(conversation.workingSubagents.map(\.id) == ["boundary-tests"])
        #expect(conversation.subagents.first { $0.id == "redis-check" }?.state == .completed)
        let child = try await studio.readFileTail(path: active, from: 0, limit: 100_000)
        var childReader = TranscriptReader()
        var childConversation = Conversation()
        childConversation.apply(childReader.append(child.bytes))
        #expect(childConversation.items.contains { if case .tool(let tool) = $0 { tool.id == "boundary-run" && tool.state == .running } else { false } })
    }

    @Test(.timeLimit(.minutes(1))) func previewComposerSendContinuesConversation() async throws {
        let client = HerdrClient(runner: DemoHost(scenario: try .bundled("preview")))
        let path = DemoScenario.transcriptPath("p1")
        let head = try await client.readFileTail(path: path, from: 0, limit: 100_000)
        var stream = client.followFile(path: path, from: head.fileSize).makeAsyncIterator()
        try await client.sendText("Run the migrations first, then deploy", pane: "p1", submit: true, session: "main")
        var reader = TranscriptReader()
        var conversation = Conversation()
        conversation.apply(reader.append(head.bytes))
        conversation.apply(reader.append(try #require(try await stream.next())))
        #expect(conversation.pendingAsk == nil)
        conversation.apply(reader.append(try #require(try await stream.next())))
        #expect(conversation.items.contains { if case .tool(let tool) = $0 { tool.id == "deploy-run" && tool.state == .succeeded } else { false } })
    }

    @Test func appendRequiresDeclaredTranscript() throws {
        #expect(throws: DemoError.self) {
            _ = try Fixture.scenario(timeline: #"[{"t":0,"do":"append","pane":"p1","records":"reply.jsonl"}]"#)
        }
    }
}

@Suite struct ScreenMarkupTests {
    @Test func footerPinsToTheBottomAndBodyWrapsWithHangingIndent() {
        let markup = """
            <b>●</> first line
              a long body line that has to wrap
            <footer>
            <rule>
            > prompt
            """
        let rows = ScreenMarkup.text(markup, cols: 16, rows: 7)
        #expect(rows == [
            "● first line",
            "  a long body",
            "  line that has",
            "  to wrap",
            "",
            "────────────────",
            "> prompt",
        ])
    }

    @Test func tallBodiesShowTheirLastLinesAboveTheFooter() {
        let markup = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n<footer>\nfoot\n"
        #expect(ScreenMarkup.text(markup, cols: 10, rows: 3) == ["line 9", "line 10", "foot"])
    }

    @Test func stylesBecomeSGRAndResetAtRowEnds() {
        let bytes = String(decoding: ScreenMarkup.render("<red>err</> ok", cols: 10, rows: 1), as: UTF8.self)
        #expect(bytes.contains("\u{1B}[0;31merr\u{1B}[0m ok\u{1B}[0m"))
    }
}

private struct DemoPromptIO: PromptIO {
    let client: HerdrClient
    let path: String
    func readVisible() async throws -> String { try await client.readPane("p1", session: "main").text }
    func send(keys: [String]) async throws { try await client.sendKeys(keys, pane: "p1", session: "main") }
    func type(_ text: String) async throws { try await client.sendText(text, pane: "p1", submit: false, session: "main") }
    func waitForResult(toolCallId: String, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            var reader = TranscriptReader()
            var conversation = Conversation()
            conversation.apply(reader.append(try await client.readFileTail(path: path, from: 0, limit: 100_000).bytes))
            if case .ask(let ask) = conversation.item(id: toolCallId), ask.answer != nil { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private enum Fixture {
    /// A one-pane scenario on disk with the given timeline JSON.
    static func scenario(timeline: String, transcript: Bool = false) throws -> DemoScenario {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "before".write(to: dir.appendingPathComponent("before.screen"), atomically: true, encoding: .utf8)
        try "after".write(to: dir.appendingPathComponent("after.screen"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"type\":\"title\",\"title\":\"Before\"}\n".write(to: dir.appendingPathComponent("initial.jsonl"), atomically: true, encoding: .utf8)
        try "{\"type\":\"title\",\"title\":\"After\"}\n".write(to: dir.appendingPathComponent("reply.jsonl"), atomically: true, encoding: .utf8)
        let json = """
            {
              "host": {"name": "box", "address": "box", "user": "me"},
              "herdr": {"version": "0.9.1", "protocol": 22},
              "sessions": [{"name": "main", "default": true, "running": true}],
              "snapshot": {
                "version": "0.9.1", "protocol": 22,
                "workspaces": [{"workspace_id": "w1", "number": 1, "label": "app", "focused": true, "agent_status": "working"}],
                "tabs": [{"tab_id": "t1", "workspace_id": "w1", "number": 1, "label": "", "focused": true, "agent_status": "working"}],
                "panes": [{"pane_id": "p1", "workspace_id": "w1", "tab_id": "t1", "focused": true, "agent_status": "working", "revision": 1}],
                "agents": [{"pane_id": "p1", "workspace_id": "w1", "tab_id": "t1", "agent_status": "working", "focused": true}]
              },
              "screens": {"p1": "before.screen"},
              "transcripts": \(transcript ? #"{"p1":"initial.jsonl"}"# : "{}"),
              "timeline": \(timeline)
            }
            """
        try json.write(to: dir.appendingPathComponent("scenario.json"), atomically: true, encoding: .utf8)
        return try DemoScenario(directory: dir)
    }
}
