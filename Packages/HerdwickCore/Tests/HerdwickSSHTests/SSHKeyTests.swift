import Crypto
import Foundation
import Testing
@testable import HerdwickSSH

@Suite struct SSHKeyTests {
    /// Round-trips a key through real `ssh-keygen` output: parse, public line, fingerprint.
    @Test func matchesOpenSSH() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", keyPath])

        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        let key = try SSHKeys.parseOpenSSHPrivateKey(pem)
        let expectedPublic = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(SSHKeys.publicKeyLine(for: key, comment: "test") == expectedPublic)

        let fingerprint = try run("/usr/bin/ssh-keygen", ["-lf", keyPath + ".pub"]).split(separator: " ")[1]
        #expect(SSHKeys.fingerprint(ofPublicKeyLine: expectedPublic) == String(fingerprint))
    }

    @Test func rejectsEncryptedKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "secret", "-f", keyPath])
        #expect(throws: SSHError.self) {
            try SSHKeys.parseOpenSSHPrivateKey(try String(contentsOfFile: keyPath, encoding: .utf8))
        }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
