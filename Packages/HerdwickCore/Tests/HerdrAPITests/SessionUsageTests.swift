import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

/// The host-side totals must agree with what the app decodes when the whole file is loaded.
@Suite struct SessionUsageTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    private func check(_ lines: [String], format: TranscriptFormat, expect: (input: Int, output: Int, cost: Double?)) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage \(UUID().uuidString) it's.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = TranscriptReader(format: format)
        var conversation = Conversation()
        conversation.apply(records: reader.appendRecords(Array((lines.joined(separator: "\n") + "\n").utf8)))
        let loaded = try #require(conversation.usage)
        let whole = try #require(try await client.sessionUsage(path: url.path, format: format))
        #expect(whole.inputTokens == expect.input && whole.outputTokens == expect.output)
        #expect(loaded.inputTokens == whole.inputTokens && loaded.outputTokens == whole.outputTokens)
        #expect(whole.cost.map { ($0 * 1e6).rounded() } == expect.cost.map { ($0 * 1e6).rounded() })
        #expect(loaded.cost.map { ($0 * 1e6).rounded() } == whole.cost.map { ($0 * 1e6).rounded() })
    }

    @Test func ompSumsAssistantUsageAndCost() async throws {
        try await check([
            #"{"type":"message","id":"u1","message":{"role":"user","content":"what does \"usage\":{\"input\":999} mean"}}"#,
            #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"x"}],"model":"m","usage":{"input":4,"output":906,"cacheRead":69884,"cacheWrite":1167,"totalTokens":71961,"cost":{"input":0.000016,"output":0.01812,"cacheRead":0.0139768,"cacheWrite":0.009336,"total":0.0414488},"cttl":{"ephemeral1h":1167}},"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"a2","message":{"role":"assistant","content":[],"usage":{"input":2,"output":10,"cacheRead":0,"cacheWrite":5,"totalTokens":17,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":1.5e-05}}}}"#,
        ], format: .omp, expect: (71_062, 916, 0.0414638))
    }

    @Test func claudeCountsEachAPIMessageOnceAndSkipsToolResults() async throws {
        try await check([
            #"{"type":"assistant","uuid":"1","message":{"model":"claude","id":"msg_A","type":"message","role":"assistant","content":[{"type":"thinking"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":100},"output_tokens":7,"service_tier":"standard"}}}"#,
            #"{"type":"assistant","uuid":"2","message":{"model":"claude","id":"msg_A","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":100},"output_tokens":50,"service_tier":"standard"}}}"#,
            #"{"type":"user","uuid":"3","message":{"role":"user","content":[{"type":"tool_result","content":"done"}]},"toolUseResult":{"totalTokens":9,"usage":{"input_tokens":5000,"output_tokens":5000}}}"#,
            #"{"type":"assistant","uuid":"4","message":{"model":"claude","id":"msg_B","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":2103,"output_tokens":4}}}"#,
        ], format: .claude, expect: (4_207, 54, nil))
    }

    @Test func codexTakesTheLatestCumulativeTotal() async throws {
        func count(_ last: (Int, Int), _ total: (Int, Int)) -> String {
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":0,"output_tokens":\#(total.1),"reasoning_output_tokens":0,"total_tokens":0},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":0,"output_tokens":\#(last.1),"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":1}}}"#
        }
        try await check([count((100, 10), (100, 10)), count((100, 10), (100, 10)), count((250, 30), (350, 40))],
                        format: .codex, expect: (350, 40, nil))
    }

    @Test func missingOrUsagelessTranscriptIsNil() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl").path
        #expect(try await client.sessionUsage(path: missing, format: .omp) == nil)
    }
}
