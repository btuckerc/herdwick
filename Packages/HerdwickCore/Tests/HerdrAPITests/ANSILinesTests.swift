import Testing
@testable import HerdrAPI

@Suite struct ANSILinesTests {
    @Test func sgrColoursCarryAcrossLinesAndResets() {
        let lines = ANSILines.parse("\u{1B}[1;38;2;1;2;3mhi\r\nthere\u{1B}[0m ok\r\n\u{1B}[38;5;200;44mx\u{1B}[39mY\n")
        var bold = ANSIStyle(); bold.bold = true; bold.foreground = .rgb(1, 2, 3)
        var indexed = ANSIStyle(); indexed.foreground = .indexed(200); indexed.background = .indexed(4)
        var bgOnly = ANSIStyle(); bgOnly.background = .indexed(4)
        #expect(lines == [
            [ANSIRun(text: "hi", style: bold)],
            [ANSIRun(text: "there", style: bold), ANSIRun(text: " ok")],
            [ANSIRun(text: "x", style: indexed), ANSIRun(text: "Y", style: bgOnly)],
        ])
    }

    @Test func nonSGREscapesAreDroppedAndBlankLinesKept() {
        let lines = ANSILines.parse("a\u{1B}[2K\u{1B}]0;title\u{07}b\n\u{1B}[0m\nc")
        #expect(lines == [[ANSIRun(text: "ab")], [], [ANSIRun(text: "c")]])
    }
}
