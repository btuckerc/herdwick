import Foundation

/// Codex rollout files (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`), checked
/// against Codex 0.157: `response_item` carries messages, reasoning, `function_call` /
/// `custom_tool_call` and their outputs; `event_msg` carries errors; the rest is bookkeeping.
enum CodexTranscript {
    static func entries(_ line: ArraySlice<UInt8>) -> [TranscriptEntry] {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let type = record["type"] as? String else {
            return [.malformed(String(decoding: line.prefix(2048), as: UTF8.self))]
        }
        let payload = record["payload"] as? [String: Any] ?? [:]
        let id = payload["id"] as? String ?? ""
        switch type {
        case "response_item":
            switch payload["type"] as? String {
            case "message": return message(payload, id: id)
            case "reasoning": return reasoning(payload, id: id)
            case "function_call": return call(payload, id: id, arguments: normalized(payload["arguments"] as? String))
            case "custom_tool_call": return call(payload, id: id, arguments: json(["input": payload["input"] as? String ?? ""]))
            case "function_call_output", "custom_tool_call_output": return output(payload, id: id)
            case let other: return [.metadata(type: other ?? type)]
            }
        case "compacted":
            return [.compaction(summary: payload["message"] as? String ?? "")]
        case "event_msg":
            switch payload["type"] as? String {
            case "error":
                return [.notice(payload["message"] as? String ?? "Codex reported an error.")]
            case "task_complete":
                guard let error = payload["error"] as? [String: Any], let text = error["message"] as? String else { break }
                return [.notice(text)]
            default:
                break
            }
            return [.metadata(type: type)]
        default:
            return [.metadata(type: type)]
        }
    }

    private static func message(_ payload: [String: Any], id: String) -> [TranscriptEntry] {
        let blocks = payload["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        let images = blocks.filter { ($0["type"] as? String)?.contains("image") == true }.count
        switch payload["role"] as? String {
        case "user" where !isHarness(text):
            return [.message(TranscriptMessage(id: id, role: .user, text: text, imageCount: images))]
        case "assistant":
            return [.message(TranscriptMessage(id: id, role: .assistant, text: text))]
        default:
            return [.metadata(type: "message")]
        }
    }

    private static func reasoning(_ payload: [String: Any], id: String) -> [TranscriptEntry] {
        let summary = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let content = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let text = (summary.isEmpty ? content : summary).joined(separator: "\n\n")
        guard !text.isEmpty else { return [.metadata(type: "reasoning")] }
        return [.message(TranscriptMessage(id: id, role: .assistant, text: "", thinking: text))]
    }

    private static func call(_ payload: [String: Any], id: String, arguments: String?) -> [TranscriptEntry] {
        guard let name = payload["name"] as? String, let callID = payload["call_id"] as? String else {
            return [.metadata(type: payload["type"] as? String ?? "call")]
        }
        let call = TranscriptMessage.ToolCall(id: callID, name: name, arguments: arguments)
        return [.message(TranscriptMessage(id: id, role: .assistant, text: "", toolCalls: [call]))]
    }

    /// Shell output arrives as a header (`Chunk ID`, `Wall time`, `Process exited with code N`,
    /// `Original token count`) then `Output:`; the exit code becomes `details.exit_code`.
    private static func output(_ payload: [String: Any], id: String) -> [TranscriptEntry] {
        guard let callID = payload["call_id"] as? String else { return [.metadata(type: "output")] }
        var text = payload["output"] as? String
            ?? (payload["output"] as? [String: Any]).flatMap { $0["output"] as? String ?? $0["content"] as? String }
            ?? ""
        var exitCode: Int?
        if let marker = text.range(of: "\nOutput:\n") ?? (text.hasPrefix("Output:\n") ? text.range(of: "Output:\n") : nil) {
            let header = text[..<marker.lowerBound]
            if let match = header.firstMatch(of: /Process exited with code (-?\d+)/) { exitCode = Int(match.1) }
            text = String(text[marker.upperBound...])
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        while text.last?.isWhitespace == true { text.removeLast() }
        let details = exitCode.flatMap { json(["exit_code": $0]) }
        return [.message(TranscriptMessage(id: id, role: .toolResult, text: text, toolCallId: callID,
                                           isError: (exitCode ?? 0) != 0, details: details))]
    }

    private static func isHarness(_ text: String) -> Bool {
        ["<environment_context>", "<user_instructions>", "# AGENTS.md instructions", "<permissions instructions>",
         "<skills_instructions>", "<turn_aborted>"].contains(where: text.hasPrefix)
    }

    private static func normalized(_ arguments: String?) -> String? {
        guard let arguments, let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) else { return arguments }
        return json(object)
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
