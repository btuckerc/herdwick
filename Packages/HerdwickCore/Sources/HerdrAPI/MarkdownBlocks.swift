import Foundation

/// Block-level Markdown structure for assistant text. Inline markup (emphasis,
/// code spans, links) stays in each string for the app's inline renderer.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case table(MarkdownTable)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote(String)
    case rule
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }
    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    public var text: String
    /// Nesting depth, 0 for top-level items.
    public var depth: Int
    /// `true`/`false` for task items (`- [x]`, `- [ ]`), nil otherwise.
    public var checked: Bool?

    public init(text: String, depth: Int = 0, checked: Bool? = nil) {
        self.text = text
        self.depth = depth
        self.checked = checked
    }
}

public enum MarkdownBlocks {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var parser = Parser(lines: source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return parser.run()
    }

    private struct Parser {
        let lines: [String]
        var i = 0
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        init(lines: [String]) { self.lines = lines }

        mutating func run() -> [MarkdownBlock] {
            while i < lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    flush(); i += 1
                } else if let fence = fenceMarker(trimmed) {
                    flush(); code(fence: fence, info: String(trimmed.dropFirst(fence.count)))
                } else if let heading = heading(trimmed) {
                    flush(); blocks.append(heading); i += 1
                } else if isRule(trimmed) {
                    flush(); blocks.append(.rule); i += 1
                } else if trimmed.hasPrefix(">") {
                    flush(); quote()
                } else if listMarker(line) != nil {
                    flush(); list()
                } else if trimmed.contains("|"), i + 1 < lines.count,
                          let alignments = delimiterRow(lines[i + 1]) {
                    flush(); table(alignments: alignments)
                } else {
                    paragraph.append(trimmed); i += 1
                }
            }
            flush()
            return blocks
        }

        mutating func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        func fenceMarker(_ trimmed: String) -> String? {
            for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
                let run = trimmed.prefix { $0 == mark.first }
                return String(run)
            }
            return nil
        }

        mutating func code(fence: String, info: String) {
            let language = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            let indent = lines[i].prefix { $0 == " " }.count
            i += 1
            var body: [String] = []
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) { i += 1; break }
                var line = Substring(lines[i])
                var drop = indent
                while drop > 0, line.first == " " { line = line.dropFirst(); drop -= 1 }
                body.append(String(line)); i += 1
            }
            blocks.append(.code(language: language?.isEmpty == false ? language : nil,
                                text: body.joined(separator: "\n")))
        }

        func heading(_ trimmed: String) -> MarkdownBlock? {
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
        }

        func isRule(_ trimmed: String) -> Bool {
            let chars = trimmed.filter { $0 != " " }
            guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
            return chars.allSatisfy { $0 == first }
        }

        mutating func quote() {
            var body: [String] = []
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                body.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            blocks.append(.quote(body.joined(separator: "\n")))
        }

        struct Marker { var indent: Int; var ordered: Bool; var number: Int; var content: String }

        func listMarker(_ line: String) -> Marker? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let rest = line.drop { $0 == " " || $0 == "\t" }
            if let first = rest.first, "-*+".contains(first) {
                let after = rest.dropFirst()
                guard after.first == " " else { return nil }
                return Marker(indent: indent, ordered: false, number: 1,
                              content: after.trimmingCharacters(in: .whitespaces))
            }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let delim = after.first, delim == "." || delim == ")",
                  after.dropFirst().first == " " else { return nil }
            return Marker(indent: indent, ordered: true, number: Int(digits) ?? 1,
                          content: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }

        mutating func list() {
            guard let first = listMarker(lines[i]) else { return }
            var items: [MarkdownListItem] = []
            var indents: [Int] = []
            while i < lines.count {
                let line = lines[i]
                if let marker = listMarker(line) {
                    if marker.indent <= first.indent, marker.ordered != first.ordered { break }
                    while let last = indents.last, last > marker.indent { indents.removeLast() }
                    if indents.last != marker.indent { indents.append(marker.indent) }
                    var text = marker.content
                    var checked: Bool?
                    if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)) }
                    else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" {
                        checked = true; text = String(text.dropFirst(3))
                    }
                    items.append(MarkdownListItem(text: text.trimmingCharacters(in: .whitespaces),
                                                  depth: indents.count - 1, checked: checked))
                    i += 1
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line continues the list only if another item follows.
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    guard j < lines.count, let next = listMarker(lines[j]),
                          next.indent > first.indent || next.ordered == first.ordered else { break }
                    i = j
                } else if line.first == " " || line.first == "\t", !items.isEmpty {
                    // Continuation line of the previous item.
                    items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
        }

        func cells(_ line: String) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
            var result: [String] = []
            var current = ""
            var escaped = false
            var inCode = false
            for ch in row {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "`" { inCode.toggle() }
                if ch == "|", !inCode { result.append(current); current = ""; continue }
                current.append(ch)
            }
            result.append(current)
            return result.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        func delimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
            guard line.contains("-") else { return nil }
            let parts = cells(line)
            var alignments: [MarkdownTable.Alignment] = []
            for part in parts {
                let core = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
                switch (part.hasPrefix(":"), part.hasSuffix(":")) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                default: alignments.append(.leading)
                }
            }
            return alignments
        }

        mutating func table(alignments: [MarkdownTable.Alignment]) {
            let header = cells(lines[i])
            guard header.count == alignments.count else {
                paragraph.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1; return
            }
            i += 2
            var rows: [[String]] = []
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("|") else { break }
                var row = cells(lines[i])
                if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                rows.append(Array(row.prefix(header.count)))
                i += 1
            }
            blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
        }
    }
}
