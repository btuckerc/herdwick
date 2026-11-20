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
        #expect(activity.preview == "\(String(repeating: "word ", count: 28).dropLast())…")
        #expect(activity.previewAt == TranscriptMessage.date("2026-09-27T10:00:00Z"))
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any])
        old.removeValue(forKey: "preview"); old.removeValue(forKey: "previewAt")
        let restored = try JSONDecoder().decode(TranscriptActivity.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.preview == nil)
        #expect(restored.lastTurnAt == activity.lastTurnAt)
    }

    @Test func previewDropsMarkdownMarkersAndJoinsListItems() {
        let text = "## Done\nStaging is deployed.\n\n- Both migrations applied;\n  * health checks passed\n2. Production untouched\n> quoted\n#hashtag stays"
        #expect(TranscriptActivity.previewLine(text)
            == "Done Staging is deployed. · Both migrations applied; · health checks passed · Production untouched quoted #hashtag stays")
        #expect(TranscriptActivity.previewLine("- a\n- b") == "a · b", "a leading item takes no separator")
        #expect(TranscriptActivity.previewLine("**bold** start") == "bold start", "emphasis isn't a list marker")
        #expect(TranscriptActivity.previewLine("- **Move:** ran `bun test`, 2 * 3") == "Move: ran bun test, 2 * 3")
        #expect(TranscriptActivity.previewLine(String(repeating: "- item\n", count: 40)).count <= 140)
    }

    @Test func longPreviewEndsAtAWordWithEllipsis() {
        let text = "The retry test was flaky because the backoff timer read the wall clock; switched it to a monotonic clock and reran it fifty times."
        #expect(TranscriptActivity.previewLine(text, limit: 40) == "The retry test was flaky because the…")
        #expect(TranscriptActivity.previewLine("one two three", limit: 13) == "one two three", "an exact fit isn't cut")
        #expect(TranscriptActivity.previewLine("- first item\n- second item", limit: 14) == "first item…", "no dangling separator")
    }

    @Test func verdictStopsBeforeTheFirstListItem() {
        #expect(TranscriptActivity.verdict("No blocking findings in PR #412. · Move: the old key") == "No blocking findings in PR #412.")
        #expect(TranscriptActivity.verdict("Summary · Tests pass") == "Summary · Tests pass", "a heading isn't a verdict")
        #expect(TranscriptActivity.verdict("Fixed. The test now runs on the fake clock.") == "Fixed. The test now runs on the fake clock.")
    }

    @Test func cautionIsOnlyAClosingWarningCallout() {
        let review = "No blocking findings in PR #412.\n\n- **Move:** the key is removed.\n\n**Before deploying:** apply 0042 first; existing rows need team IDs."
        #expect(TranscriptActivity.caution(review) == "Before deploying: apply 0042 first; existing rows need team IDs.")
        #expect(TranscriptActivity.caution("Done.\n\n**Warning:** the cache is cold.\n\n") == "Warning: the cache is cold.", "trailing blank lines don't hide it")
        #expect(TranscriptActivity.caution("Done.\n\n**Before deploying:** apply 0042 first; existing rows need team IDs. I left the working tree unchanged.")
                == "Before deploying: apply 0042 first; existing rows need team IDs.", "only its first sentence")
        #expect(TranscriptActivity.caution("Done.\n\n**Warning:** pin v1.2 first. then redeploy.") == "Warning: pin v1.2 first. then redeploy.",
                "a sentence ends only before a capital")
        #expect(TranscriptActivity.caution("**Before deploying:** apply 0042.\n\nThen all is well.") == nil, "only the last paragraph counts")
        #expect(TranscriptActivity.caution("Done.\n\n**Next:** open a PR.") == nil, "a callout that isn't a warning")
        #expect(TranscriptActivity.caution("Done.\n\nWarning: plain text.") == nil, "the label must be bold")
    }

    @Test func openingSplitsTheVerdictFromWhatFollows() {
        let listed = TranscriptActivity.opening("No blocking findings in PR #412. · Move: the old key · Access: kept")
        #expect(listed.verdict == "No blocking findings in PR #412." && listed.rest == "Move: the old key\nAccess: kept")
        let prose = TranscriptActivity.opening("Fixed. The test now runs on the fake clock. 500 runs, no failures.")
        #expect(prose.verdict == "Fixed. The test now runs on the fake clock." && prose.rest == "500 runs, no failures.",
                "an acknowledgement alone isn't the verdict")
        let mid = TranscriptActivity.opening("Done. The v2 names hold · Move: none")
        #expect(mid.verdict == "Done. The v2 names hold" && mid.rest == "Move: none")
        let lone = TranscriptActivity.opening("All set. Every endpoint pages")
        #expect(lone.verdict == "All set. Every endpoint pages" && lone.rest == nil)
        let full = TranscriptActivity.opening("Staging is two migrations behind. Both are safe.")
        #expect(full.verdict == "Staging is two migrations behind." && full.rest == "Both are safe.")
        #expect(TranscriptActivity.opening("Summary · Tests pass").verdict == "Summary · Tests pass", "a heading isn't a verdict")
        #expect(TranscriptActivity.opening("See e.g. the docs").rest == nil, "no capital after the period: one sentence")
        #expect(TranscriptActivity.opening("Summary · Tests pass. All green").rest == nil, "sentences inside a list item don't split")
    }
}
