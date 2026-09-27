import Foundation

internal enum ClaudeTranscript {
    static func entries(_ line: ArraySlice<UInt8>, parsed: [String: Any]? = nil) -> [TranscriptEntry] {
        guard let r = parsed ?? (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let type = r["type"] as? String else { return [.malformed(String(decoding: line.prefix(2048), as: UTF8.self))] }
        if type == "ai-title", let s = r["aiTitle"] as? String { return [.title(s)] }
        if type == "summary", let s = r["summary"] as? String { return [.title(s)] }
        if type == "system" {
            if r["subtype"] as? String == "compact_boundary" { return [.compaction(summary: r["content"] as? String ?? "")] }
            if r["level"] as? String == "error" || r["subtype"] as? String == "api_error" { return [.notice(r["content"] as? String ?? "")] }
            if r["subtype"] as? String == "turn_duration" { return [.turnEnded(at: TranscriptMessage.date(r["timestamp"]))] }
            return [.metadata(type: type)]
        }
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
        if let content = message["content"] as? String {
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
        if typed.hasPrefix("[Request interrupted by user") { result.insert(.notice(typed), at: 0) }
        else if !texts.isEmpty || !images.isEmpty { result.insert(.message(.init(id: id, role: .user, text: typed, images: images, timestamp: TranscriptMessage.date(r["timestamp"]))), at: 0) }
        return result.isEmpty ? [.metadata(type: type)] : result
    }
    private static func isHarness(_ s: String) -> Bool { ["<command-name>", "<command-message>", "<local-command-stdout>", "<system-reminder>", "Caveat:"].contains(where: s.hasPrefix) }
    private static func contentText(_ value: Any?) -> String { if let s = value as? String { return s }; return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
    private static func json(_ value: Any?) -> String? { guard let v = value, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return nil }; return String(decoding: d, as: UTF8.self) }
    private static func raw(_ line: ArraySlice<UInt8>) -> String { String(decoding: line.prefix(2048), as: UTF8.self) }
}
