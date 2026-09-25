import Foundation
import HerdrAPI
import Testing

private let blob = String(repeating: "A", count: 68)
private let invalidLines: [String] = [
    "ssh-rsa \(blob) comment",
    "ssh-ed25519 \(blob) bad comment",
    "ssh-ed25519 \(blob) \(String(repeating: "a", count: 65))",
    "ssh-ed25519 \(blob) 'comment'",
    "ssh-ed25519 \(blob) comment\nextra",
]

struct AuthorizedKeyInstallTests {
    let line = "ssh-ed25519 \(blob) comment"

    @Test func installsAndIsIdempotent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try run(AuthorizedKeyInstall.script(for: line), home: home) == "installed\n")
        let directory = home.appendingPathComponent(".ssh")
        let file = directory.appendingPathComponent("authorized_keys")
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber == 0o600)
        #expect(try String(contentsOf: file) == line + "\n")
        #expect(try run(AuthorizedKeyInstall.script(for: line), home: home) == "present\n")
        #expect(try String(contentsOf: file) == line + "\n")
    }

    @Test func addsSeparatorToFileWithoutNewline() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: directory.appendingPathComponent("authorized_keys"))
        #expect(try run(AuthorizedKeyInstall.script(for: line), home: home) == "installed\n")
        #expect(try String(contentsOf: directory.appendingPathComponent("authorized_keys")) == "existing\n" + line + "\n")
    }

    @Test(arguments: invalidLines)
    func rejectsInvalidLine(_ value: String) {
        #expect(throws: AuthorizedKeyInstallError.invalidKeyLine) { try AuthorizedKeyInstall.script(for: value) }
    }

    @Test func refusesSymlinkAndRemovalIsExact() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("target")
        try Data("untouched\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("authorized_keys"), withDestinationURL: target)
        #expect(throws: ProcessFailure.self) { try run(AuthorizedKeyInstall.script(for: line), home: home) }
        #expect(try String(contentsOf: target) == "untouched\n")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("authorized_keys"))
        try Data((line + "\nother\n").utf8).write(to: directory.appendingPathComponent("authorized_keys"))
        try run(AuthorizedKeyInstall.removalScript(for: line), home: home)
        #expect(try String(contentsOf: directory.appendingPathComponent("authorized_keys")) == "other\n")
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ script: String, home: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ProcessFailure() }
        return text
    }
}

private struct ProcessFailure: Error {}
