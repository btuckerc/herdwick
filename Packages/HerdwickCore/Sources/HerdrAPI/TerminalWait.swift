import Foundation

public struct TerminalInputWait: Sendable, Equatable {
    public let toolCallId: String
    public let command: String
    public let startedAt: Date?

    public init(toolCallId: String, command: String, startedAt: Date?) {
        self.toolCallId = toolCallId
        self.command = command
        self.startedAt = startedAt
    }
}

public struct ConsoleScreen: Sendable, Equatable {
    public let command: String
    public let lines: [String]

    public init(command: String, lines: [String]) {
        self.command = command
        self.lines = lines
    }

    public static func parse(_ visible: String) -> ConsoleScreen? {
        let rows = visible.components(separatedBy: .newlines)
        for start in rows.indices where rows[start].contains("╭") {
            var end = start + 1
            while end < rows.count && !rows[end].contains("╰") { end += 1 }
            guard end < rows.count else { continue }
            let box = rows[(start + 1)..<end].compactMap { row -> String? in
                guard let left = row.firstIndex(of: "│") else { return nil }
                let afterLeft = row.index(after: left)
                let right = row[afterLeft...].lastIndex(of: "│") ?? row.endIndex
                return String(row[afterLeft..<right]).trimmingCharacters(in: .whitespaces)
            }
            guard let headerIndex = box.firstIndex(where: { $0.contains("Console ") && $0.contains(" ⟨running⟩") }),
                  let footerIndex = box.firstIndex(where: { $0.contains("input forwarded to PTY") }),
                  headerIndex < footerIndex else { continue }
            let header = box[headerIndex]
            guard let consoleRange = header.range(of: "Console "),
                  let runningRange = header.range(of: " ⟨running⟩", range: consoleRange.upperBound..<header.endIndex) else { continue }
            let command = String(header[consoleRange.upperBound..<runningRange.lowerBound])
            var body = Array(box[(headerIndex + 1)..<footerIndex])
            while body.last?.isEmpty == true { body.removeLast() }
            return ConsoleScreen(command: command, lines: body)
        }
        return nil
    }

    /// The last non-empty line.
    public var prompt: String? { lines.last(where: { !$0.isEmpty }) }

    /// Whether the prompt explicitly offers a yes/no choice.
    public var offersYesNo: Bool {
        guard let prompt else { return false }
        let lower = prompt.lowercased()
        return ["[y/n]", "(y/n)", "(yes/no)", "[yes/no]"].contains(where: lower.contains)
    }

    /// Whether the last line reads as a question the command waits on: a yes/no choice, a
    /// password, or a line ending in `?` or `:` (`Continue?`, `Passphrase:`).
    public var asksForInput: Bool {
        guard let prompt else { return false }
        let lower = prompt.lowercased()
        if offersYesNo || lower.contains("password") || lower.contains("passphrase") { return true }
        return prompt.hasSuffix("?") || prompt.hasSuffix(":")
    }
}
