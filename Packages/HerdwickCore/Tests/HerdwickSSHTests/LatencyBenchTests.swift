import Foundation
import HerdrAPI
import Testing
@testable import HerdwickSSH

/// Connect-to-live timings through a relay that delays every byte by half an RTT, the way a
/// phone on a tailnet sees a host. Read-only against herdr session `main`.
/// `HERDWICK_BENCH=1 [HERDWICK_BENCH_RTT_MS=100] swift test --filter LatencyBench`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDWICK_BENCH"] == "1"), .serialized)
final class LatencyBenchTests {
    let server: LocalSSHD
    let clientKey = SSHKeys.generate()
    let rtt = Double(ProcessInfo.processInfo.environment["HERDWICK_BENCH_RTT_MS"] ?? "100")! / 1000

    init() throws {
        server = try LocalSSHD(authorizedKey: SSHKeys.publicKeyLine(for: clientKey, comment: "herdwick-bench"))
    }

    deinit { server.stop() }

    private func dial() async throws -> SSHConnection {
        let fd = try DelayedRelay.start(toLocalPort: server.port, oneWay: rtt / 2)
        return try await SSHConnection.connect(
            adoptingConnectedSocket: fd, username: NSUserName(),
            authentication: .ed25519(clientKey), hostKeyValidator: { _ in true }
        )
    }

    private func report(_ label: String, _ start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "BENCH %-34@ %6.0f ms  %5.1f RTT", label as NSString, seconds * 1000, seconds / rtt))
    }

    /// `first run`: nothing cached. `relaunch`: the app's later launches, with the herdr path and
    /// the on-screen panes (the subscription hint) remembered from the first run.
    @Test func connectToLive() async throws {
        var herdr = ProcessInfo.processInfo.environment["HERDWICK_BENCH_HERDR"]
        var hint: Set<String>?
        for round in ["first run", "relaunch"] {
            let start = ContinuousClock.now
            let ssh = try await dial()
            report("\(round) ssh handshake", start)
            let client = HerdrClient(runner: ssh, herdrPath: herdr)
            herdr = try await client.resolveHerdrPath()
            report("\(round) herdr path", start)
            async let sessions = client.sessions()
            var preview = false
            for try await update in client.mirror(session: "main", panes: hint) {
                if case .preview = update, !preview { preview = true; report("\(round) first preview", start) }
                if case .live(let snapshot) = update {
                    hint = Set(snapshot.panes.map(\.id))
                    break
                }
            }
            report("\(round) live", start)
            _ = try await sessions
            let one = ContinuousClock.now
            _ = try await client.snapshot(session: "main")
            report("\(round) one snapshot request", one)
            await ssh.close()
        }
    }
}

/// One end of an AF_UNIX socketpair relayed to 127.0.0.1:port, each byte delivered `oneWay`
/// seconds after it was read, in order.
enum DelayedRelay {
    static func start(toLocalPort port: Int, oneWay: Double) throws -> CInt {
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
        for (from, to) in [(pair[1], tcp), (tcp, pair[1])] {
            let queue = DelayQueue()
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
                    guard n > 0 else { break }
                    queue.put(Array(buffer[0..<n]), at: Date().addingTimeInterval(oneWay))
                }
                queue.put(nil, at: Date().addingTimeInterval(oneWay))
            }
            Thread.detachNewThread {
                while let (bytes, due) = queue.take() {
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    guard let bytes else { break }
                    guard bytes.withUnsafeBytes({ write(to, $0.baseAddress, bytes.count) }) == bytes.count else { break }
                }
                shutdown(to, CInt(SHUT_WR))
            }
        }
        return pair[0]
    }
}

private final class DelayQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [([UInt8]?, Date)] = []

    func put(_ bytes: [UInt8]?, at due: Date) {
        condition.lock()
        items.append((bytes, due))
        condition.signal()
        condition.unlock()
    }

    func take() -> ([UInt8]?, Date)? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty { condition.wait() }
        return items.removeFirst()
    }
}
