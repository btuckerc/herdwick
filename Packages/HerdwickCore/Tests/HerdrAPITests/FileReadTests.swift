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
        if command.contains("remote-api-bridge") {
            return try await LocalProcessRunner().exec("read line; printf '%s\\n' " +
                shellQuote(#"{"result":{"process_info":{"foreground_processes":[{"pid":\#(pid)}]}}}"#))
        }
        return try await LocalProcessRunner().exec("export CLAUDE_CONFIG_DIR=\(shellQuote(shellDirectory)); " + command)
    }
}
