import HerdrAPI
import SwiftUI

/// Assistant Markdown as native blocks: headings, lists and task lists, quotes, code and
/// tables. Inline emphasis, code spans and links come from `AttributedString`.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .table(let table):
            TableBlock(table: table)
        case .list(let ordered, let start, let items):
            ListBlock(ordered: ordered, start: start, items: items)
        case .quote(let text):
            HStack(spacing: 10) {
                Capsule().fill(.quaternary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
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

private struct ListBlock: View {
    let ordered: Bool
    let start: Int
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item, index)
                    Text(MarkdownText.inline(item.text))
                        .strikethrough(item.checked == true, color: .secondary)
                        .foregroundStyle(item.checked == true ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem, _ index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered, item.depth == 0 {
            Text("\(start + ordinal(index)).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(item.depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
        }
    }

    /// Position among the top-level items, so nested items don't advance the count.
    private func ordinal(_ index: Int) -> Int {
        items[..<index].filter { $0.depth == 0 }.count
    }
}
