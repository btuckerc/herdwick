import XCTest
@testable import HerdrAPI

final class ToolDetailTests: XCTestCase {
    func testOmpEditAndClaudeEdit() throws {
        let d = "{\"path\":\"Sources/A.swift\",\"diff\":\" 10|old\\n-11|gone\\n+11|new\\n\\n 20|keep\"}"
        guard case .edit(let files) = ToolDetail(name: "edit", arguments: nil, output: nil, details: d) else { return XCTFail() }
        XCTAssertEqual(files[0].path, "Sources/A.swift")
        XCTAssertEqual(files[0].lines.map(\.kind), [.context, .removed, .added, .gap, .context])
        XCTAssertEqual(files[0].lines[1].line, 11)
        let a = "{\"file_path\":\"a.txt\",\"old_string\":\"one\\ntwo\",\"new_string\":\"three\"}"
        guard case .edit(let edits) = ToolDetail(name: "Edit", arguments: a, output: nil, details: nil) else { return XCTFail() }
        XCTAssertEqual(edits[0].lines.map(\.kind), [.removed, .removed, .added])
    }

    /// Once the edit ran, Claude's structuredPatch gives the real hunks and line numbers.
    func testClaudeEditPrefersStructuredPatch() throws {
        let a = "{\"file_path\":\"a.txt\",\"old_string\":\"one\",\"new_string\":\"one\\ntwo\"}"
        let r = "{\"structuredPatch\":[{\"oldStart\":4,\"newStart\":4,\"lines\":[\" one\",\"+two\"]},{\"oldStart\":9,\"newStart\":10,\"lines\":[\"-x\",\"+y\",\"\\\\ No newline at end of file\"]}]}"
        guard case .edit(let files) = ToolDetail(name: "Edit", arguments: a, output: nil, details: r) else { return XCTFail() }
        XCTAssertEqual(files[0].lines.map(\.kind), [.context, .added, .gap, .removed, .added])
        XCTAssertEqual(files[0].lines.map(\.line), [4, 5, nil, 9, 10])
        XCTAssertEqual(files[0].added, 2); XCTAssertEqual(files[0].removed, 1)
    }

    func testCodexPatchCreatesFilesAndCounts() throws {
        let patch = "*** Begin Patch\n*** Update File: old.swift\n@@\n-old\n+new\n*** Add File: new.swift\n+hello\n+world\n*** End Patch"
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["input": patch]), as: UTF8.self)
        guard case .edit(let files) = ToolDetail(name: "apply_patch", arguments: args, output: nil, details: nil) else { return XCTFail() }
        XCTAssertEqual(files.map(\.path), ["old.swift", "new.swift"])
        XCTAssertEqual(files[0].added, 1); XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[1].change, .added); XCTAssertEqual(files[1].added, 2)
    }

    func testTodosShellAndClaudeBash() {
        let t = "{\"todos\":[{\"content\":\"one\",\"status\":\"pending\"},{\"content\":\"two\",\"status\":\"in_progress\"},{\"content\":\"three\",\"status\":\"completed\"}]}"
        guard case .todo(let items) = ToolDetail(name: "TodoWrite", arguments: t, output: nil, details: nil) else { return XCTFail() }
        XCTAssertEqual(items.map(\.state), [.pending, .active, .done])
        let plan = "{\"plan\":[{\"step\":\"ship\",\"status\":\"completed\"}]}"
        guard case .todo(let p) = ToolDetail(name: "update_plan", arguments: plan, output: nil, details: nil) else { return XCTFail() }
        XCTAssertEqual(p.first?.text, "ship"); XCTAssertEqual(p.first?.state, .done)
        let cmd = ToolDetail(name: "exec_command", arguments: "{\"cmd\":[\"bash\",\"-lc\",\"echo hi\"]}", output: "hi", details: "{\"exit_code\":0}")
        guard case .shell(let c, let o, let e) = cmd else { return XCTFail() }
        XCTAssertEqual(c, "echo hi"); XCTAssertEqual(o, "hi"); XCTAssertEqual(e, 0)
        guard case .shell(let bash, _, _) = ToolDetail(name: "Bash", arguments: "{\"command\":\"pwd\"}", output: nil, details: nil) else { return XCTFail() }
        XCTAssertEqual(bash, "pwd")
    }

    func testUnknownIsGeneric() {
        guard case .generic(let output) = ToolDetail(name: "future_tool", arguments: nil, output: "result", details: nil) else { return XCTFail() }
        XCTAssertEqual(output, "result")
    }
}
