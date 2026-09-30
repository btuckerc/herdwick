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
}
