import Foundation
import HerdrTestSupport
import Testing
@testable import HerdrAPI

@Test func attachmentUploadWritesLiteralPathsAndSweepsExpiredFiles() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let session = "a'b; $(touch injected)"
    let filename = "image ' name.jpg"
    let payload = Data([0, 1, 255, 10, 13])
    func upload() throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AttachmentUpload.command(session: session, filename: filename, retentionMinutes: 60)]
        process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": temporary.path]) { _, new in new }
        process.currentDirectoryURL = temporary
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let lines = String(decoding: response, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        let path = try #require(lines.first)
        #expect(Int(lines.last?.trimmingCharacters(in: .whitespaces) ?? "") == payload.count)
        return URL(fileURLWithPath: String(path))
    }
    let result = try upload()
    #expect(result.lastPathComponent == filename)
    #expect(result.deletingLastPathComponent().lastPathComponent == session)
    #expect(try Data(contentsOf: result) == payload)
    #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("injected").path))
    let old = result.deletingLastPathComponent().appendingPathComponent("old")
    let fresh = result.deletingLastPathComponent().appendingPathComponent("fresh")
    try payload.write(to: old)
    try payload.write(to: fresh)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
    _ = try upload()
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(try Data(contentsOf: fresh) == payload)
    #expect(!FileManager.default.fileExists(atPath: result.path + ".part"))
}

private struct TemporaryUploadRunner: CommandRunner {
    let directory: String
    func exec(_ command: String) async throws -> any ExecChannel {
        try await LocalProcessRunner().exec("export TMPDIR=\(shellQuote(directory)); " + command)
    }
}

@Test func attachmentUploadStreamsMultipleChunksAndRejectsTraversal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = TemporaryUploadRunner(directory: directory.path)
    let data = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
    let path = try await AttachmentUpload.upload(data, session: "session with spaces",
                                               filename: "binary.dat", retentionMinutes: 60, runner: runner)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    await #expect(throws: UploadError.self) {
        try await AttachmentUpload.upload(data, session: "../escape", filename: "binary.dat",
                                          retentionMinutes: 60, runner: runner)
    }
}
