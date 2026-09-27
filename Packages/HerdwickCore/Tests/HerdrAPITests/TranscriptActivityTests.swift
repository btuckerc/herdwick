import Foundation
import Testing
import HerdrTestSupport
@testable import HerdrAPI

@Suite struct TranscriptActivityTests {
    private static func date(_ string: String) -> Date { TranscriptMessage.date(string)! }

    private static func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Screens/\(name)")
        return Array(try Data(contentsOf: url))
    }

    private static func omp(_ role: String, _ content: String, at time: String) -> String {
        let body: [String: Any] = role == "toolCall"
            ? ["role": "assistant", "content": [["type": "toolCall", "id": "c", "name": "bash", "arguments": [:] as [String: Any]]]]
            : ["role": role, "content": content, "toolCallId": "c"]
        let record: [String: Any] = ["type": "message", "id": UUID().uuidString, "timestamp": time, "message": body]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    /// Reads the file the way the app does: one batch per round until nothing more is waiting.
    private static func refresh(_ activity: inout TranscriptActivity, client: HerdrClient) async throws {
        var rounds = 0
        repeat {
            let chunk = try #require(try await client.readChunks(["a": (activity.path, activity.nextRead)])["a"])
            activity.absorb(size: chunk.size, from: chunk.from, bytes: chunk.bytes)
            rounds += 1
        } while activity.needsMore && rounds < 20
    }

    @Test func recordedCodexAndClaudeMessagesCarryTheirTimes() throws {
        // Codex's last message is the user's; its time is on the outer record.
        let (codex, _) = TranscriptActivity.scan(try Self.fixture("codex-transcript.jsonl"), format: .codex, startsMidFile: false, flush: true)
        #expect(codex == Self.date("2026-09-25T05:23:37.128Z"))
        // Up to Claude's last user prompt; later lines are tool results and thinking-free replies.
        let claude = try Self.fixture("claude-transcript.jsonl")
        let lines = claude.split(separator: 0x0A, omittingEmptySubsequences: false)
        let upToPrompt = Array(lines.prefix(46).joined(separator: [0x0A])) + [0x0A]
        #expect(TranscriptActivity.scan(upToPrompt, format: .claude, startsMidFile: false, flush: true).0 == Self.date("2026-09-25T05:23:02.110Z"))
        #expect(TranscriptActivity.scan(claude, format: .claude, startsMidFile: false, flush: true).0 == Self.date("2026-09-25T05:25:07.971Z"))
    }

    @Test func toolWorkIsNotAMessage() {
        let lines = Self.omp("user", "run it", at: "2026-09-25T10:00:00Z")
            + Self.omp("toolCall", "", at: "2026-09-25T10:01:00Z")
            + Self.omp("toolResult", "output", at: "2026-09-25T10:02:00Z")
            + Self.omp("assistant", "  \n", at: "2026-09-25T10:03:00Z")
        #expect(TranscriptActivity.scan(Array(lines.utf8), format: .omp, startsMidFile: false, flush: true).0 == Self.date("2026-09-25T10:00:00Z"))
    }

    @Test func followsAppendsAndLooksBackPastLongToolRuns() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString) it's.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HerdrClient(runner: LocalProcessRunner())
        var activity = TranscriptActivity(path: url.path, format: .omp)

        // No file yet: nothing known, and nothing is read on the next round either.
        try await Self.refresh(&activity, client: client)
        #expect(activity.lastMessageAt == nil)

        // The only message sits more than two read windows before the end.
        var text = Self.omp("assistant", "done", at: "2026-09-25T09:00:00Z")
        let filler = String(repeating: "x", count: 4000)
        while text.utf8.count < TranscriptActivity.window * 2 + 10_000 {
            text += Self.omp("toolResult", filler, at: "2026-09-25T09:30:00Z")
        }
        try Data(text.utf8).write(to: url)
        try await Self.refresh(&activity, client: client)
        #expect(activity.lastMessageAt == Self.date("2026-09-25T09:00:00Z"))
        #expect(activity.offset == text.utf8.count)

        // More tool work keeps the time; a new prompt moves it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Self.omp("toolResult", "more", at: "2026-09-25T11:00:00Z").utf8))
        try await Self.refresh(&activity, client: client)
        #expect(activity.lastMessageAt == Self.date("2026-09-25T09:00:00Z"))
        try handle.write(contentsOf: Data(Self.omp("user", "next", at: "2026-09-25T12:00:00Z").utf8))
        try handle.close()
        try await Self.refresh(&activity, client: client)
        #expect(activity.lastMessageAt == Self.date("2026-09-25T12:00:00Z"))

        // A replaced, shorter file is a different history.
        try Data(Self.omp("user", "fresh", at: "2026-09-24T08:00:00Z").utf8).write(to: url)
        try await Self.refresh(&activity, client: client)
        try await Self.refresh(&activity, client: client)
        #expect(activity.lastMessageAt == Self.date("2026-09-24T08:00:00Z"))
    }

    @Test func stepsPastALineLongerThanARead() {
        var activity = TranscriptActivity(path: "/t", format: .omp)
        let first = Self.omp("user", "hi", at: "2026-09-25T10:00:00Z")
        activity.absorb(size: first.utf8.count, from: 0, bytes: Array(first.utf8))
        // A single record larger than a whole forward read, then a reply.
        let huge = Self.omp("toolResult", String(repeating: "y", count: TranscriptActivity.forwardLimit + 10), at: "2026-09-25T10:01:00Z")
        let reply = Self.omp("assistant", "ok", at: "2026-09-25T10:02:00Z")
        let file = Array((first + huge + reply).utf8)
        var rounds = 0
        while rounds < 10 {
            let read = activity.nextRead
            let from = read.from!
            activity.absorb(size: file.count, from: from, bytes: Array(file[from..<min(file.count, from + read.limit)]))
            rounds += 1
            if !activity.needsMore { break }
        }
        #expect(activity.lastMessageAt == Self.date("2026-09-25T10:02:00Z"))
        #expect(activity.offset == file.count)
    }
}
