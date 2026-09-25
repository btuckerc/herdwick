import Testing
@testable import HerdrAPI

@Suite struct OmpEditorTests {
    private let status = "╭── \u{F0AA1} Opus 5.5   hearth ─────────────|────── 67.3 tok/s ──╮"

    @Test func emptyEditorHasNoDraft() {
        let screen = """
         10. They are herd animals and should never be kept alone.

        \(status)
        ╰─                                                          ─╯
        hearth
        """
        #expect(OmpEditor.draft(inScreen: screen) == nil)
    }

    @Test func draftSpansBoxRowsAndTheBottomBorder() {
        let screen = """
         Restored last queued message to editor

         Steering · 1
           1. PROBE3 line one
           └ Alt+Up/Shift+Up to edit

        \(status)
        │  draft line A                                              │
        │  line B                                                    │
        ╰─ line C                                                   ─╯
        hearth
        """
        #expect(OmpEditor.draft(inScreen: screen) == "draft line A\nline B\nline C")
        #expect(OmpEditor.draft(inScreen: "╭─╮\n╰─ PROBE4 second   ─╯") == "PROBE4 second")
    }

    @Test func screenWithoutEditorHasNoDraft() {
        #expect(OmpEditor.draft(inScreen: "$ ls\nREADME.md\n$ ") == nil)
    }
}
