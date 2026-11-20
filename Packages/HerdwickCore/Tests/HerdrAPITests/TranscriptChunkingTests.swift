import Foundation
import HerdrAPI
import Testing

/// A followed transcript arrives in arbitrary pieces; decoding them one by one must give the
/// same records and resume offset as reading the whole file at once.
@Suite("Transcript chunking")
struct TranscriptChunkingTests {
    private func fixture(_ name: String) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Screens"))
        return Array(try Data(contentsOf: url))
    }

    private func decode(_ bytes: [UInt8], format: TranscriptFormat, chunks: [Int]) -> (records: [TranscriptRecord], consumed: Int) {
        var reader = TranscriptReader(format: format)
        var records: [TranscriptRecord] = []
        var offset = 0
        var partition = 0
        while offset < bytes.count {
            let end = min(offset + chunks[partition % chunks.count], bytes.count)
            records += reader.appendRecords(Array(bytes[offset..<end]))
            offset = end
            partition += 1
        }
        return (records, reader.consumedBytes)
    }

    @Test(arguments: [
        ("claude-transcript", TranscriptFormat.claude),
        ("claude-tasks", TranscriptFormat.claude),
        ("codex-transcript", TranscriptFormat.codex),
        ("omp-irc-incoming", TranscriptFormat.omp)
    ])
    func everyPartitionMatchesSingleShot(name: String, format: TranscriptFormat) throws {
        let bytes = try fixture(name)
        var reader = TranscriptReader(format: format)
        let expected = reader.appendRecords(bytes)
        for chunks in [[1], [2, 3, 5, 8, 13], [17, 1, 4096]] {
            let actual = decode(bytes, format: format, chunks: chunks)
            #expect(actual.records == expected)
            #expect(actual.consumed == reader.consumedBytes)
        }
    }

    @Test func multibyteCharactersSplitAcrossChunks() {
        let line = #"{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"café 🐑"}]}}"#
        let bytes = Array((line + "\n").utf8)
        var reader = TranscriptReader()
        let expected = reader.appendRecords(bytes)
        let actual = decode(bytes, format: .omp, chunks: [1])
        #expect(actual.records == expected)
        #expect(actual.consumed == bytes.count)
    }
}
