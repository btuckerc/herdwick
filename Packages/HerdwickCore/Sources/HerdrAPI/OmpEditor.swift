import Foundation

/// omp's input box at the bottom of its screen:
///
///     ╭── Opus 5.5   hearth ──────────╮
///     │  first line                   │
///     ╰─ last line                   ─╯
///
/// The last line sits on the bottom border, so an empty editor is a bare `╰─ … ─╯`.
public enum OmpEditor {
    /// The editor's text, wrapped rows joined by newlines; nil when it is empty or not on screen.
    public static func draft(inScreen visibleText: String) -> String? {
        let lines = visibleText.split(separator: "\n", omittingEmptySubsequences: false)
        guard let bottom = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╰") }),
              let top = lines[..<bottom].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╭") })
        else { return nil }
        let rows = lines[(top + 1)...bottom].map { line -> String in
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            for prefix in ["╰─", "│"] where s.hasPrefix(prefix) { s = s.dropFirst(prefix.count) }
            for suffix in ["─╯", "│"] where s.hasSuffix(suffix) { s = s.dropLast(suffix.count) }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let text = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
