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
                // Shown as the reply shows them, not folded like tool images.
                case .images(let paths): TranscriptImages(paths: paths).environment(\.inlineImages, true)
                case .rule: Divider().padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Code spans naming an image or text file (`shot.png`, `Views/a.swift:42`) link to its
    /// preview, as do paths in prose (App/Views/a.swift), bare image names (shot.png) and image
    /// embeds (`![shot](shot.png)`) inside other text; remote ones stay plain links.
    static func inline(_ text: String) -> AttributedString {
        let text = text.contains("![") ? linkingEmbeds(text) : text
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if text.contains("`") {
            for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
                if let path = namedFile(String(string[run.range].characters)), let url = fileLink(path) { string[run.range].link = url }
            }
        }
        if text.contains("/") || text.contains(".") { linkingPaths(&string) }
        return string
    }

    /// A file named in prose: a word with a `/`, or with an image extension (a bare `a.swift`
    /// could as well be Node.js), never a URL (`https://x/a.md` stays as it is).
    private static func linkingPaths(_ string: inout AttributedString) {
        let leading = CharacterSet(charactersIn: "([<\"'"), trailing = CharacterSet(charactersIn: ".,;:!?)]>\"'")
        var links: [(Range<AttributedString.Index>, URL)] = []
        for run in string.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) != true {
            let text = String(string[run.range].characters)
            // Walked forward once: each word's index starts from the last one's.
            var index = run.range.lowerBound, previous = text.startIndex
            for word in text.split(whereSeparator: \.isWhitespace) where word.contains(".") && !word.contains("://") {
                var found = word
                while let first = found.unicodeScalars.first, leading.contains(first) { found = found.dropFirst() }
                while let last = found.unicodeScalars.last, trailing.contains(last) { found = found.dropLast() }
                guard let path = namedFile(String(found)), found.contains("/") || isImagePath(path), let url = fileLink(path) else { continue }
                index = string.characters.index(index, offsetBy: text.distance(from: previous, to: found.startIndex))
                previous = found.startIndex
                links.append((index..<string.characters.index(index, offsetBy: found.count), url))
            }
        }
        for (range, url) in links { string[range].link = url }
    }

    /// `![alt](target "title")`, one level of parentheses in the target; group 1 is an escaping `\`.
    nonisolated(unsafe) private static let embed = #/(\\?)!\[([^\]]*)\]\(<?((?:[^()\s>]|\([^()\s]*\))+)>?(?:\s+"[^"]*")?\)/#

    /// Outside code spans only: a reply quoting the syntax keeps it as written.
    private static func linkingEmbeds(_ text: String) -> String {
        text.split(separator: "`", omittingEmptySubsequences: false).enumerated().map { index, part in
            index.isMultiple(of: 2) ? String(part).replacing(embed) { match in
                guard match.1.isEmpty else { return String(match.0) }
                let target = String(match.3)
                let link = localImage(target).flatMap(fileLink)?.absoluteString ?? target
                return "[\(match.2.isEmpty ? (target as NSString).lastPathComponent : String(match.2))](\(link))"
            } : String(part)
        }.joined(separator: "`")
    }

    /// An embed's host path: absolute, `~/…`, relative, or a `file:` URL; nil for web images.
    private static func localImage(_ target: String) -> String? {
        if target.hasPrefix("file://") { return URL(string: target)?.path(percentEncoded: false) }
        guard !target.contains("://"), !target.hasPrefix("data:") else { return nil }
        return target.removingPercentEncoding ?? target
    }

    /// A paragraph of nothing but host-image embeds shows the images themselves.
    private static func embeddedImages(_ text: String) -> [String]? {
        guard text.contains("!["), text.replacing(embed, with: "").allSatisfy(\.isWhitespace) else { return nil }
        let paths = text.matches(of: embed).map { $0.1.isEmpty ? localImage(String($0.3)) : nil }
        return paths.contains(nil) ? nil : paths.compactMap(\.self)
    }

    private enum Segment {
        case prose(AttributedString)
        case code(language: String?, text: String)
        case table(MarkdownTable)
        case images([String])
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
            if case .paragraph(let text) = block, let paths = embeddedImages(text) {
                flush()
                segments.append(.images(paths))
                continue
            }
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

