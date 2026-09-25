import Crypto
import Foundation
import HerdrAPI
import Testing
@testable import HerdwickSSH

/// Real OpenSSH round trips against a private, unprivileged `sshd` on 127.0.0.1.
/// `HERDWICK_SSH_LIVE=1 swift test`. Leaves `~/.ssh` untouched.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDWICK_SSH_LIVE"] == "1"), .serialized)
final class SSHConnectionLiveTests {
    let server: LocalSSHD
    let clientKey = SSHKeys.generate()

    init() throws {
        server = try LocalSSHD(authorizedKey: SSHKeys.publicKeyLine(for: clientKey, comment: "herdwick-test"))
    }

    deinit { server.stop() }

    private func connect(
        key: Curve25519.Signing.PrivateKey? = nil,
        validator: @escaping HostKeyValidator = { _ in true }
    ) async throws -> SSHConnection {
        try await SSHConnection.connect(
            host: "localhost", port: server.port, username: NSUserName(),
            authentication: .ed25519(key ?? clientKey), hostKeyValidator: validator
        )
    }

    @Test func execStreamsStdoutAndReportsFailure() async throws {
        let ssh = try await connect()
        let exec = try await ssh.exec("printf hello; echo oops >&2; exit 3")
        var out: [UInt8] = []
        await #expect(throws: CommandError.exited(status: 3, stderr: "oops\n")) {
            for try await chunk in exec.output { out += chunk }
        }
        #expect(String(decoding: out, as: UTF8.self) == "hello")
        await ssh.close()
    }

    @Test func stdinRoundTripsUntilEOF() async throws {
        let ssh = try await connect()
        let exec = try await ssh.exec("cat")
        try await exec.write(Array("one\ntwo\n".utf8))
        try await exec.closeInput()
        var out: [UInt8] = []
        for try await chunk in exec.output { out += chunk }
        #expect(String(decoding: out, as: UTF8.self) == "one\ntwo\n")
        try await ssh.ping()
        await ssh.close()
    }

    /// A command that exits before the client sends EOF (a quick read over a slow link):
    /// the late half-close must not fail the read.
    @Test func closeInputAfterCommandExitedKeepsItsOutput() async throws {
        let ssh = try await connect()
        let exec = try await ssh.exec("printf done")
        try await Task.sleep(for: .milliseconds(300))
        try await exec.closeInput()
        var out: [UInt8] = []
        for try await chunk in exec.output { out += chunk }
        #expect(String(decoding: out, as: UTF8.self) == "done")
        await ssh.close()
    }

    /// A photo is megabytes: far past the SSH channel window, so writes must wait for window adjusts.
    @Test func uploadsMultiMegabyteAttachment() async throws {
        let ssh = try await connect()
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let session = "herdwick-live-\(UUID().uuidString)"
        let path = try await AttachmentUpload.upload(data, session: session, filename: "photo.jpeg", retentionMinutes: 60, runner: ssh)
        #expect(FileManager.default.contents(atPath: path) == data)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        await ssh.close()
    }

    @Test func hostKeyMismatchIsRejectedWithItsFingerprint() async throws {
        await #expect(throws: SSHError.hostKeyRejected(fingerprint: server.hostKeyFingerprint)) {
            _ = try await self.connect(validator: { _ in false })
        }
    }

    @Test func hostKeyPresentedMatchesServer() async throws {
        let seen = Seen()
        let ssh = try await connect(validator: { seen.key = $0; return true })
        #expect(seen.key?.fingerprint == server.hostKeyFingerprint)
        await ssh.close()
    }

    @Test func unknownClientKeyFailsAuthentication() async throws {
        await #expect(throws: SSHError.authenticationFailed) {
            _ = try await self.connect(key: SSHKeys.generate())
        }
    }

    @Test func closeWakesWaiters() async throws {
        let ssh = try await connect()
        async let closed: Void = ssh.waitUntilClosed()
        await ssh.close()
        await closed
        #expect(!ssh.isActive)
    }

    /// The production path end to end: herdr's bridge over SSH, read-only against `main`.
    @Test func herdrPingOverSSH() async throws {
        let client = HerdrClient(runner: try await connect())
        let pong = try await client.ping(session: "main")
        #expect(pong.protocolVersion >= 22)
        #expect(try await !client.snapshot(session: "main").workspaces.isEmpty)
    }

    /// The Tailscale path: `tailscale_dial` hands back one end of a Unix socketpair
    /// that tsnet relays to the peer. Emulated here with threads relaying to sshd.
    @Test func adoptsSocketpairLikeTailscaleDial() async throws {
        let fd = try SocketpairRelay.start(toLocalPort: server.port)
        let ssh = try await SSHConnection.connect(
            adoptingConnectedSocket: fd, username: NSUserName(),
            authentication: .ed25519(clientKey), hostKeyValidator: { _ in true }
        )
        let exec = try await ssh.exec("echo adopted")
        var out: [UInt8] = []
        for try await chunk in exec.output { out += chunk }
        #expect(String(decoding: out, as: UTF8.self) == "adopted\n")
        try await ssh.ping()
        await ssh.close()
    }
}

private final class Seen: @unchecked Sendable { var key: SSHHostKey? }

/// One end of an AF_UNIX socketpair, relayed byte for byte to 127.0.0.1:port.
enum SocketpairRelay {
    static func start(toLocalPort port: Int) throws -> CInt {
        var pair: [CInt] = [0, 0]
        guard socketpair(AF_UNIX, CInt(SOCK_STREAM.rawValue), 0, &pair) == 0 else { throw SSHError.connectionClosed }
        let tcp = socket(AF_INET, CInt(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw SSHError.connectionClosed }
        let far = pair[1]
        for (from, to) in [(far, tcp), (tcp, far)] {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
                    guard n > 0, buffer.withUnsafeBytes({ write(to, $0.baseAddress, n) }) == n else { break }
                }
                shutdown(to, CInt(SHUT_WR))
            }
        }
        return pair[0]
    }
}

/// A throwaway daemonised `sshd` owned by the current user, with its own host key and authorized_keys.
final class LocalSSHD: @unchecked Sendable {
    let port: Int
    let hostKeyFingerprint: String
    private let dir: URL
    private var pid: pid_t = 0

    init(authorizedKey: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-sshd-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostKey = dir.appendingPathComponent("host_ed25519").path
        _ = try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        hostKeyFingerprint = String(try Self.run("/usr/bin/ssh-keygen", ["-lf", hostKey + ".pub"]).split(separator: " ")[1])
        try (authorizedKey + "\n").write(to: dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        port = Int.random(in: 40000...50000)
        let config = """
            ListenAddress 127.0.0.1:\(port)
            HostKey \(hostKey)
            AuthorizedKeysFile \(dir.path)/authorized_keys
            PidFile \(dir.path)/sshd.pid
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            """
        let configPath = dir.appendingPathComponent("sshd_config").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        // Daemon mode with null stdio: the launcher exits once sshd listens, and the daemon
        // holds no pipe of ours open.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        launcher.arguments = ["-f", configPath]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
        launcher.waitUntilExit()
        for _ in 0..<50 {
            if let text = try? String(contentsOfFile: dir.path + "/sshd.pid", encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop()
        throw SSHError.connectionClosed
    }

    func stop() {
        if pid > 0 { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
