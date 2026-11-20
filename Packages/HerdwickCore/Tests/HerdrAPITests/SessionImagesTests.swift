import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

/// The host lists every tool image in the file without sending inline bytes, and a listed
/// inline image fetches exactly its own bytes.
@Suite struct SessionImagesTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("images \(UUID().uuidString) it's.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func b64(_ fill: UInt8) -> String { Data(repeating: fill, count: 300).base64EncodedString() }

    @Test func ompListsBlobsAndFetchesEachInlineImageByItsPlace() async throws {
        let blob = String(repeating: "a", count: 64)
        let url = try file([
            #"{"type":"message","id":"u","message":{"role":"user","content":[{"type":"image","data":"\#(b64(9))","mimeType":"image/png"}]}}"#,
            #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"x"},{"type":"image","data":"blob:sha256:\#(blob)","mimeType":"image/png"}]}}"#,
            #"{"type":"message","id":"r2","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"image","data":"\#(b64(1))","mimeType":"image/png"},{"type":"text","text":"ok"},{"type":"image","data":"\#(b64(2))","mimeType":"image/jpeg"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let images = try await client.transcriptToolImages(path: url.path, format: .omp)
        #expect(images.map(\.source) == [.blob(blob), .transcriptLine(3, ordinal: 0), .transcriptLine(3, ordinal: 1)])
        #expect(images.map(\.mimeType) == ["image/png", "image/png", "image/jpeg"])
        #expect(try await client.transcriptImage(path: url.path, line: 3, ordinal: 1) == Data(repeating: 2, count: 300))
        #expect(try await client.transcriptImage(path: url.path, line: 3, ordinal: 0) == Data(repeating: 1, count: 300))
    }

    @Test func claudeListsToolResultImagesOnly() async throws {
        let url = try file([
            #"{"type":"user","uuid":"1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64(9))"}}]}}"#,
            #"{"type":"user","uuid":"2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64(4))"}}]}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let images = try await client.transcriptToolImages(path: url.path, format: .claude)
        #expect(images.map(\.source) == [.transcriptLine(2, ordinal: 0)])
        #expect(try await client.transcriptImage(path: url.path, line: 2, ordinal: 0) == Data(repeating: 4, count: 300))
    }

    @Test func claudeListsSubagentImagesInTimeOrderEachOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgs \(UUID().uuidString)")
        let parent = dir.appendingPathComponent("s1.jsonl")
        let children = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func result(_ fill: UInt8, _ at: String) -> String {
            // Claude writes the record's time after its message, so after the image.
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64(fill))"}}]}]},"uuid":"\#(at)","timestamp":"\#(at)"}"#
        }
        try Data((result(1, "2026-11-20T01:00:00Z") + "\n" + result(3, "2026-11-20T04:00:00Z") + "\n").utf8).write(to: parent)
        // The child read the same screenshot the parent did at 1:00, and one of its own.
        try Data((result(2, "2026-11-20T02:00:00Z") + "\n" + result(1, "2026-11-20T03:00:00Z") + "\n").utf8)
            .write(to: children.appendingPathComponent("agent-abc.jsonl"))
        let images = try await client.transcriptToolImages(path: parent.path, format: .claude, subagents: true, names: ["abc": "Reviewer"])
        // Inline images are never merged by sampling: a re-read stays a separate image.
        #expect(images.map(\.at) == ["2026-11-20T01:00:00Z", "2026-11-20T02:00:00Z", "2026-11-20T03:00:00Z", "2026-11-20T04:00:00Z"])
        #expect(images.map(\.origin) == [nil, "Reviewer", "Reviewer", nil])
        let child = images[1]
        guard case .transcriptLine(let line, let ordinal) = child.source else { Issue.record("not a line"); return }
        #expect(try await client.transcriptImage(path: try #require(child.file), line: line, ordinal: ordinal) == Data(repeating: 2, count: 300))
        // Without subagents, only the parent's own.
        #expect(try await client.transcriptToolImages(path: parent.path, format: .claude).count == 2)
    }

    @Test func onlyIdenticalBlobsCollapse() {
        let a = TranscriptImage(source: .blob(String(repeating: "a", count: 64)), mimeType: nil, at: "1")
        let again = TranscriptImage(source: .blob(String(repeating: "a", count: 64)), mimeType: nil, at: "3")
        let inline = TranscriptImage(source: .base64("x"), mimeType: nil, at: "2")
        let inlineAgain = TranscriptImage(source: .base64("x"), mimeType: nil, at: "4")
        #expect(TranscriptImage.newestOfEach([a, inline, again, inlineAgain]).map(\.at) == ["2", "3", "4"])
    }

    @Test func aSmallInlineImageIsKept() async throws {
        let small = Data(repeating: 6, count: 60).base64EncodedString()
        let url = try file([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(small)"}}]}]},"uuid":"1","timestamp":"2026-11-20T01:00:00Z"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let images = try await client.transcriptToolImages(path: url.path, format: .claude, subagents: true)
        #expect(images.count == 1)
        #expect(images.first?.inlineData == Data(repeating: 6, count: 60))
    }
}
