import Foundation

internal enum ClaudeTranscript {
    static func entries(_ line: ArraySlice<UInt8>, parsed: [String: Any]? = nil) -> [TranscriptEntry] {
        guard let r = parsed ?? (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let type = r["type"] as? String else { return [.malformed(String(decoding: line.prefix(2048), as: UTF8.self))] }
        if type == "ai-title", let s = r["aiTitle"] as? String { return [.title(s)] }
        if type == "summary", let s = r["summary"] as? String { return [.title(s)] }
        if type == "system" {
            if r["subtype"] as? String == "compact_boundary" {
                // "Context compacted · 301k → 20k tokens": what the agent kept of what it had.
                let meta = r["compactMetadata"] as? [String: Any]
                let before = (meta?["preTokens"] as? NSNumber)?.intValue, after = (meta?["postTokens"] as? NSNumber)?.intValue
                let counts = before.map { b in after.map { "\(tokens(b)) → \(tokens($0)) tokens" } ?? "\(tokens(b)) tokens" }
                return [.compaction(summary: counts.map { "Context compacted · \($0)" } ?? r["content"] as? String ?? "")]
            }
            if r["level"] as? String == "error" || r["subtype"] as? String == "api_error" { return [.notice(r["content"] as? String ?? "")] }
            if r["subtype"] as? String == "turn_duration" { return [.turnEnded(at: TranscriptMessage.date(r["timestamp"]))] }
            return [.metadata(type: type)]
        }
        if type == "attachment", let a = r["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
           let prompt = a["prompt"] as? String {
            // Delivered mid-turn: the turn carries on, so only the job settles.
            if a["commandMode"] as? String == "task-notification", let entries = taskNotification(prompt) { return entries }
            // A message the person typed while the agent worked: theirs, where it landed.
            if a["commandMode"] as? String == "prompt", !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [.message(.init(id: ConversationItem.queuedPrefix + (r["uuid"] as? String ?? ""), role: .user, text: prompt,
                                       timestamp: TranscriptMessage.date(r["timestamp"])))]
            }
        }
        // Claude Code's copies of each API request (two per call in 2.1) are bookkeeping, not
        // conversation: as rows they were unopenable lines inside every run of steps.
        if type.hasPrefix("api-request") { return [.metadata(type: type)] }
        if type != "assistant" && type != "user" { return r["message"] != nil ? [.unknown(type: type, raw: raw(line))] : [.metadata(type: type)] }
        let id = r["uuid"] as? String ?? ""
        guard let message = r["message"] as? [String: Any] else { return [.metadata(type: type)] }
        if type == "assistant" {
            let blocks = message["content"] as? [[String: Any]] ?? []
            var text = [String](), thinking = [String](), calls = [TranscriptMessage.ToolCall](), images = [TranscriptImage]()
            for b in blocks { switch b["type"] as? String {
            case "text": if let s = b["text"] as? String { text.append(s) }
            case "thinking": if let s = b["thinking"] as? String { thinking.append(s) }
            case "tool_use": if let bid = b["id"] as? String, let name = b["name"] as? String { calls.append(.init(id: bid, name: name, arguments: json(b["input"]))) }
            case "image": if let image = TranscriptImage.claude(b) { images.append(image) }
            default: break }
            }
            let timestamp = TranscriptMessage.date(r["timestamp"])
            let reply = TranscriptEntry.message(.init(id: id, role: .assistant, text: text.joined(separator: "\n\n"), thinking: thinking.joined(separator: "\n\n"), images: images, toolCalls: calls, timestamp: timestamp))
            // Each content block is its own line, all stamped with the reply's stop reason.
            if let stop = message["stop_reason"] as? String, stop != "tool_use" { return [reply, .turnEnded(at: timestamp)] }
            return [reply]
        }
        // The person's own words stay theirs, even quoting a notification.
        let human = r["turnOrigin"] as? String == "human"
        if let content = message["content"] as? String {
            if !human, let entries = taskNotification(content) { return entries }
            if r["isMeta"] as? Bool == true || isHarness(content) { return [.metadata(type: type)] }
            if content.hasPrefix("[Request interrupted by user") { return [.notice(content)] }
            return [.message(.init(id: id, role: .user, text: content, timestamp: TranscriptMessage.date(r["timestamp"])))]
        }
        var result: [TranscriptEntry] = [], texts = [String](), images = [TranscriptImage]()
        for b in message["content"] as? [[String: Any]] ?? [] { switch b["type"] as? String {
        case "text": if let s = b["text"] as? String { texts.append(s) }
        case "image": if let image = TranscriptImage.claude(b) { images.append(image) }
        case "tool_result":
            guard let call = b["tool_use_id"] as? String else { continue }
            let output = contentText(b["content"]), error = b["is_error"] as? Bool ?? false
            let shown = (b["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "image" ? TranscriptImage.claude($0) : nil }
            result.append(.message(.init(id: id, role: .toolResult, text: output, images: shown, toolCallId: call, isError: error, details: json(r["toolUseResult"] ?? b))))
        default: break }
        }
        let typed = texts.joined(separator: "\n\n")
        if !human, result.isEmpty, images.isEmpty, let entries = taskNotification(typed) { return entries }
        if r["isMeta"] as? Bool != true && !isHarness(typed) {
            if typed.hasPrefix("[Request interrupted by user") { result.insert(.notice(typed), at: 0) }
            else if !texts.isEmpty || !images.isEmpty { result.insert(.message(.init(id: id, role: .user, text: typed, images: images, timestamp: TranscriptMessage.date(r["timestamp"]))), at: 0) }
        }
        return result.isEmpty ? [.metadata(type: type)] : result
    }
    /// Claude Code's word that a background task ended: `<task-notification>` with the task's
    /// id, the call that started it, its output file, `<status>` (`completed`, `failed`,
    /// `stopped`), a one-line `<summary>` ("Background command \"…\" completed (exit code 0)")
    /// and, for an MCP task, its `<result>`. A Monitor's events come the same way without a
    /// status and end nothing: each is a notice.
    static func taskNotification(_ text: String) -> [TranscriptEntry]? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("<task-notification>") else { return nil }
        // One delivery can carry several.
        var entries: [TranscriptEntry] = []
        for block in body.components(separatedBy: "<task-notification>").dropFirst() {
            let block = block.components(separatedBy: "</task-notification>").first ?? block
            func tag(_ name: String) -> String? {
                guard let open = block.range(of: "<\(name)>"), let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex) else { return nil }
                return unescape(String(block[open.upperBound..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let id = tag("task-id"), !id.isEmpty else { continue }
            let summary = tag("summary") ?? ""
            guard let status = tag("status") else {
                entries.append(.notice([summary.isEmpty ? id : summary, tag("event")].compactMap { $0 }.joined(separator: "\n")))
                continue
            }
            var label = summary.isEmpty ? id : summary
            if let match = summary.firstMatch(of: #/^Background command "(.*)" (?:completed|failed)/#) { label = String(match.1) }
            let exit = summary.firstMatch(of: #/exit code (-?\d+)/#).flatMap { Int($0.1) }
            entries.append(.jobsFinished([FinishedJob(id: id, label: label, output: tag("result") ?? "", failed: status != "completed" || (exit ?? 0) != 0,
                                                      outputFile: tag("output-file"), callID: tag("tool-use-id"))]))
        }
        return entries.isEmpty ? nil : entries
    }
    private static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func tokens(_ n: Int) -> String { n >= 1000 ? "\((n + 500) / 1000)k" : "\(n)" }
    private static func isHarness(_ s: String) -> Bool { ["<command-name>", "<command-message>", "<local-command-stdout>", "<system-reminder>", "Caveat:"].contains(where: s.hasPrefix) }
    private static func contentText(_ value: Any?) -> String { if let s = value as? String { return s }; return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
    private static func json(_ value: Any?) -> String? { guard let v = value, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return nil }; return String(decoding: d, as: UTF8.self) }
    private static func raw(_ line: ArraySlice<UInt8>) -> String { String(decoding: line.prefix(2048), as: UTF8.self) }
}
