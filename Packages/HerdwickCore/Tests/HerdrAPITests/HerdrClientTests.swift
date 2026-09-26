import Foundation
import HerdrTestSupport
import Testing
@testable import HerdrAPI

@Suite struct WireTests {
    @Test func shellQuoteSurvivesTheShell() async throws {
        let nasty = ["plain", "", "two words", "it's", "$(touch /tmp/x)", "a\"b\\c", "semi;colon", "w1:p1"]
        let runner = LocalProcessRunner()
        for word in nasty {
            let channel = try await runner.exec("printf '%s' " + shellQuote(word))
            try await channel.closeInput()
            var out: [UInt8] = []
            for try await chunk in channel.output { out += chunk }
            #expect(String(decoding: out, as: UTF8.self) == word)
        }
    }

    @Test func lineSplitterHandlesSplitAndBatchedLines() {
        var s = LineSplitter()
        #expect(s.append(Array("{\"a\":".utf8)) == [])
        #expect(s.append(Array("1}\n{\"b\":2}\n\n{\"c\"".utf8)) == [Array("{\"a\":1}".utf8), Array("{\"b\":2}".utf8)])
        #expect(s.append(Array(":3}\n".utf8)) == [Array("{\"c\":3}".utf8)])
    }

    @Test func apiErrorsAreTyped() throws {
        let line = Array(#"{"id":"1","error":{"code":"pane_not_found","message":"no pane w9:p9"}}"#.utf8)
        #expect(throws: HerdrError.api(code: "pane_not_found", message: "no pane w9:p9")) {
            let _: HerdrClient.Ignored = try HerdrClient.decodeResponse(line)
        }
    }

    /// Real wire shapes: structural events use underscores (`layout_updated`), status changes arrive dotted.
    @Test func eventsUseSubscriptionNamesAndTolerateUnknownStatus() throws {
        let line = Array(#"{"event":"pane.agent_status_changed","data":{"agent":"omp","pane_id":"w1:p1","workspace_id":"w1","agent_status":"napping"}}"#.utf8)
        let event = try HerdrClient.decodeEvent(line)
        #expect(event.kind == "pane.agent_status_changed")
        #expect(event.statusChange?.agentStatus == .unknown)
        #expect(try HerdrClient.decodeEvent(Array(#"{"event":"layout_updated","data":{}}"#.utf8)).kind == "layout.updated")
    }

    @Test func terminalCommandsMatchHerdrWireFormat() throws {
        func json(_ c: TerminalCommand) throws -> [String: String] {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
            return object.mapValues { "\($0)" }
        }
        #expect(try json(.text("hi")) == ["type": "terminal.input", "text": "hi"])
        #expect(try json(.bytes([0x1B, 0x5B, 0x41])) == ["type": "terminal.input", "bytes": "G1tB"])
        #expect(try json(.resize(cols: 100, rows: 30)) == ["type": "terminal.resize", "cols": "100", "rows": "30"])
        #expect(try json(.scroll(up: true, lines: 3)) == ["type": "terminal.scroll", "direction": "up", "lines": "3"])
        #expect(try json(.release) == ["type": "terminal.release"])
    }
}

/// Runs against the real herdr on this machine. `HERDWICK_LIVE=1 swift test`.
/// Read-only against the user's `main` session; writes use a throwaway session.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDWICK_LIVE"] == "1"), .serialized, .timeLimit(.minutes(1)))
struct LiveHerdrTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    @Test func discoversHerdrAndSessions() async throws {
        #expect(try await client.resolveHerdrPath().hasSuffix("herdr"))
        let sessions = try await client.sessions()
        #expect(sessions.contains { $0.name == "main" && $0.running })
    }

    @Test func pingAndSnapshot() async throws {
        let pong = try await client.ping(session: "main")
        #expect(pong.protocolVersion >= 22)
        let snapshot = try await client.snapshot(session: "main")
        #expect(!snapshot.workspaces.isEmpty)
        for agent in snapshot.agents {
            #expect(snapshot.panes.contains { $0.id == agent.paneID })
        }
        let ranks = snapshot.agentsByAttention.map(\.agentStatus.attentionRank)
        #expect(ranks == ranks.sorted())
    }

    @Test func unknownMethodIsATypedError() async throws {
        await #expect(throws: HerdrError.self) {
            let _: HerdrClient.Ignored = try await client.request("no.such.method", params: HerdrClient.EmptyParams(), session: "main")
        }
    }

    @Test func observeStartsWithAFullFrame() async throws {
        let pane = try #require(try await client.snapshot(session: "main").panes.first).id
        let terminal = try await client.terminal(pane: pane, session: "main", cols: 80, rows: 24, control: false)
        var first: TerminalMessage?
        for try await message in terminal.messages {
            first = message
            break
        }
        await terminal.close()
        guard case .frame(let frame) = first else {
            Issue.record("expected a frame, got \(String(describing: first))")
            return
        }
        #expect(frame.full && frame.width == 80 && frame.height == 24 && !frame.bytes.isEmpty)
    }

    /// Full write path on an isolated server: events, send_input, terminal control.
    @Test func writePathOnThrowawaySession() async throws {
        let session = "herdwick-test-\(UInt32.random(in: 0...UInt32.max))"
        let herdr = shellQuote(try await client.resolveHerdrPath())
        func sh(_ command: String) async throws {
            _ = try await HerdrClient.collect(try await LocalProcessRunner().exec(command))
        }
        // Null stdio so the daemon holds none of the runner's pipes open.
        try await sh("\(herdr) --session \(session) server </dev/null >/dev/null 2>&1 &")
        var failure: (any Error)?
        do { try await exerciseWritePath(session: session) } catch { failure = error }
        // herdr's server ignores SIGTERM; stop it through its API, then remove the session.
        try await sh("\(herdr) --session \(session) server stop >/dev/null 2>&1; for i in $(seq 30); do \(herdr) session delete \(session) >/dev/null 2>&1 && exit 0; sleep 0.1; done; exit 1")
        if let failure { throw failure }
    }

    private func exerciseWritePath(session: String) async throws {
        var snapshot: Snapshot?
        for _ in 0..<40 where snapshot?.panes.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(250))
            snapshot = try? await client.snapshot(session: session)
        }
        let pane = try #require(snapshot?.panes.first).id

        let events = try await client.events(session: session, subscriptions: Subscription.structural)
        let seen = Task { () -> [String] in
            var kinds: [String] = []
            for try await event in events {
                kinds.append(event.kind)
                if event.kind == "tab.renamed" { break }
            }
            return kinds
        }
        struct Rename: Encodable, Sendable { var tab_id: String; var label: String }
        let tab = try #require(snapshot?.tabs.first).id
        let _: HerdrClient.Ignored = try await client.request("tab.rename", params: Rename(tab_id: tab, label: "herdwick"), session: session)
        let kinds = try await seen.value
        #expect(kinds.last == "tab.renamed", "events: \(kinds)")

        try await client.sendText("printf 'herdwick-%s\\n' ok", pane: pane, submit: true, session: session)
        let terminal = try await client.terminal(pane: pane, session: session, cols: 60, rows: 20, control: true)
        try await terminal.send(.text("echo via-control\r"))
        var screen = ""
        for try await message in terminal.messages {
            if case .frame(let frame) = message { screen += String(decoding: frame.bytes, as: UTF8.self) }
            if screen.contains("herdwick-ok") && screen.contains("via-control") { break }
        }
        await terminal.close()
        #expect(screen.contains("herdwick-ok"))
        #expect(screen.contains("via-control"))

        // The mirror follows structure changes and re-subscribes for the new pane.
        var mirror = client.mirror(session: session).makeAsyncIterator()
        #expect(try await mirror.next()?.snapshot.panes.count == 1)
        struct Split: Encodable, Sendable { var direction = "right"; var target_pane_id: String }
        let _: HerdrClient.Ignored = try await client.request("pane.split", params: Split(target_pane_id: pane), session: session)
        var latest: Snapshot?
        repeat { latest = try await mirror.next()?.snapshot } while latest?.panes.count != 2
        let _: HerdrClient.Ignored = try await client.request("tab.rename", params: Rename(tab_id: tab, label: "mirrored"), session: session)
        repeat { latest = try await mirror.next()?.snapshot } while latest?.tabs.first?.label != "mirrored"
    }
}
