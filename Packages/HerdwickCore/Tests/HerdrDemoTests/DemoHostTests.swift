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
        let first = try #require(try await snapshots.next())
        #expect(first.agents.map(\.agentStatus) == [.working])
        host.startClock()
        let next = try #require(try await snapshots.next())
        #expect(next.agents.map(\.agentStatus) == [.blocked])
        let refreshed = try #require(try await snapshots.next())
        #expect(refreshed.workspaces.first?.agentStatus == .blocked, "the snapshot re-derives the roll-up")
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
        await #expect(throws: (any Error).self) { _ = try await snapshots.next() }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: CommandError.channelClosed) { _ = try await client.sessions() }
    }

    @Test func rejectsStepsNamingUnknownPanes() throws {
        #expect(throws: DemoError.self) {
            _ = try Fixture.scenario(timeline: #"[{"t": 1, "do": "status", "pane": "p9", "status": "done"}]"#)
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

private enum Fixture {
    /// A one-pane scenario on disk with the given timeline JSON.
    static func scenario(timeline: String) throws -> DemoScenario {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "before".write(to: dir.appendingPathComponent("before.screen"), atomically: true, encoding: .utf8)
        try "after".write(to: dir.appendingPathComponent("after.screen"), atomically: true, encoding: .utf8)
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
              "timeline": \(timeline)
            }
            """
        try json.write(to: dir.appendingPathComponent("scenario.json"), atomically: true, encoding: .utf8)
        return try DemoScenario(directory: dir)
    }
}
