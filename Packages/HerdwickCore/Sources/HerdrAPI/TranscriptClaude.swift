import Foundation

internal enum ClaudeTranscript {
    static func entries(_ line: ArraySlice<UInt8>) -> [TranscriptEntry] {
        guard let r = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let type = r["type"] as? String else { return [.malformed(String(decoding: line.prefix(2048), as: UTF8.self))] }
        if type == "ai-title", let s = r["aiTitle"] as? String { return [.title(s)] }
        if type == "summary", let s = r["summary"] as? String { return [.title(s)] }
        if type == "system" {
            if r["subtype"] as? String == "compact_boundary" { return [.compaction(summary: r["content"] as? String ?? "")] }
            if r["level"] as? String == "error" || r["subtype"] as? String == "api_error" { return [.notice(r["content"] as? String ?? "")] }
            return [.metadata(type: type)]
        }
        if type != "assistant" && type != "user" { return r["message"] != nil ? [.unknown(type: type, raw: raw(line))] : [.metadata(type: type)] }
        let id = r["uuid"] as? String ?? ""
        guard let message = r["message"] as? [String: Any] else { return [.metadata(type: type)] }
        if type == "assistant" {
            let blocks = message["content"] as? [[String: Any]] ?? []
            var text = [String](), thinking = [String](), calls = [TranscriptMessage.ToolCall](), images = 0
            for b in blocks { switch b["type"] as? String {
            case "text": if let s = b["text"] as? String { text.append(s) }
            case "thinking": if let s = b["thinking"] as? String { thinking.append(s) }
            case "tool_use": if let bid = b["id"] as? String, let name = b["name"] as? String { calls.append(.init(id: bid, name: name, arguments: json(b["input"]))) }
            case "image": images += 1
            default: break }
            }
            return [.message(.init(id: id, role: .assistant, text: text.joined(separator: "\n\n"), thinking: thinking.joined(separator: "\n\n"), imageCount: images, toolCalls: calls, timestamp: TranscriptMessage.date(r["timestamp"])))]
        }
        if let content = message["content"] as? String {
            if r["isMeta"] as? Bool == true || isHarness(content) { return [.metadata(type: type)] }
            if content.hasPrefix("[Request interrupted by user") { return [.notice(content)] }
            return [.message(.init(id: id, role: .user, text: content))]
        }
        var result: [TranscriptEntry] = [], texts = [String](), images = 0
        for b in message["content"] as? [[String: Any]] ?? [] { switch b["type"] as? String {
        case "text": if let s = b["text"] as? String { texts.append(s) }
        case "image": images += 1
        case "tool_result":
            guard let call = b["tool_use_id"] as? String else { continue }
            let output = contentText(b["content"]), error = b["is_error"] as? Bool ?? false
            result.append(.message(.init(id: id, role: .toolResult, text: output, imageCount: 0, toolCallId: call, isError: error, details: json(r["toolUseResult"] ?? b))))
        default: break }
        }
        let typed = texts.joined(separator: "\n\n")
        if typed.hasPrefix("[Request interrupted by user") { result.insert(.notice(typed), at: 0) }
        else if !texts.isEmpty || images > 0 { result.insert(.message(.init(id: id, role: .user, text: typed, imageCount: images)), at: 0) }
        return result.isEmpty ? [.metadata(type: type)] : result
    }
    private static func isHarness(_ s: String) -> Bool { ["<command-name>", "<command-message>", "<local-command-stdout>", "<system-reminder>", "Caveat:"].contains(where: s.hasPrefix) }
    private static func contentText(_ value: Any?) -> String { if let s = value as? String { return s }; return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
    private static func json(_ value: Any?) -> String? { guard let v = value, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return nil }; return String(decoding: d, as: UTF8.self) }
    private static func raw(_ line: ArraySlice<UInt8>) -> String { String(decoding: line.prefix(2048), as: UTF8.self) }
}
