import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import HerdwickSSH

@Suite struct SSHTimeoutTests {
    /// A peer that accepts TCP but never speaks SSH (a captive portal, a half-dead VPN)
    /// must fail within the handshake timeout instead of hanging the reconnect loop.
    @Test(.timeLimit(.minutes(1))) func silentPeerTimesOut() async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { _ in MultiThreadedEventLoopGroup.singleton.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)

        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await SSHConnection.connect(
                host: "127.0.0.1", port: port, username: "nobody", authentication: .none,
                hostKeyValidator: { _ in true }, timeout: .milliseconds(500)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
