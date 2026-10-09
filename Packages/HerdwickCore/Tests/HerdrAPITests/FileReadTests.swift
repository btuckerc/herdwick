import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

@Suite struct FileReadTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    #if os(Linux)
    @Test func transcriptDiscoveryPrefersAgentDirectoryAndPreservesSpaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent config")
        let shell = root.appendingPathComponent("shell config")
        for directory in [agent, shell] {
            let project = directory.appendingPathComponent("projects/project space")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data().write(to: project.appendingPathComponent("session-id.jsonl"))
        }
        let shellOnly = shell.appendingPathComponent("projects/project space/shell-only.jsonl")
        try Data().write(to: shellOnly)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.environment = ["CLAUDE_CONFIG_DIR": agent.path]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let client = HerdrClient(runner: DiscoveryRunner(pid: process.processIdentifier, shellDirectory: shell.path), herdrPath: "/herdr")
        let ref = AgentSessionRef(source: "test", agent: "claude", kind: "id", value: "session-id")
        let location = try await client.locateTranscript(ref, pane: "pane", session: "test")
        #expect(location?.path == agent.appendingPathComponent("projects/project space/session-id.jsonl").path)
        // One host command for several panes, each resolved on its own: the agent's directory,
        // the shell's, or nothing.
        func claude(_ id: String) -> AgentSessionRef { AgentSessionRef(source: "test", agent: "claude", kind: "id", value: id) }
        let batch = try await client.locateTranscripts([("a", ref), ("b", claude("shell-only")), ("c", claude("absent"))], session: "test")
        #expect(batch == [
            "a": TranscriptLocation(path: agent.appendingPathComponent("projects/project space/session-id.jsonl").path, format: .claude),
            "b": TranscriptLocation(path: shellOnly.path, format: .claude),
        ])
    }
    #endif

    @Test func readsBinaryBytesExactlyAndRefusesLargeOrMissingFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("read \(UUID().uuidString) it's.png")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<4096).map { UInt8($0 % 256) } + [0x0A, 0x00, 0x0D])
        try bytes.write(to: file)

        #expect(try await client.readFile(path: file.path) == bytes)
        let large = await #expect(throws: FileTooLarge.self) { try await client.readFile(path: file.path, maxBytes: 100) }
        #expect(large?.bytes == bytes.count)
        let missing = await #expect(throws: FileUnreadable.self) { try await client.readFile(path: "/no/such/image.png") }
        #expect(missing?.path == "/no/such/image.png")
    }
}

private struct DiscoveryRunner: CommandRunner {
    let pid: Int32
    let shellDirectory: String
    func exec(_ command: String) async throws -> any ExecChannel {
        if command.contains("HERDWICK_REQUEST") {
            // A request lane on a host without perl: the request in the command line is asked
            // for again, then each is answered with its own id and the status line.
            let reply = #"{"id":"%s","result":{"process_info":{"foreground_processes":[{"pid":\#(pid)}]}}}\n\036%s\n"#
            return try await LocalProcessRunner().exec("printf '\\036r\\n'; while IFS= read -r r; do id=${r#*\\\"id\\\":\\\"}; printf "
                + shellQuote(reply) + " \"${id%%\\\"*}\" 0; done")
        }
        return try await LocalProcessRunner().exec("export CLAUDE_CONFIG_DIR=\(shellQuote(shellDirectory)); " + command)
    }
}
