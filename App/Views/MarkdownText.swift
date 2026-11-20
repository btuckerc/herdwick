import HerdrAPI
import SwiftUI

/// Assistant Markdown as native blocks: headings, lists and task lists, quotes, code and
/// tables. Inline emphasis, code spans and links come from `AttributedString`. The prose between
/// code blocks, lists, tables and rules is one `Text`, so a selection can run across paragraphs.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let segments = MarkdownRenderCache.shared.segments(for: text)
        // Prose and lists sit a paragraph's gap apart; code, tables, images and rules get more.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let string): Text(string)
                case .list(let items): ListBlock(items: items)
                case .code(let language, let text): CodeBlock(language: language, text: text).padding(.vertical, 3)
                case .table(let table): TableBlock(table: table).padding(.vertical, 3)
                // Shown as the reply shows them, not folded like tool images.
                case .images(let paths): TranscriptImages(paths: paths).environment(\.inlineImages, true).padding(.vertical, 3)
                case .rule: Divider().padding(.vertical, 10)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { previous, _ in MarkdownRenderCache.shared.discard(previous) }
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

    enum Segment {
        case prose(AttributedString)
        case list([ListItem])
        case code(language: String?, text: String)
        case table(RenderedTable)
        case images([String])
        case rule
    }

    struct RenderedTable {
        let header: [AttributedString]
        let rows: [[AttributedString]]
        let alignments: [MarkdownTable.Alignment]
    }

    struct ListItem {
        let marker: String
        let depth: Int
        let body: AttributedString
    }

    static func segments(_ text: String) -> [Segment] {
        let blocks = MarkdownBlocks.parse(text)
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
            case .table(let table):
                flush()
                segments.append(.table(RenderedTable(header: table.header.map(inline),
                                                     rows: table.rows.map { $0.map(inline) },
                                                     alignments: table.alignments)))
            case .rule: flush(); segments.append(.rule)
            case .list(let ordered, let start, let items):
                flush()
                segments.append(.list(listItems(ordered: ordered, start: start, items: items)))
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
        case .list: return AttributedString()
        case .paragraph(let text): return inline(text)
        case .code, .table, .rule: return AttributedString()
        }
    }

    private static func listItems(ordered: Bool, start: Int, items: [MarkdownListItem]) -> [ListItem] {
        var number = start
        return items.map { item in
            var marker = item.depth == 0 ? "•" : "◦"
            if ordered, item.depth == 0 { marker = "\(number)."; number += 1 }
            if let checked = item.checked { marker = checked ? "☑" : "☐" }
            var body = inline(item.text)
            if item.checked == true {
                body.strikethroughStyle = .single
                body.foregroundColor = .secondary
            }
            return ListItem(marker: marker, depth: item.depth, body: body)
        }
    }
}

/// A list with a hanging indent: wrapped lines return to the text's column, not under the
/// marker (round 22: "• Move: …" wrapped back to the bullet's edge and read as prose with a
/// bullet in front). Items sit a half-line apart, as the blocks of one reply do.
private struct ListBlock: View {
    let items: [MarkdownText.ListItem]
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var nesting: CGFloat = 18
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the gutter stops growing with the text: scaled, the bullet's
        // column took a fifth of a result card's width (round 87: opus#8, sa#7). Numbers and
        // checkboxes keep their own width; the indent still hangs.
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: large ? 4 : 6) {
                    Text(item.marker)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: large ? nil : markerWidth, alignment: .leading)
                        .accessibilityHidden(item.marker == "•" || item.marker == "◦")
                    Text(item.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * (large ? min(nesting, 24) : nesting))
            }
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
        .background(.fill.tertiary, in: .rect(cornerRadius: Tokens.Radius.plate))
    }
}

private struct TableBlock: View {
    let table: MarkdownText.RenderedTable

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
        .background(.fill.quaternary, in: .rect(cornerRadius: Tokens.Radius.plate))
    }

    private func cell(_ text: AttributedString, _ column: Int) -> some View {
        Text(text)
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

