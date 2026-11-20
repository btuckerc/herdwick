import Foundation
import HerdrAPI
import Synchronization
import TailscaleKit

/// The app's own Tailscale node (TailscaleKit / tsnet). It joins the user's tailnet as a
/// device called "herdwick-…", with no VPN profile or system extension, and dials peers
/// in-process. The node persists its state, so sign-in happens once.
@MainActor @Observable
final class Tailnet {
    enum State: Equatable {
        case off
        case starting
        /// Waiting for the user to approve this device in the browser.
        case needsLogin(URL?)
        case running
        case failed(String)
    }

    struct Peer: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var dnsName: String
        var address: String
        var online: Bool
        var sshHostKeys: [String]
    }

    private(set) var state: State = .off
    private(set) var peers: [Peer] = []
    private(set) var tailnetName: String?
    private var node: TailscaleNode?
    private var handle: TailscaleHandle?
    /// The node being created; every caller shares it, so a cold launch makes one node.
    private var starting: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    /// A rebind in flight after a suspension or a route change; dials wait for it, up to
    /// `recoveryBound`. `recoveryID` tells a newer one from an abandoned one.
    private var recovery: Task<Void, Never>?
    private var recoveryStarted: ContinuousClock.Instant?
    private var recoveryID = 0
    /// When the last rebind finished; the first dial after one pings its peer first.
    private var recoveredAt: ContinuousClock.Instant?
    /// Dials that failed in a row while their peer was online; see `noteDialFailure`.
    private var dialFailures = 0
    private var restartedAt: ContinuousClock.Instant?
    /// Whether a live link rides this node; set by `AppModel`. A node that serves one isn't broken.
    var carriesLiveLink: () -> Bool = { false }

    /// True once this device has signed in before; the node then comes up by itself.
    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: Self.stateDirectory.appendingPathComponent("tailscaled.state").path)
    }

    static var stateDirectory: URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }

    /// Starts the node if needed and follows its state until it is running.
    func start(controlURL: String = kDefaultControlURL) {
        guard node == nil else {
            refreshSoon()
            return
        }
        guard starting == nil else { return }
        state = .starting
        let config = Configuration(
            hostName: "herdwick-\(UIDeviceName.short)",
            path: Self.stateDirectory.path,
            authKey: nil,
            controlURL: controlURL,
            ephemeral: false
        )
        starting = Task {
            do {
                // tailscale_start blocks: off the cooperative pool, as `dial` explains.
                let node = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try TailscaleNode(config: config, logger: nil) })
                    }
                }
                guard !Task.isCancelled else {
                    // Signed out meanwhile.
                    try? await node.close()
                    return
                }
                self.node = node
                self.handle = await node.tailscale
                self.refreshSoon()
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed("Tailscale could not start: \(error)")
            }
            self.starting = nil
        }
    }

    /// Asks the node for a fresh login URL; used when the first one expired.
    func restartLogin() async {
        guard let node else { return }
        let api = LocalAPIClient(localNode: node, logger: nil)
        try? await api.startLoginInteractive()
        refreshSoon()
    }

    /// Forgets this device's tailnet identity. The stale device stays listed in the
    /// Tailscale admin console until it expires or is removed there.
    func signOut() async {
        starting?.cancel()
        starting = nil
        poll?.cancel()
        try? await node?.close()
        node = nil
        handle = nil
        recovery = nil
        recoveryStarted = nil
        recoveredAt = nil
        dialFailures = 0
        peers = []
        tailnetName = nil
        try? FileManager.default.removeItem(at: Self.stateDirectory)
        state = .off
    }

    /// Rebinds the node's sockets and forgets the peer paths it trusted, as a network change
    /// does. For a process back from suspension (iOS may have reclaimed its UDP and DERP
    /// sockets) or a new route. Without it the first dial after a resume can sit through
    /// WireGuard handshake retries (5 s each) until magicsock notices by itself. Callers share
    /// the one in flight; dials wait for it.
    func recover() {
        guard let node else { return }
        guard state == .running else {
            // The state may be from before a suspension: look again.
            if state == .starting { refreshSoon() }
            return
        }
        if recovery != nil {
            guard recoveryIsStuck else { return }
            abandonRecovery()
        }
        recoveryID += 1
        let id = recoveryID
        recoveryStarted = .now
        recovery = Task {
            let start = ContinuousClock.now
            var rebound = false
            do {
                try await node.rebind()
                rebound = true
                ConnectTrace.note("tailnet rebind \(ContinuousClock.now - start)")
            } catch {
                ConnectTrace.note("tailnet rebind failed: \(error)")
            }
            // Signed out, restarted or abandoned meanwhile: this result is stale.
            guard self.node === node, self.recoveryID == id else { return }
            // Only a rebind that worked gave the peers fresh paths worth a ping.
            self.recoveredAt = rebound ? .now : nil
            self.recovery = nil
            self.recoveryStarted = nil
            // The backend may have changed state while the process was suspended.
            self.refreshSoon()
        }
    }

    /// The Go side bounds a rebind at 5 s, but nothing here enforced it: one that never
    /// returned held every dial to its full budget and blocked any later rebind until relaunch.
    private static let recoveryBound: Duration = .seconds(6)

    private var recoveryIsStuck: Bool {
        recoveryStarted.map { ContinuousClock.now - $0 > Self.recoveryBound } ?? false
    }

    private func abandonRecovery() {
        ConnectTrace.note("tailnet rebind stuck, abandoned")
        recovery = nil
        recoveryStarted = nil
        recoveredAt = nil
    }

    /// Polls the in-memory status (it survives iOS suspension, unlike the loopback API)
    /// until the node is running, then once more whenever asked.
    func refreshSoon() {
        poll?.cancel()
        poll = Task {
            var askedForLogin = false
            var waited = Duration.zero
            while waited < .seconds(600), !Task.isCancelled {
                if let status = await status() {
                    apply(status)
                    switch status.BackendState {
                    case "Running":
                        return
                    case "NeedsLogin" where status.AuthURL.isEmpty && !askedForLogin && waited >= .seconds(3):
                        askedForLogin = true
                        await restartLogin()
                        return
                    default:
                        break
                    }
                }
                // Connecting waits on `Running`, so look often while the node comes up (it
                // usually does within a second or two); a sign-in in the browser takes a while.
                let interval: Duration = if case .needsLogin = state { .seconds(1) }
                    else if waited < .seconds(5) { .milliseconds(50) } else { .milliseconds(250) }
                try? await Task.sleep(for: interval)
                waited += interval
            }
        }
    }

    private func status() async -> IpnState.Status? {
        guard let node, let data = try? await node.statusJSON() else { return nil }
        return try? JSONDecoder().decode(IpnState.Status.self, from: data)
    }

    /// Assigns only what changed: the poll runs every 50 ms while the node comes up, and every
    /// assignment, equal or not, invalidates the views that read it.
    private func apply(_ status: IpnState.Status) {
        let name = status.CurrentTailnet?.Name
        if tailnetName != name { tailnetName = name }
        let next: State = switch status.BackendState {
        case "Running": .running
        case "NeedsLogin", "NeedsMachineAuth": .needsLogin(URL(string: status.AuthURL))
        default: if case .needsLogin = state { state } else { .starting }
        }
        if state != next { state = next }
        let list = (status.Peer ?? [:]).values.compactMap { peer -> Peer? in
            guard let address = peer.TailscaleIPs?.first(where: { !$0.contains(":") }) ?? peer.TailscaleIPs?.first else {
                return nil
            }
            let dns = peer.DNSName.hasSuffix(".") ? String(peer.DNSName.dropLast()) : peer.DNSName
            return Peer(
                id: peer.ID, name: peer.HostName, dnsName: dns, address: address,
                online: peer.Online, sshHostKeys: peer.SSH_HostKeys ?? []
            )
        }
        .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
        if peers != list { peers = list }
    }

    func peer(id: String) -> Peer? {
        peers.first { $0.id == id }
    }

    /// Shows fixed machines without starting a node; used only by the demo captures.
    func showDemo(name: String, peers: [Peer]) {
        tailnetName = name
        self.peers = peers
        state = .running
    }

    /// A connected TCP socket to `port` on the peer `nodeID` (at `address` if the node no longer
    /// lists it), which the caller owns. One 15 s budget covers the node coming up, any
    /// recovery in flight and the dial. Right after a rebind the peer gets a disco ping (1 s at
    /// most) so the dial finds a fresh path instead of retrying handshakes on a stale one.
    func connect(to nodeID: String, address: String, port: Int) async throws -> (fd: CInt, peer: Peer?) {
        do {
            let result = try await dial(nodeID: nodeID, address: address, port: port)
            dialFailures = 0
            return result
        } catch {
            noteDialFailure(error, nodeID: nodeID)
            throw error
        }
    }

    private func dial(nodeID: String, address: String, port: Int) async throws -> (fd: CInt, peer: Peer?) {
        let deadline = ContinuousClock.now + .seconds(15)
        var handle = try await readyHandle(by: deadline)
        let peer = peer(id: nodeID)
        let target = peer?.address ?? address
        if let recoveredAt, ContinuousClock.now - recoveredAt < .seconds(10), let node {
            self.recoveredAt = nil
            // Leaves the dial at least 3 s of the budget.
            let budget = min(.seconds(1), deadline - ContinuousClock.now - .seconds(3))
            if budget > .zero {
                let start = ContinuousClock.now
                do {
                    // Abandoned, not awaited, should the blocking call overrun its own bound.
                    try await withTimeout(budget + .milliseconds(500)) { try await node.ping(target, timeout: budget) }
                    ConnectTrace.note("tailnet ping \(ContinuousClock.now - start)")
                } catch {
                    ConnectTrace.note("tailnet ping failed after \(ContinuousClock.now - start)")
                }
            }
            // The node may have gone, or begun another recovery, while the ping ran.
            handle = try await readyHandle(by: deadline)
        }
        let ready = handle
        do {
            let fd = try await withTimeout(deadline - ContinuousClock.now) {
                try await Self.dial(address: target, port: port, handle: ready, by: deadline)
            }
            return (fd, peer)
        } catch {
            // `state` stops following the backend once it runs; it may have left Running since
            // (signed out, say). Look again, so the next attempt sees that.
            if !(error is CancellationError), self.handle == ready { refreshSoon() }
            throw error
        }
    }

    /// A node back from suspension can stay broken in ways one rebind doesn't fix (a dead DERP
    /// or control connection), so every dial runs out its budget until the app is relaunched.
    /// Dials failing in a row while the peer is online escalate: the second rebinds again, the
    /// third replaces the node. Cancelled dials, sign-out and an offline peer don't count, and a
    /// refused dial proves the node works.
    private func noteDialFailure(_ error: any Error, nodeID: String) {
        if error is CancellationError { return }
        if let error = error as? TailnetError, case .refused = error {
            dialFailures = 0
            return
        }
        if let error = error as? TailnetError, case .signedOut = error { return }
        if peer(id: nodeID)?.online == false { return }
        dialFailures += 1
        ConnectTrace.note("tailnet dial failed (\(dialFailures) in a row)")
        if dialFailures == 2 {
            recover()
        } else if dialFailures >= 3 {
            restart(reason: "\(dialFailures) failed dials")
        }
    }

    /// Replaces the node with a fresh one on the same state, as a relaunch would; no sign-in.
    /// At most every 2 minutes, and never while a live link rides the node. The old node must
    /// close first (5 s at most): two nodes on one state could fight over it, so one that
    /// won't close is kept.
    private func restart(reason: String) {
        guard let old = node, starting == nil, !carriesLiveLink() else { return }
        if let restartedAt, ContinuousClock.now - restartedAt < .seconds(120) { return }
        restartedAt = .now
        dialFailures = 0
        ConnectTrace.note("tailnet restart: \(reason)")
        let oldHandle = handle
        poll?.cancel()
        recovery = nil
        recoveryStarted = nil
        recoveredAt = nil
        node = nil
        handle = nil
        state = .starting
        starting = Task {
            let closed = (try? await withTimeout(.seconds(5)) { try await old.close(); return true }) ?? false
            // Signed out meanwhile: that owns the node now.
            guard !Task.isCancelled else { return }
            self.starting = nil
            if closed {
                ConnectTrace.note("tailnet restart: old node closed")
                self.start()
            } else {
                ConnectTrace.note("tailnet restart: old node did not close, kept")
                self.node = old
                self.handle = oldHandle
                self.refreshSoon()
            }
        }
    }

    /// `tailscale_dial_timeout` blocks for up to the time left, so it runs on a GCD thread:
    /// Swift's cooperative pool has one thread per core, and a few dials stuck there stopped
    /// every task in the app, timeouts included, until it was relaunched. Cancelling returns at
    /// once, a dial that hasn't begun by then never does, and a socket that arrives later is closed.
    nonisolated private static func dial(address: String, port: Int, handle: TailscaleHandle,
                                         by deadline: ContinuousClock.Instant) async throws -> CInt {
        let pending = PendingDial()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.wait(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    pending.finish(Result {
                        let left = deadline - ContinuousClock.now
                        guard !pending.isCancelled, left > .zero else { throw TimeoutError() }
                        let millis = CInt(clamping: left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)
                        var conn: tailscale_conn = 0
                        let target = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
                        guard tailscale_dial_timeout(handle, "tcp", target, max(1, millis), &conn) == 0 else {
                            var buffer = [CChar](repeating: 0, count: 512)
                            tailscale_errmsg(handle, &buffer, buffer.count)
                            let message = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            // The peer answered with a reset: nothing listens on that port.
                            if message.localizedCaseInsensitiveContains("refused") { throw TailnetError.refused }
                            throw TailnetError.dialFailed(message)
                        }
                        return conn
                    })
                }
            }
        } onCancel: {
            pending.cancel()
        }
    }

    /// The node handle once it runs and any recovery has finished; throws if that takes past `deadline`.
    private func readyHandle(by deadline: ContinuousClock.Instant) async throws -> TailscaleHandle {
        if node == nil { start() } else if state == .starting { refreshSoon() }
        do {
            _ = try await withTimeout(deadline - ContinuousClock.now) { @MainActor in
                for await state in Observations({ @MainActor in self.state }) {
                    switch state {
                    case .running:
                        if let handle = self.handle { return handle }
                    case .needsLogin:
                        throw TailnetError.signedOut
                    case .failed(let message):
                        throw TailnetError.dialFailed(message)
                    case .off, .starting:
                        break
                    }
                }
                throw TailnetError.notRunning
            }
            // Polled rather than awaited: a task's value can't be abandoned at the deadline.
            while recovery != nil {
                guard ContinuousClock.now < deadline else { throw TailnetError.notRunning }
                if recoveryIsStuck {
                    abandonRecovery()
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard state == .running, let current = self.handle else { throw TailnetError.notRunning }
            return current
        } catch is TimeoutError {
            throw TailnetError.notRunning
        }
    }
}

enum TailnetError: LocalizedError {
    case notRunning, signedOut
    /// The peer is reachable but nothing accepts connections on the port.
    case refused
    case dialFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Tailscale is still starting."
        case .signedOut: "Sign in to Tailscale again."
        case .refused: "The host refused the connection."
        case .dialFailed(let message): message.isEmpty ? "Tailscale could not reach the host." : message
        }
    }
}

enum UIDeviceName {
    /// A short random suffix, stable per install, so several phones stay distinct.
    static var short: String {
        let key = "tailnet.suffix"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = String(UUID().uuidString.prefix(4)).lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

/// One `tailscale_dial_timeout` and whoever still waits for it: the caller, or no one once cancelled.
private final class PendingDial: Sendable {
    private struct State {
        var waiter: CheckedContinuation<CInt, any Error>?
        var cancelled = false
    }

    private let state = Mutex(State())

    /// False when already cancelled; the continuation has then been resumed.
    func wait(_ continuation: CheckedContinuation<CInt, any Error>) -> Bool {
        let cancelled = state.withLock { state in
            if !state.cancelled { state.waiter = continuation }
            return state.cancelled
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    /// The caller gave up; a dial not yet begun is not worth starting.
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func cancel() {
        let waiter = state.withLock { state in
            state.cancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<CInt, any Error>) {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        if let waiter {
            waiter.resume(with: result)
        } else if case .success(let fd) = result {
            close(fd)
        }
    }
}
