import Foundation
@testable import HerdrAPI
import HerdrTestSupport
import Testing

/// Claude Code 2.1.319 shapes (sanitized): a director launches background seats, each seat's
/// end wakes it for a turn of its own; only the turn that leaves nothing running alerts.
@Suite struct TurnSettleTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    static func human(_ text: String, at: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u-\#(at)","timestamp":"\#(at)","permissionMode":"bypassPermissions","origin":{"kind":"human"},"promptSource":"typed","turnOrigin":"human"}"#
    }
    static func launch(_ task: String, at: String) -> String {
        #"{"isSidechain":false,"type":"user","uuid":"l-\#(task)","timestamp":"\#(at)","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"\#(task)"},"message":{"role":"user","content":[{"tool_use_id":"toolu_\#(task)","type":"tool_result","content":"Command running in background with ID: \#(task). Output is being written to: /tmp/t/\#(task).output.","is_error":false}]}}"#
    }
    static func wake(_ task: String, status: String = "completed", at: String) -> String {
        #"{"isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>\#(task)</task-id>\n<tool-use-id>toolu_\#(task)</tool-use-id>\n<output-file>/tmp/t/\#(task).output</output-file>\n<status>\#(status)</status>\n<summary>Background command \"seat\" completed (exit code 0)</summary>\n</task-notification>"},"uuid":"w-\#(task)","timestamp":"\#(at)","origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","turnOrigin":"task_notification"}"#
    }
    static func midTurn(_ task: String, at: String) -> String {
        #"{"isSidechain":false,"attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>\#(task)</task-id>\n<status>completed</status>\n<summary>Background command \"x\" completed (exit code 0)</summary>\n</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}},"type":"attachment","uuid":"q-\#(task)","timestamp":"\#(at)"}"#
    }
    static func reply(_ text: String, at: String) -> String {
        #"{"isSidechain":false,"type":"assistant","uuid":"a-\#(at)","timestamp":"\#(at)","effort":"high","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}}"#
    }
    static func ended(at: String) -> String {
        #"{"isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":1000,"messageCount":3,"timestamp":"\#(at)","isMeta":false}"#
    }
    /// Tool output that quotes the keys (a grep over transcripts) must not count.
    static let quoted = #"{"type":"user","uuid":"g","timestamp":"2026-11-20T00:30:00Z","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"{\"turnOrigin\":\"human\",\"backgroundTaskId\":\"zzz\"}"}]}}"#

    private func settle(_ lines: [String]) async throws -> TurnSettle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settle \(UUID().uuidString) it's.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(try await client.turnSettle(path: url.path))
    }

    @Test func aCouncilAlertsOnItsLaunchTurnAndItsLastSeatOnly() async throws {
        var lines = [Self.human("run the council", at: "2026-11-20T00:00:00Z"),
                     Self.launch("seat1", at: "2026-11-20T00:00:01Z"), Self.launch("seat2", at: "2026-11-20T00:00:02Z"),
                     Self.quoted, Self.reply("Waiting on seats.", at: "2026-11-20T00:00:03Z"), Self.ended(at: "2026-11-20T00:00:04Z")]
        let launched = try await settle(lines)
        #expect(launched.origin == .human && launched.ended && launched.pending == 2)
        #expect(launched.endedAt == TranscriptMessage.date("2026-11-20T00:00:04Z"))
        #expect(launched.hostNow != nil)
        #expect(!launched.holds())

        lines += [Self.wake("seat1", at: "2026-11-20T00:10:00Z"), Self.reply("One in.", at: "2026-11-20T00:10:01Z"), Self.ended(at: "2026-11-20T00:10:02Z")]
        let first = try await settle(lines)
        #expect(first.origin == .wake && first.ended && first.pending == 1)
        // The backstop counts on the host's clock: ten minutes after the turn ended it alerts anyway.
        let ended = try #require(first.endedAt)
        let young = TurnSettle(origin: .wake, ended: true, pending: 1, endedAt: ended, hostNow: ended.addingTimeInterval(60), scannedAt: Date(timeIntervalSince1970: 0))
        #expect(young.holds(now: Date(timeIntervalSince1970: 500)))
        #expect(!young.holds(now: Date(timeIntervalSince1970: 541)))
        #expect(young.releaseAt(now: Date(timeIntervalSince1970: 500)) == Date(timeIntervalSince1970: 540))
        #expect(!first.holds(), "fixture times are long past: expired, so it alerts")

        // Still mid-turn (no turn_duration yet): not held, so the caller re-checks.
        let midway = try await settle(lines + [Self.wake("seat2", status: "failed", at: "2026-11-20T00:15:00Z")])
        #expect(!midway.ended)

        lines += [Self.wake("seat2", status: "failed", at: "2026-11-20T00:15:00Z"), Self.reply("Both in.", at: "2026-11-20T00:15:01Z"), Self.ended(at: "2026-11-20T00:15:02Z")]
        let last = try await settle(lines)
        #expect(last.origin == .wake && last.pending == 0)
        #expect(!last.holds(now: TranscriptMessage.date("2026-11-20T00:15:03Z")!))
    }

    @Test func aMidTurnDeliveryClosesItsTaskAndACheckInKeepsTheRest() async throws {
        var lines = [Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                     Self.midTurn("a", at: "2026-11-20T00:00:05Z"), Self.launch("b", at: "2026-11-20T00:00:06Z"),
                     Self.launch("c", at: "2026-11-20T00:00:07Z"),
                     Self.human("how is it going?", at: "2026-11-20T00:01:00Z"), Self.ended(at: "2026-11-20T00:01:02Z")]
        let checkIn = try await settle(lines)
        #expect(checkIn.origin == .human && checkIn.ended && checkIn.pending == 2)
        // A seat back after the check-in is still not the last one.
        lines += [Self.wake("b", at: "2026-11-20T00:05:00Z"), Self.ended(at: "2026-11-20T00:05:02Z")]
        let wake = try await settle(lines)
        #expect(wake.origin == .wake && wake.pending == 1)
    }

    @Test func aTaskThatNeverReportsStopsCountingAfterThreeHours() async throws {
        let s = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("old", at: "2026-11-20T00:00:01Z"),
                                  Self.human("later", at: "2026-11-20T04:00:00Z"), Self.launch("x", at: "2026-11-20T04:00:01Z"),
                                  Self.wake("x", at: "2026-11-20T04:10:00Z"), Self.ended(at: "2026-11-20T04:10:02Z")])
        #expect(s.origin == .wake && s.pending == 0)
    }

    @Test func anOlderTranscriptWithoutOriginsNeverHolds() async throws {
        let s = try await settle([#"{"type":"user","uuid":"1","message":{"role":"user","content":"hi"}}"#, Self.ended(at: "2026-11-20T00:00:02Z")])
        #expect(s.origin == .none)
        #expect(!s.holds())
    }

    static func queuedPrompt(_ text: String, at: String) -> String {
        #"{"isSidechain":false,"attachment":{"type":"queued_command","prompt":"\#(text)","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true},"type":"attachment","uuid":"qp-\#(at)","timestamp":"\#(at)"}"#
    }

    @Test func aMessageTypedMidTurnMakesItThePersonsTurn() async throws {
        let s = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                  Self.launch("b", at: "2026-11-20T00:00:02Z"), Self.wake("a", at: "2026-11-20T00:05:00Z"),
                                  Self.queuedPrompt("status?", at: "2026-11-20T00:05:01Z"), Self.ended(at: "2026-11-20T00:05:09Z")])
        #expect(s.origin == .human && s.pending == 1)
    }

    @Test func badTimesAndUnmarkedPromptsFailOpen() async throws {
        let s = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                  Self.wake("x", at: "2026-11-20T00:05:00Z"), Self.ended(at: "2026-11-20T00:99:00Z")])
        #expect(s.endedAt == nil && !s.holds())
        let offset = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                       Self.wake("x", at: "2026-11-20T00:05:00Z"), Self.ended(at: "2026-11-20T01:10:00+01:00")])
        #expect(offset.endedAt == nil, "only UTC times are read; an offset one fails open")
        let garbage = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                        Self.wake("x", at: "2026-11-20T00:05:00Z"), Self.ended(at: "2026-11-20T00:06:00garbageZ")])
        #expect(garbage.endedAt == nil)
        let leap = try await settle([Self.human("go", at: "2026-02-28T00:00:00Z"), Self.launch("a", at: "2026-02-28T00:00:01Z"),
                                     Self.wake("x", at: "2026-02-28T00:05:00Z"), Self.ended(at: "2026-02-29T00:06:00Z")])
        #expect(leap.endedAt == nil, "2026 has no February 29")
        let unknown = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                        Self.wake("x", at: "2026-11-20T00:05:00Z"),
                                        #"{"type":"user","turnOrigin":"scheduled","message":{"role":"user","content":"tick"},"uuid":"u","timestamp":"2026-11-20T00:05:30Z"}"#,
                                        Self.ended(at: "2026-11-20T00:06:00Z")])
        #expect(unknown.origin == .none)
        let interrupted = try await settle([Self.human("go", at: "2026-11-20T00:00:00Z"), Self.launch("a", at: "2026-11-20T00:00:01Z"),
                                            Self.wake("x", at: "2026-11-20T00:05:00Z"),
                                            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"i"}"#,
                                            Self.ended(at: "2026-11-20T00:06:00Z")])
        #expect(interrupted.origin == .none)
    }
}
