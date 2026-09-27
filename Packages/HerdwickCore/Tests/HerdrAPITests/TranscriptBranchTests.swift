import Foundation
import Testing
@testable import HerdrAPI

@Suite struct TranscriptBranchTests {
    private func bytes(_ records: [[String: Any]]) throws -> [UInt8] {
        try records.flatMap { Array(try JSONSerialization.data(withJSONObject: $0)) + [10] }
    }
    private func message(_ id: String, _ parent: String?, _ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "id": id, "parentId": parent as Any? ?? NSNull(),
         "message": ["role": role, "content": text], "timestamp": "2026-09-27T10:00:00Z"]
    }

    @Test func branchSwitchRemovesAbandonedAskAndUsage() throws {
        var reader = TranscriptReader(), conversation = Conversation()
        let root = message("root", nil, "user", "Choose a branch")
        var abandoned = message("left", "root", "assistant", "Left")
        abandoned["message"] = ["role": "assistant", "model": "left-model", "usage": ["input": 12, "output": 3, "cost": ["total": 0.2]], "content": [["type": "toolCall", "id": "ask", "name": "ask", "arguments": ["questions": [["question": "Continue?", "options": [["label": "Yes"]]]]]]]]
        conversation.apply(records: reader.appendRecords(try bytes([root, abandoned])))
        #expect(conversation.pendingAsk != nil)
        #expect(conversation.usage?.inputTokens == 12)
        var right = message("right", "root", "assistant", "Right")
        right["message"] = ["role": "assistant", "content": "Right", "model": "right-model", "usage": ["input": 4, "cacheRead": 6, "output": 2]]
        let encoded = try bytes([right])
        conversation.apply(records: reader.appendRecords(Array(encoded.prefix(20))))
        #expect(conversation.pendingAsk != nil)
        conversation.apply(records: reader.appendRecords(Array(encoded.dropFirst(20))))
        #expect(conversation.pendingAsk == nil)
        #expect(conversation.items.map(\.id) == ["root", "right"])
        #expect(conversation.modelID == "right-model")
        #expect(conversation.usage?.inputTokens == 10)
        #expect(conversation.usage?.cost == nil)
        conversation.apply(records: reader.appendRecords(encoded))
        #expect(conversation.usage?.outputTokens == 2)
        #expect(conversation.items.map(\.id) == ["root", "right"])
    }

    @Test func parentlessRecordsStayLinear() throws {
        var reader = TranscriptReader(), conversation = Conversation()
        conversation.apply(records: reader.appendRecords(try bytes([
            message("ask", nil, "user", "Review it"),
            message("thought", nil, "assistant", "Checking"),
            message("final", nil, "assistant", "Done"),
        ])))
        #expect(conversation.items.map(\.id) == ["ask", "thought", "final"])
    }

    @Test func parentlessRecordAfterTreeStartsNewRoot() throws {
        var reader = TranscriptReader(), conversation = Conversation()
        conversation.apply(records: reader.appendRecords(try bytes([
            message("root", nil, "user", "First"),
            message("old", "root", "assistant", "Old"),
            message("newRoot", nil, "user", "Again"),
        ])))
        #expect(conversation.items.map(\.id) == ["newRoot"])
    }

    @Test func metadataDoesNotChooseLeafAndLinearAppendMatchesLegacy() throws {
        let log = try bytes([
            ["type": "thinking_level_change", "id": "thinking", "parentId": NSNull(), "thinkingLevel": "high"],
            message("user", "thinking", "user", "Hello"),
            ["type": "custom", "id": "meta", "parentId": "user"],
            message("reply", "meta", "assistant", "Hi"),
            ["type": "title_change", "id": "title", "parentId": "user", "title": "Greeting"]
        ])
        var recordsReader = TranscriptReader(), legacyReader = TranscriptReader()
        var conversation = Conversation(), legacy = Conversation()
        for line in log.split(separator: 10) {
            conversation.apply(records: recordsReader.appendRecords(Array(line) + [10]))
            legacy.apply(legacyReader.append(Array(line) + [10]))
        }
        #expect(conversation.items == legacy.items)
        #expect(conversation.activeLeafID == "reply")
        #expect(conversation.thinkingLevel == "high")
        #expect(!conversation.hasIncompletePrefix)
    }

    @Test func missingAncestorRetainsIncompletePrefixAndKnownBranchSwitches() throws {
        var reader = TranscriptReader(), conversation = Conversation()
        conversation.apply(records: reader.appendRecords(try bytes([
            message("prefix", "outside", "user", "Loaded tail"),
            message("old", "prefix", "assistant", "Old branch"),
            message("new", "prefix", "assistant", "New branch")
        ])))
        #expect(conversation.hasIncompletePrefix)
        #expect(conversation.items.map(\.id) == ["prefix", "new"])
    }

    @Test func planReviewRequiresLastCallSuccessAndNoLaterUser() throws {
        var reader = TranscriptReader(), conversation = Conversation()
        var call = message("call", nil, "assistant", "")
        call["message"] = ["role": "assistant", "content": [["type": "toolCall", "id": "propose", "name": "write", "arguments": ["path": "xd://propose", "content": "my-plan"]]]]
        var result = message("result", "call", "toolResult", "Plan ready for review.")
        result["message"] = ["role": "toolResult", "toolCallId": "propose", "content": "Plan ready for review."]
        conversation.apply(records: reader.appendRecords(try bytes([call, result])))
        #expect(conversation.pendingPlanReview == "my-plan")
        conversation.apply(records: reader.appendRecords(try bytes([message("user", "result", "user", "Revise it")])))
        #expect(conversation.pendingPlanReview == nil)
        conversation.apply(records: reader.appendRecords(try bytes([message("branch", "call", "assistant", "Different path")])))
        #expect(conversation.pendingPlanReview == nil)
    }

    @Test func claudeUsageDeduplicatesAPIMessageWithoutApplyingParentUuid() throws {
        var reader = TranscriptReader(format: .claude), conversation = Conversation()
        let log: [[String: Any]] = [1, 2].map { index in
            ["type": "assistant", "uuid": "block-\(index)", "parentUuid": "not-loaded", "message": ["id": "api-reply", "model": "claude", "usage": ["input_tokens": 10, "output_tokens": 4], "content": [["type": "text", "text": "Block \(index)"]]]]
        }
        conversation.apply(records: reader.appendRecords(try bytes(log)))
        #expect(conversation.items.map(\.id) == ["block-1", "block-2"])
        #expect(conversation.usage?.inputTokens == 10)
        #expect(conversation.usage?.outputTokens == 4)
        #expect(!conversation.hasIncompletePrefix)
    }

    @Test func codexCountsLoadedDeltasOnceNotLifetimeTotal() throws {
        var reader = TranscriptReader(format: .codex), conversation = Conversation()
        let count: [String: Any] = ["type": "event_msg", "payload": [
            "type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 10, "output_tokens": 3],
                "total_token_usage": ["input_tokens": 900, "output_tokens": 100]
            ]
        ]]
        conversation.apply(records: reader.appendRecords(try bytes([count, count])))
        #expect(conversation.usage?.inputTokens == 10)
        #expect(conversation.usage?.outputTokens == 3)
        #expect(conversation.usage?.cost == nil)
    }

    @Test func previewIsBoundedSingleLineAndOldStateDecodes() throws {
        var activity = TranscriptActivity(path: "/log", format: .omp)
        let log = try bytes([message("user", nil, "user", "hello\n world"), message("reply", "user", "assistant", String(repeating: "word\n", count: 50))])
        activity.absorb(size: log.count, from: 0, bytes: log)
        #expect(activity.preview == String(String(repeating: "word ", count: 28).prefix(140)))
        #expect(activity.previewAt == TranscriptMessage.date("2026-09-27T10:00:00Z"))
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any])
        old.removeValue(forKey: "preview"); old.removeValue(forKey: "previewAt")
        let restored = try JSONDecoder().decode(TranscriptActivity.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.preview == nil)
        #expect(restored.lastTurnAt == activity.lastTurnAt)
    }
}
