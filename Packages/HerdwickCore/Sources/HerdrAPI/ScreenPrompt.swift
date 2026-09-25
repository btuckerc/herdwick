import Foundation

// A prompt an agent is showing in its terminal, read from `pane.read` visible text.
//
// Three shapes cover the agents herdr runs today, each checked against live captures:
// - omp's `ask` box: `╭─ Ask ─╮`, a tab row (`fruits    Submit`) when there are several
//   questions or checkboxes, radio U+F10C / box U+F096 / checked U+F14A, cursor U+F054,
//   a "Review answers" page, and a `Custom answer:` box for "Other".
// - Claude Code's AskUserQuestion: a tab row (`←  ☐ Color  ☒ Toppings  ✔ Submit  →`, or
//   just `☐ Pet`), numbered rows with `❯` on the cursor, `[ ]`/`[✔]` checkboxes and an
//   unnumbered `Submit` row for multi-select, "Type something." for a custom answer, and a
//   "Review your answers" page.
// - A numbered choice list with a cursor (`❯` Claude, `›` Codex): permission and approval
//   prompts, plan approval, trust dialogs. The question is the nearest line ending in "?".

public struct ScreenPrompt: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case ompAsk, claudeAsk, choice }
    public enum Phase: Sendable, Equatable { case question, review, customInput }

    public struct Option: Sendable, Equatable {
        public var label: String
        /// Indented text under the option: its description, or a wrapped label.
        public var detail: String?
        public var number: Int?
        /// Nil when the option is not a checkbox.
        public var checked: Bool?
        /// The agent's own free-text row ("Other (type your own)", "Type something.").
        public var isOther: Bool
        /// The row that confirms a multi-select question or the review page.
        public var isSubmit: Bool
        public init(label: String, detail: String? = nil, number: Int? = nil, checked: Bool? = nil,
                    isOther: Bool = false, isSubmit: Bool = false) {
            self.label = label; self.detail = detail; self.number = number; self.checked = checked
            self.isOther = isOther; self.isSubmit = isSubmit
        }
    }

    public var style: Style
    public var phase: Phase
    /// The question being asked, or the prompt's own question ("Do you want to proceed?").
    public var title: String
    /// What the prompt is about: the command, the file, the reason. Choice prompts only.
    public var context: [String]
    public var options: [Option]
    public var cursor: Int?
    /// Question tabs (omp ids, Claude headers) when the prompt pages through several.
    public var tabs: [String]

    public init(style: Style, phase: Phase = .question, title: String, context: [String] = [],
                options: [Option], cursor: Int?, tabs: [String] = []) {
        self.style = style; self.phase = phase; self.title = title; self.context = context
        self.options = options; self.cursor = cursor; self.tabs = tabs
    }

    public static func parse(_ visibleText: String) -> ScreenPrompt? {
        let lines = visibleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return omp(lines) ?? claudeAsk(lines) ?? choice(lines)
    }
}

// MARK: - omp

private let ompCursor: Character = "\u{F054}"
private let ompRadio: Character = "\u{F10C}"
private let ompBox: Character = "\u{F096}"
private let ompChecked: Character = "\u{F14A}"

extension ScreenPrompt {
    static func omp(_ lines: [String]) -> ScreenPrompt? {
        if let top = lines.lastIndex(where: { $0.contains("─ Custom answer:") }),
           !lines[(top + 1)...].contains(where: { $0.contains("─ Ask ") }) {
            let header = lines[top]
            let start = header.range(of: "Custom answer:")!.upperBound
            let title = String(header[start...]).trimmingCharacters(in: CharacterSet(charactersIn: " ─╮"))
            return ScreenPrompt(style: .ompAsk, phase: .customInput, title: title, options: [], cursor: nil)
        }
        guard let top = lines.lastIndex(where: { $0.contains("─ Ask ") }),
              let divider = lines[(top + 1)...].firstIndex(where: { $0.contains("├") }),
              let end = lines[(divider + 1)...].firstIndex(where: { $0.contains("├") || $0.contains("╰") })
        else { return nil }

        var header = lines[(top + 1)..<divider].map(boxed).filter { !$0.isEmpty }
        var tabs: [String] = []
        if header.count >= 2, let first = header.first, first.hasSuffix("Submit") {
            tabs = first.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "Submit" }
            header.removeFirst()
        }
        let title = header.joined(separator: " ").normalizedSpace
        let body = lines[(divider + 1)..<end]

        if title == "Review answers" {
            var options: [Option] = []; var cursor: Int?
            for line in body {
                let content = boxed(line)
                guard content.hasSuffix("Submit") else { continue }
                if content.contains(ompCursor) { cursor = options.count }
                options.append(Option(label: "Submit", isSubmit: true))
            }
            let context = body.map(boxed).filter { !$0.isEmpty && !$0.hasSuffix("Submit") }
            return ScreenPrompt(style: .ompAsk, phase: .review, title: title, context: context,
                                options: options, cursor: cursor, tabs: tabs)
        }

        var options: [Option] = []; var cursor: Int?
        for line in body {
            let content = boxed(line)
            guard let mark = content.firstIndex(where: { $0 == ompRadio || $0 == ompBox || $0 == ompChecked }) else {
                if !content.isEmpty, !options.isEmpty {
                    let detail = options[options.count - 1].detail.map { $0 + " " } ?? ""
                    options[options.count - 1].detail = detail + content
                }
                continue
            }
            var label = String(content[content.index(after: mark)...]).trimmingCharacters(in: .whitespaces)
            label = label.replacingOccurrences(of: " (Recommended)", with: "")
            let glyph = content[mark]
            if content[..<mark].contains(ompCursor) { cursor = options.count }
            options.append(Option(label: label, checked: glyph == ompRadio ? nil : glyph == ompChecked,
                                  isOther: label == "Other (type your own)"))
        }
        guard !options.isEmpty else { return nil }
        return ScreenPrompt(style: .ompAsk, title: title, options: options, cursor: cursor, tabs: tabs)
    }

    /// The text inside a `│ … │` box row.
    private static func boxed(_ line: String) -> String {
        var s = Substring(line)
        if let i = s.firstIndex(of: "│") { s = s[s.index(after: i)...] }
        if let i = s.lastIndex(of: "│") { s = s[..<i] }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Claude Code AskUserQuestion

private let claudeCursor: Character = "❯"

extension ScreenPrompt {
    static func claudeAsk(_ lines: [String]) -> ScreenPrompt? {
        // The tab row sits right under the rule that separates the prompt from the transcript.
        guard let tabRow = lines.indices.last(where: { $0 > 0 && isRule(lines[$0 - 1]) && isClaudeTabRow(lines[$0]) })
        else { return nil }
        let tabs = lines[tabRow]
            .replacingOccurrences(of: "←", with: "").replacingOccurrences(of: "→", with: "")
            .components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("✔") }
            .map { String($0.drop(while: { $0 == "☐" || $0 == "☒" || $0 == " " })) }

        let rest = Array(lines[(tabRow + 1)...])
        guard let firstRow = rest.firstIndex(where: { numberedRow($0) != nil }) else { return nil }
        let heading = rest[..<firstRow].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = heading.first else { return nil }

        if first == "Review your answers" {
            let title = heading.last ?? first
            let context = Array(heading.dropFirst().dropLast())
            let (options, cursor) = numberedOptions(rest[firstRow...], checkboxes: false)
            return ScreenPrompt(style: .claudeAsk, phase: .review, title: title, context: context,
                                options: options, cursor: cursor, tabs: tabs)
        }

        // Rows below the divider ("Chat about this") are not answers.
        let block = rest[firstRow...].prefix(while: { !isRule($0) })
        var (options, cursor) = numberedOptions(block, checkboxes: true)
        guard !options.isEmpty else { return nil }
        if let other = options.lastIndex(where: { !$0.isSubmit && $0.number != nil }),
           options[other].label.hasPrefix("Type something") {
            options[other].isOther = true
        }
        return ScreenPrompt(style: .claudeAsk, title: heading.joined(separator: " ").normalizedSpace,
                            options: options, cursor: cursor, tabs: tabs)
    }

    private static func isClaudeTabRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("☐") || trimmed.hasPrefix("☒") || (trimmed.hasPrefix("←") && trimmed.hasSuffix("→"))
    }

    /// Numbered rows (`❯ 1. Red`), their indented descriptions, and an unnumbered `Submit` row.
    private static func numberedOptions(_ rows: ArraySlice<String>, checkboxes: Bool) -> ([Option], Int?) {
        var options: [Option] = []; var cursor: Int?
        for line in rows {
            if let row = numberedRow(line) {
                var label = row.label; var checked: Bool?
                if checkboxes, label.hasPrefix("["), let close = label.firstIndex(of: "]") {
                    checked = label[label.index(after: label.startIndex)..<close].contains(where: { !$0.isWhitespace })
                    label = String(label[label.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                if row.cursor { cursor = options.count }
                options.append(Option(label: label, number: row.number, checked: checked))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let hasCursor = trimmed.first == claudeCursor || trimmed.first == "›"
            let bare = hasCursor ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed
            if bare == "Submit" {
                if hasCursor { cursor = options.count }
                options.append(Option(label: "Submit", isSubmit: true))
            } else if !options.isEmpty, line.first?.isWhitespace == true {
                let detail = options[options.count - 1].detail.map { $0 + " " } ?? ""
                options[options.count - 1].detail = detail + trimmed
            } else if !options.isEmpty {
                break
            }
        }
        return (options, cursor)
    }
}

// MARK: - Numbered choice (permissions, approvals)

extension ScreenPrompt {
    static func choice(_ lines: [String]) -> ScreenPrompt? {
        // The option block closest to the bottom of the screen.
        guard let last = lines.lastIndex(where: { numberedRow($0) != nil }) else { return nil }
        var first = last
        var index = last - 1
        while index >= 0 {
            if numberedRow(lines[index]) != nil { first = index; index -= 1; continue }
            // A run of indented text continues the option above it (a wrapped label).
            var above = index
            while above >= 0, numberedRow(lines[above]) == nil, isIndentedText(lines[above]) { above -= 1 }
            guard above >= 0, above < index, numberedRow(lines[above]) != nil else { break }
            index = above
        }
        var options: [Option] = []; var cursor: Int?
        for line in lines[first...last] {
            if let row = numberedRow(line) {
                if row.cursor { cursor = options.count }
                options.append(Option(label: stripShortcut(row.label), number: row.number))
            } else if !options.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let detail = options[options.count - 1].detail.map { $0 + " " } ?? ""
                options[options.count - 1].detail = detail + trimmed
            }
        }
        guard options.count >= 2, cursor != nil,
              options.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }) else { return nil }

        // Everything between the prompt's top edge and the options: a rule (Claude) or a
        // stretch of blank rows (Codex) separates it from the transcript.
        var top = first
        var blanks = 0
        while top > 0, !isRule(lines[top - 1]), first - top < 40 {
            blanks = lines[top - 1].trimmingCharacters(in: .whitespaces).isEmpty ? blanks + 1 : 0
            if blanks >= 3 { break }
            top -= 1
        }
        let region = lines[top..<first].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy({ $0 == "╌" }) }
        // Claude asks right above its options, with the details above the question; Codex
        // asks first, then lists details ("Reason: …?", "$ cmd"), which are never the title.
        let titleIndex = region.lastIndex { line in
            line.hasSuffix("?") && !line.hasPrefix("$ ") && line.firstMatch(of: #/^[A-Z][A-Za-z ]{0,20}: /#) == nil
        }
        let title = titleIndex.map { region[$0] } ?? region.first ?? ""
        let context: [String]
        if let titleIndex {
            context = titleIndex == region.count - 1 ? Array(region[..<titleIndex]) : Array(region[(titleIndex + 1)...])
        } else {
            context = Array(region.dropFirst())
        }
        return ScreenPrompt(style: .choice, title: title, context: context, options: options, cursor: cursor)
    }

    /// Codex labels end in their shortcut key: "Yes, proceed (y)", "No, … (esc)".
    private static func stripShortcut(_ label: String) -> String {
        guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else { return label }
        let key = label[open.upperBound..<label.index(before: label.endIndex)]
        let isShortcut = key.count == 1 || key == "esc" || key.hasPrefix("shift+") || key.hasPrefix("ctrl+")
        return isShortcut ? String(label[..<open.lowerBound]) : label
    }
}

// MARK: - Shared

private struct NumberedRow { let cursor: Bool; let number: Int; let label: String }

/// `❯ 1. Yes`, `  2. No`, `› 1. Yes, proceed (y)`.
private func numberedRow(_ line: String) -> NumberedRow? {
    var s = Substring(line).drop(while: { $0 == " " })
    var cursor = false
    if let first = s.first, first == "❯" || first == "›" {
        cursor = true
        s = s.dropFirst().drop(while: { $0 == " " })
    }
    let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
    guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
    s = s.dropFirst(digits.count)
    guard s.hasPrefix(". ") else { return nil }
    let label = s.dropFirst(2).trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return NumberedRow(cursor: cursor, number: number, label: label)
}

/// A horizontal rule the agents draw between the transcript and the prompt.
private func isRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "─" }
}

private func isIndentedText(_ line: String) -> Bool {
    line.first?.isWhitespace == true && !line.trimmingCharacters(in: .whitespaces).isEmpty
}

extension String {
    var normalizedSpace: String { split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}
