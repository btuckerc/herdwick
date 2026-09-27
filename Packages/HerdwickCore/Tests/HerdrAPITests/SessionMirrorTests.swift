import Foundation
@testable import HerdrAPI
import Synchronization
import Testing

@Suite struct SessionMirrorTests {
    @Test func statusBacklogKeepsOnlyTheLatestPerPane() async throws {
        let inbox = EventInbox()
        for index in 0..<10_000 {
            inbox.add(HerdrEvent(kind: "pane.agent_status_changed", statusChange: .init(
                paneID: "p", workspaceID: "w", agentStatus: index == 9_999 ? .done : .working)))
            inbox.add(HerdrEvent(kind: "tab.renamed"))
        }
        inbox.finish(nil)
        let batch = try #require(try await inbox.next())
        #expect(batch.keys.sorted() == ["p"])
        #expect(batch["p"]?.agentStatus == .done)
        #expect(try await inbox.next() == nil)
    }

    @Test func structuralBacklogStillRequestsASnapshot() async throws {
        let inbox = EventInbox()
        for _ in 0..<10_000 { inbox.add(HerdrEvent(kind: "tab.renamed")) }
        inbox.finish(nil)
        #expect(try await inbox.next() == [:])
        #expect(try await inbox.next() == nil)
    }

    /// After a suspension the host delivers its queued events at once; catching up must not
    /// cost a snapshot round trip per event.
    @Test func eventBacklogCostsAFewSnapshotsNotOneEach() async throws {
        let host = ScriptedHost(backlog: 50)
        var mirror = HerdrClient(runner: host, herdrPath: "/bin/herdr").mirror(session: "s").makeAsyncIterator()
        var updates = 0
        do {
            while try await mirror.next() != nil { updates += 1 }
        } catch HerdrError.noResponse {
            // The event bridge ended after its backlog, as a dead one would.
        }
        #expect(updates >= 3)
        // Preview, first live, then the backlog: at most a couple of passes, not 50.
        #expect(host.snapshots.withLock { $0 } <= 4)
    }

    /// A redial hints the panes it last saw; one that has gone makes herdr refuse the
    /// subscription, and the mirror must still go live on the preview's panes.
    @Test func staleHintFallsBackToThePreviewsPanes() async throws {
        let host = ScriptedHost(backlog: 0)
        let mirror = HerdrClient(runner: host, herdrPath: "/bin/herdr").mirror(session: "s", panes: ["gone"])
        var sawLive = false
        do {
            for try await update in mirror {
                if case .live = update { sawLive = true }
            }
        } catch HerdrError.noResponse {}
        #expect(sawLive)
    }
}

/// Answers `session.snapshot` after a short delay; `events.subscribe` acknowledges, then
/// sends `backlog` events line by line while the first live snapshot is in flight, then ends.
private final class ScriptedHost: CommandRunner {
    let backlog: Int
    let snapshots = Mutex(0)

    init(backlog: Int) { self.backlog = backlog }

    func exec(_ command: String) async throws -> any ExecChannel {
        ScriptedChannel(host: self)
    }

    fileprivate func respond(to request: [UInt8], output: AsyncThrowingStream<[UInt8], any Error>.Continuation) async {
        struct Request: Decodable { var method: String }
        guard let method = try? JSONDecoder().decode(Request.self, from: Data(request)).method else { return }
        switch method {
        case "session.snapshot":
            snapshots.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            output.yield(Array(#"{"id":"1","result":{"snapshot":{"version":"0","protocol":1,"workspaces":[],"tabs":[],"panes":[],"agents":[]}}}"#.utf8) + [0x0A])
            output.finish()
        case "events.subscribe":
            // Every scripted snapshot has no panes, so a pane subscription names one that is gone.
            if String(decoding: request, as: UTF8.self).contains("pane_id") {
                output.yield(Array(#"{"id":"events","error":{"code":"pane_not_found","message":"gone"}}"#.utf8) + [0x0A])
                output.finish()
                return
            }
            output.yield(Array(#"{"id":"events","result":{}}"#.utf8) + [0x0A])
            for _ in 0..<backlog {
                output.yield(Array(#"{"event":"tab_renamed","data":{}}"#.utf8) + [0x0A])
            }
            output.finish()
        default:
            output.finish()
        }
    }
}

private final class ScriptedChannel: ExecChannel {
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let host: ScriptedHost

    init(host: ScriptedHost) {
        self.host = host
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: [UInt8]) async throws {
        let line = Array(bytes.prefix { $0 != 0x0A })
        Task { [host, continuation] in await host.respond(to: line, output: continuation) }
    }

    func closeInput() async throws {}
    func close() async { continuation.finish() }
}
