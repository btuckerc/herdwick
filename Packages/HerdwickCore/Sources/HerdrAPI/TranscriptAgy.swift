import Foundation

/// Antigravity CLI (`agy`) logs, one step per line in
/// `~/.gemini/antigravity-cli/brain/<conversation>/.system_generated/logs/transcript.jsonl`, checked
/// against agy 1.5.13: `USER_INPUT` wraps the user's text in `<USER_REQUEST>`; `PLANNER_RESPONSE`
/// carries the reply, thinking and `tool_calls`; each call's result follows as its own step, in call
/// order (`GENERIC`), so a call's id is the step index its result lands on.
enum AgyTranscript {
    static func entries(_ line: ArraySlice<UInt8>, parsed: [String: Any]? = nil) -> [TranscriptEntry] {
        guard let record = parsed ?? (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let type = record["type"] as? String, let step = record["step_index"] as? Int else {
            return [.malformed(String(decoding: line.prefix(2048), as: UTF8.self))]
        }
        let id = "agy-\(step)"
        let timestamp = TranscriptMessage.date(record["created_at"])
        let content = record["content"] as? String ?? ""
        switch type {
        case "USER_INPUT":
            let text = userText(content)
            guard !text.isEmpty else { return [.metadata(type: type)] }
            return [.message(TranscriptMessage(id: id, role: .user, text: text, timestamp: timestamp))]
        case "PLANNER_RESPONSE":
            let calls = (record["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { index, call in
                (call["name"] as? String).map { name in
                    TranscriptMessage.ToolCall(id: "agy-\(step + 1 + index)", name: toolName(name),
                                               arguments: arguments(name, call["args"] as? [String: Any] ?? [:]))
                }
            }
            let message = TranscriptMessage(id: id, role: .assistant, text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                                            thinking: record["thinking"] as? String ?? "", toolCalls: calls, timestamp: timestamp)
            // A reply without tool calls is where agy hands the turn back.
            return calls.isEmpty ? [.message(message), .turnEnded(at: timestamp)] : [.message(message)]
        case "GENERIC":
            return [output(content, id: id)]
        default:
            return [.metadata(type: type)]
        }
    }

    /// The text inside `<USER_REQUEST>`; agy appends metadata and settings notes after it.
    private static func userText(_ content: String) -> String {
        guard let start = content.range(of: "<USER_REQUEST>"),
              let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex) else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// agy's shell and read tools under the names `ToolDetail` already renders.
    private static func toolName(_ name: String) -> String {
        switch name {
        case "run_command": "shell"
        case "read_file": "read"
        default: name
        }
    }

    /// agy records every argument value as JSON text (`"\"/path\""`); decode them, renaming the
    /// shell and read arguments to what `ToolDetail` reads.
    private static func arguments(_ name: String, _ args: [String: Any]) -> String? {
        var decoded = args.mapValues { value -> Any in
            guard let text = value as? String, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return value }
            return object
        }
        switch name {
        case "run_command": decoded = ["command": decoded["CommandLine"] ?? ""]
        case "read_file":
            var path = decoded["Path"] as? String ?? ""
            if let start = decoded["StartLine"] as? Int, let end = decoded["EndLine"] as? Int { path += ":\(start)-\(end)" }
            decoded = ["path": path]
        default: break
        }
        guard JSONSerialization.isValidJSONObject(decoded),
              let data = try? JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A step result opens with `Created At:`/`Completed At:` lines; commands then say
    /// `Command exited with code N.` and `Command output:`, which become the exit code and the body.
    private static func output(_ content: String, id: String) -> TranscriptEntry {
        var lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.hasPrefix("Created At:") || first.hasPrefix("Completed At:") { lines.removeFirst() }
        var text = lines.joined(separator: "\n")
        var exitCode: Int?
        if let match = text.firstMatch(of: /Command exited with code (-?\d+)\./) { exitCode = Int(match.1) }
        if let marker = text.range(of: "Command output:\n") {
            text = String(text[marker.upperBound...])
            if text.hasPrefix("---\n") { text.removeFirst(4) }
        }
        while text.last?.isWhitespace == true { text.removeLast() }
        let details = exitCode.flatMap { code in
            (try? JSONSerialization.data(withJSONObject: ["exit_code": code])).map { String(decoding: $0, as: UTF8.self) }
        }
        return .message(TranscriptMessage(id: id, role: .toolResult, text: text, toolCallId: id,
                                          isError: (exitCode ?? 0) != 0, details: details))
    }
}
