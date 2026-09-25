import Foundation
import Testing
@testable import HerdrAPI

@Suite struct PaneProcessTests {
    @Test func decodesForegroundPipelineAndOptionalFields() throws {
        let json = #"{"pane_id":"w1:p1","shell_pid":42,"foreground_process_group_id":51,"tty":"/dev/pts/2","foreground_processes":[{"pid":51,"name":"bash","argv0":"-bash","argv":["-bash"],"cwd":"/repo"},{"pid":52,"name":"python3","argv0":"/usr/bin/python3","cmdline":"python3 server.py"}]}"#
        let info = try JSONDecoder().decode(PaneProcessInfo.self, from: Data(json.utf8))
        #expect(info.paneID == "w1:p1")
        #expect(info.shellPID == 42)
        #expect(info.foregroundProcessGroupID == 51)
        let processes = try #require(info.foregroundProcesses)
        #expect(processes.first(where: { !$0.isShell })?.command == "python3")
        #expect(processes[0].cwd == "/repo")
        let minimal = try JSONDecoder().decode(PaneProcessInfo.self, from: Data(#"{"pane_id":"w1:p2"}"#.utf8))
        #expect(minimal.foregroundProcesses == nil)
        #expect(minimal.shellPID == nil)
    }

    @Test(arguments: ["bash", "zsh", "fish", "sh", "dash", "nu", "ksh", "tcsh"])
    func recognizesShellPathsAndLoginShells(_ shell: String) {
        for executable in [shell, "-" + shell, "/bin/" + shell, "/usr/bin/-" + shell] {
            let process = PaneProcessInfoProcess(pid: 1, name: "untrusted-name", argv0: executable)
            #expect(process.isShell)
        }
    }

    @Test func nonShellAndMissingArgvUseConservativeFallback() {
        #expect(!PaneProcessInfoProcess(pid: 1, name: "bash", argv0: "/usr/bin/bashful").isShell)
        #expect(!PaneProcessInfoProcess(pid: 1, name: "vim", argv: ["vim", "file"]).isShell)
        #expect(PaneProcessInfoProcess(pid: 1, name: "zsh").isShell)
        #expect(!PaneProcessInfoProcess(pid: 1, name: "unknown").isShell)
    }
}
