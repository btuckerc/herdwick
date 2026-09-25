import Testing
@testable import HerdrAPI

@Suite struct MarkdownBlocksTests {
    @Test func tableWithAlignmentsEscapesAndRaggedRows() {
        let blocks = MarkdownBlocks.parse("""
        Results:

        | Name | Count | Note |
        |:-----|------:|:----:|
        | `a|b` | 3 | pipe \\| here |
        | short |
        """)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .paragraph("Results:"))
        guard case .table(let table) = blocks[1] else { Issue.record("no table"); return }
        #expect(table.header == ["Name", "Count", "Note"])
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.rows == [["`a|b`", "3", "pipe | here"], ["short", "", ""]])
    }

    @Test func pipeTextWithoutDelimiterRowStaysParagraph() {
        #expect(MarkdownBlocks.parse("a | b\nc | d") == [.paragraph("a | b\nc | d")])
    }

    @Test func tableEndsAtBlankOrNonPipeLine() {
        let blocks = MarkdownBlocks.parse("a|b\n-|-\n1|2\nafter")
        #expect(blocks == [
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])),
            .paragraph("after"),
        ])
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let blocks = MarkdownBlocks.parse("```swift\nlet x = 1\n\n# not a heading\n```\nDone")
        #expect(blocks == [.code(language: "swift", text: "let x = 1\n\n# not a heading"), .paragraph("Done")])
    }

    @Test func unterminatedFenceRunsToEnd() {
        #expect(MarkdownBlocks.parse("```\nx") == [.code(language: nil, text: "x")])
    }

    @Test func headingsRulesAndQuotes() {
        let blocks = MarkdownBlocks.parse("## Plan ##\n#hashtag\n---\n> one\n> two")
        #expect(blocks == [
            .heading(level: 2, text: "Plan"),
            .paragraph("#hashtag"),
            .rule,
            .quote("one\ntwo"),
        ])
    }

    @Test func nestedTaskListWithContinuation() {
        let blocks = MarkdownBlocks.parse("""
        - [x] done
        - [ ] todo
          more detail
            - child
        - plain
        """)
        #expect(blocks == [.list(ordered: false, start: 1, items: [
            MarkdownListItem(text: "done", depth: 0, checked: true),
            MarkdownListItem(text: "todo\nmore detail", depth: 0, checked: false),
            MarkdownListItem(text: "child", depth: 1),
            MarkdownListItem(text: "plain", depth: 0),
        ])])
    }

    @Test func orderedListKeepsStartAndLooseItems() {
        let blocks = MarkdownBlocks.parse("3. three\n\n4) four\n\nafter")
        #expect(blocks == [
            .list(ordered: true, start: 3, items: [MarkdownListItem(text: "three"), MarkdownListItem(text: "four")]),
            .paragraph("after"),
        ])
    }

    @Test func switchingListKindStartsNewList() {
        let blocks = MarkdownBlocks.parse("- a\n1. b")
        #expect(blocks == [
            .list(ordered: false, start: 1, items: [MarkdownListItem(text: "a")]),
            .list(ordered: true, start: 1, items: [MarkdownListItem(text: "b")]),
        ])
    }

    @Test func paragraphLinesJoinAndBreakOnBlankLines() {
        #expect(MarkdownBlocks.parse("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
    }
}
