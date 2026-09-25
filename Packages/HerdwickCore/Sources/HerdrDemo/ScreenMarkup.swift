import Foundation

/// Turns `.screen` markup into one full terminal frame of ANSI bytes at a given size.
///
/// Markup is plain text with style tags that stack until `</>` resets them:
/// `<b> <dim> <i> <u> <inverse>` and the theme's ANSI colours `<red> <green> <yellow> <blue>
/// <magenta> <cyan> <white> <gray>`. `<rule>` fills the rest of its row with `─`.
/// A line holding only `<footer>` splits the screen: what follows is pinned to the bottom
/// rows, like an agent's input box. Lines wrap at word boundaries with a hanging indent,
/// the way agent TUIs reflow; if the body is taller than the space left, its last lines
/// show, as in a scrolled terminal.
enum ScreenMarkup {
    static func render(_ markup: String, cols: Int, rows: Int) -> [UInt8] {
        var out = "\u{1B}[?25l\u{1B}[0m\u{1B}[2J"
        for (index, row) in screen(markup, cols: cols, rows: rows).enumerated() where !row.isEmpty {
            out += "\u{1B}[\(index + 1);1H" + encode(row)
        }
        out += "\u{1B}[0m"
        return Array(out.utf8)
    }

    /// The screen's rows as plain text, without styles.
    static func text(_ markup: String, cols: Int, rows: Int) -> [String] {
        screen(markup, cols: cols, rows: rows).map { String($0.map(\.character)) }
    }

    /// Exactly `rows` rows of at most `cols` columns each.
    private static func screen(_ markup: String, cols: Int, rows: Int) -> [[Cell]] {
        guard cols > 0, rows > 0 else { return [] }
        let lines = markup.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let split = lines.firstIndex(of: "<footer>")
        let bodySource = split.map { Array(lines[..<$0]) } ?? lines
        let footerSource = split.map { Array(lines[($0 + 1)...]) } ?? []

        let footer = Array(trimTrailingBlank(footerSource).map { layout(parse($0), cols: cols) }.joined().suffix(rows))
        let body = Array(trimTrailingBlank(bodySource).map { layout(parse($0), cols: cols) }.joined().suffix(rows - footer.count))
        return body + Array(repeating: [], count: rows - body.count - footer.count) + footer
    }

    private static func trimTrailingBlank(_ lines: [String]) -> [String] {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: Parsing

    private struct Style: Equatable {
        var codes: [Int] = []
        var sgr: String { "\u{1B}[0" + codes.map { ";\($0)" }.joined() + "m" }
    }

    private struct Cell {
        var character: Character
        var style: Style
    }

    private enum Token {
        case cell(Cell)
        case rule(Style)
    }

    private static let tags: [String: Int] = [
        "b": 1, "dim": 2, "i": 3, "u": 4, "inverse": 7,
        "red": 31, "green": 32, "yellow": 33, "blue": 34, "magenta": 35, "cyan": 36, "white": 37, "gray": 90,
    ]

    private static func parse(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var style = Style()
        var rest = Substring(line)
        while let first = rest.first {
            if first == "<", let close = rest.firstIndex(of: ">") {
                let name = rest[rest.index(after: rest.startIndex)..<close]
                if name == "/" {
                    style = Style()
                    rest = rest[rest.index(after: close)...]
                    continue
                }
                if name == "rule" {
                    tokens.append(.rule(style))
                    rest = rest[rest.index(after: close)...]
                    continue
                }
                if let code = tags[String(name)] {
                    style.codes.append(code)
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            tokens.append(.cell(Cell(character: first, style: style)))
            rest = rest.dropFirst()
        }
        return tokens
    }

    // MARK: Layout

    private static func layout(_ tokens: [Token], cols: Int) -> [[Cell]] {
        // A rule takes whatever width the rest of the row leaves.
        let fixed = tokens.reduce(0) { width, token in
            if case .cell(let cell) = token { width + cell.character.cellWidth } else { width }
        }
        var cells: [Cell] = []
        for token in tokens {
            switch token {
            case .cell(let cell): cells.append(cell)
            case .rule(let style): cells += Array(repeating: Cell(character: "─", style: style), count: max(0, cols - fixed))
            }
        }
        guard width(cells) > cols else { return [cells] }

        let indent = hangingIndent(cells)
        let hanging = indent < cols / 2 ? indent : 0
        var rows: [[Cell]] = []
        var row: [Cell] = []
        var index = 0
        while index < cells.count {
            // Next word, with the spaces that lead it.
            var end = index
            while end < cells.count, cells[end].character == " " { end += 1 }
            while end < cells.count, cells[end].character != " " { end += 1 }
            let word = Array(cells[index..<end])
            if width(row) + width(word) <= cols {
                row += word
            } else if row.isEmpty || width(word.drop { $0.character == " " }) > cols - hanging {
                // A word longer than a row breaks mid-word.
                for cell in word {
                    if width(row) + cell.character.cellWidth > cols { rows.append(row); row = pad(hanging) }
                    row.append(cell)
                }
            } else {
                rows.append(row)
                row = pad(hanging) + word.drop { $0.character == " " }
            }
            index = end
        }
        rows.append(row)
        return rows
    }

    /// Where wrapped rows continue: past leading spaces and a short bullet such as `●`,
    /// `⎿` or `>` and the spaces after it, so text lines up under text.
    private static func hangingIndent(_ cells: [Cell]) -> Int {
        let characters = cells.map(\.character)
        let lead = characters.prefix { $0 == " " }.count
        let marker = characters.dropFirst(lead).prefix { $0 != " " }
        guard !marker.isEmpty, marker.count <= 2, !marker.contains(where: { $0.isLetter || $0.isNumber }) else { return lead }
        let gap = characters.dropFirst(lead + marker.count).prefix { $0 == " " }.count
        return gap > 0 ? lead + marker.count + gap : lead
    }

    private static func pad(_ count: Int) -> [Cell] {
        Array(repeating: Cell(character: " ", style: Style()), count: count)
    }

    private static func width(_ cells: some Collection<Cell>) -> Int {
        cells.reduce(0) { $0 + $1.character.cellWidth }
    }

    private static func encode(_ row: [Cell]) -> String {
        var out = ""
        var current: Style?
        for cell in row {
            if cell.style != current {
                out += cell.style.sgr
                current = cell.style
            }
            out.append(cell.character)
        }
        return out + "\u{1B}[0m"
    }
}

private extension Character {
    /// Terminal columns: 2 for East Asian wide characters and emoji, 1 otherwise.
    var cellWidth: Int {
        guard let scalar = unicodeScalars.first else { return 0 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
