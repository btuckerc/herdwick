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

    /// With the only session slot occupied, an unnecessary probe would drop the transport.
    @Test(.timeLimit(.minutes(1))) func inboundTrafficDefersKeepalive() async throws {
        let server = try LocalSSHD(authorizedKey: SSHKeys.publicKeyLine(for: clientKey, comment: "herdwick-test"), maxSessions: 1)
        defer { server.stop() }
        let ssh = try await SSHConnection.connect(
            host: "localhost", port: server.port, username: NSUserName(),
            authentication: .ed25519(clientKey), hostKeyValidator: { _ in true },
            keepaliveInterval: .milliseconds(500)
        )
        let exec = try await ssh.exec("cat")
        var output = exec.output.makeAsyncIterator()
        for _ in 0..<30 {
            try await exec.write([120])
            #expect(try await output.next() == [120])
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ssh.isActive)
        // Once traffic stops, the idle probe hits MaxSessions and closes the transport.
        try await Task.sleep(for: .seconds(1))
        #expect(!ssh.isActive)
        await exec.close()
        await ssh.close()
    }

    /// Freeze the peer after auth, then cancel opens before it can acknowledge them.
    @Test(.timeLimit(.minutes(1))) func cancelledOpensAndTimedOutProbesReleaseLateChannels() async throws {
        let ssh = try await SSHConnection.connect(
            host: "localhost", port: server.port, username: NSUserName(),
            authentication: .ed25519(clientKey), hostKeyValidator: { _ in true },
            keepaliveInterval: nil
        )
        let identify = try await ssh.exec("printf '%s' \"$PPID\"")
        var bytes: [UInt8] = []
        for try await chunk in identify.output { bytes += chunk }
        let pid = try #require(pid_t(String(decoding: bytes, as: UTF8.self)))
        let blocked = try await ssh.exec("cat")
        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("herdwick-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let write = Task { try await blocked.write(Array(repeating: 120, count: 8 * 1024 * 1024)) }
        try await Task.sleep(for: .milliseconds(50))
        let eof = Task { try await blocked.closeInput() }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        await blocked.close()
        write.cancel()
        eof.cancel()
        await #expect(throws: CancellationError.self) { try await write.value }
        await #expect(throws: CancellationError.self) { try await eof.value }
        #expect(ContinuousClock.now - start < .seconds(1))
        for _ in 0..<12 {
            let pending = Task { try await ssh.exec("touch '\(marker.path)'") }
            try await Task.sleep(for: .milliseconds(30))
            let start = ContinuousClock.now
            pending.cancel()
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
            #expect(ContinuousClock.now - start < .seconds(1))
            await #expect(throws: SSHError.keepaliveTimeout) {
                try await ssh.ping(timeout: .milliseconds(20))
            }
        }
        #expect(kill(pid, SIGCONT) == 0)
        // Drain late open replies and their closes before proving all session slots are free.
        var drained = false
        for _ in 0..<50 {
            do {
                try await ssh.ping()
                drained = true
                break
            } catch {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(drained)
        let exec = try await ssh.exec("printf recovered")
        var recovered: [UInt8] = []
        for try await chunk in exec.output { recovered += chunk }
        #expect(String(decoding: recovered, as: UTF8.self) == "recovered")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await ssh.close()
    }

    @Test(.timeLimit(.minutes(1))) func cancellingOutputConsumerClosesRemoteCommand() async throws {
        let ssh = try await connect()
        let exec = try await ssh.exec("echo $$; exec cat")
        let (pids, continuation) = AsyncStream<pid_t>.makeStream()
        let consumer = Task {
            var bytes: [UInt8] = []
            for try await chunk in exec.output {
                bytes += chunk
                if let newline = bytes.firstIndex(of: 10),
                   let pid = pid_t(String(decoding: bytes[..<newline], as: UTF8.self)) {
                    continuation.yield(pid)
                    continuation.finish()
                }
            }
        }
        var iterator = pids.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        #expect(kill(pid, 0) == 0)
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await ssh.close()
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

    init(authorizedKey: String, maxSessions: Int = 10) throws {
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
            MaxSessions \(maxSessions)
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
