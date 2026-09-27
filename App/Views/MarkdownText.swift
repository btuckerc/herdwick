import HerdrAPI
import SwiftUI

/// Assistant Markdown as native blocks: headings, lists and task lists, quotes, code and
/// tables. Inline emphasis, code spans and links come from `AttributedString`. The prose between
/// code blocks, tables and rules is one `Text`, so a selection can run across paragraphs and items.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(MarkdownBlocks.parse(text)).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let string): Text(string)
                case .code(let language, let text): CodeBlock(language: language, text: text)
                case .table(let table): TableBlock(table: table)
                case .rule: Divider().padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Code spans naming an image file (`shot.png`) link to the image preview.
    static func inline(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        guard text.contains("`") else { return string }
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
            let path = String(string[run.range].characters)
            if isImagePath(path), !path.contains(" "), let url = imageLink(path) { string[run.range].link = url }
        }
        return string
    }

    private enum Segment {
        case prose(AttributedString)
        case code(language: String?, text: String)
        case table(MarkdownTable)
        case rule
    }

    private static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var segments: [Segment] = []
        var prose = AttributedString()
        func flush() {
            if !prose.characters.isEmpty { segments.append(.prose(prose)) }
            prose = AttributedString()
        }
        for block in blocks {
            switch block {
            case .code(let language, let text): flush(); segments.append(.code(language: language, text: text))
            case .table(let table): flush(); segments.append(.table(table))
            case .rule: flush(); segments.append(.rule)
            default:
                if !prose.characters.isEmpty { prose += blockGap }
                prose += Self.prose(block)
            }
        }
        flush()
        return segments
    }

    /// A line break plus a short blank line: the space between blocks inside one `Text`.
    private static let blockGap: AttributedString = {
        var gap = AttributedString("\n\n")
        gap[gap.index(afterCharacter: gap.startIndex)...].font = .system(size: 6)
        return gap
    }()

    private static func prose(_ block: MarkdownBlock) -> AttributedString {
        switch block {
        case .heading(let level, let text):
            var heading = inline(text)
            heading.font = level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold()
            heading.accessibilityHeadingLevel = level == 1 ? .h1 : level == 2 ? .h2 : level == 3 ? .h3 : .h4
            return heading
        case .quote(let text):
            var quote = AttributedString("▎ ") + inline(text)
            quote.foregroundColor = .secondary
            return quote
        case .list(let ordered, let start, let items):
            var list = AttributedString()
            var number = start
            for (index, item) in items.enumerated() {
                if index > 0 { list += AttributedString("\n") }
                var marker = item.depth == 0 ? "•" : "◦"
                if ordered, item.depth == 0 { marker = "\(number)."; number += 1 }
                if let checked = item.checked { marker = checked ? "☑" : "☐" }
                var prefix = AttributedString(String(repeating: "    ", count: item.depth) + marker + " ")
                prefix.foregroundColor = .secondary
                var body = inline(item.text)
                if item.checked == true {
                    body.strikethroughStyle = .single
                    body.foregroundColor = .secondary
                }
                list += prefix + body
            }
            return list
        case .paragraph(let text): return inline(text)
        case .code, .table, .rule: return AttributedString()
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language {
                Text(language).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.footnote.monospaced())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
    }
}

private struct TableBlock: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column).fontWeight(.semibold)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.rows[row][column], column)
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(12)
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }

    private func cell(_ text: String, _ column: Int) -> some View {
        Text(MarkdownText.inline(text))
            .gridColumnAlignment(alignment(table.alignments[column]))
    }

    private func alignment(_ value: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

