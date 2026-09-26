import Foundation
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
    private var poll: Task<Void, Never>?

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
        state = .starting
        let config = Configuration(
            hostName: "herdwick-\(UIDeviceName.short)",
            path: Self.stateDirectory.path,
            authKey: nil,
            controlURL: controlURL,
            ephemeral: false
        )
        Task {
            do {
                let node = try await Task.detached { try TailscaleNode(config: config, logger: nil) }.value
                self.node = node
                self.handle = await node.tailscale
                self.refreshSoon()
            } catch {
                self.state = .failed("Tailscale could not start: \(error)")
            }
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
        poll?.cancel()
        try? await node?.close()
        node = nil
        handle = nil
        peers = []
        tailnetName = nil
        try? FileManager.default.removeItem(at: Self.stateDirectory)
        state = .off
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
                // Connecting waits on `Running`, so look often while the node comes up;
                // a sign-in in the browser takes a while.
                let interval: Duration = if case .needsLogin = state { .seconds(1) } else { .milliseconds(250) }
                try? await Task.sleep(for: interval)
                waited += interval
            }
        }
    }

    private func status() async -> IpnState.Status? {
        guard let node, let data = try? await node.statusJSON() else { return nil }
        return try? JSONDecoder().decode(IpnState.Status.self, from: data)
    }

    private func apply(_ status: IpnState.Status) {
        tailnetName = status.CurrentTailnet?.Name
        switch status.BackendState {
        case "Running":
            state = .running
        case "NeedsLogin", "NeedsMachineAuth":
            state = .needsLogin(URL(string: status.AuthURL))
        default:
            if case .needsLogin = state { break }
            state = .starting
        }
        peers = (status.Peer ?? [:]).values.compactMap { peer in
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

    /// Opens a TCP connection to `address:port` through the tailnet and returns a
    /// connected socket descriptor that the caller owns.
    nonisolated func dial(address: String, port: Int, handle: TailscaleHandle) async throws -> CInt {
        try await Task.detached {
            var conn: tailscale_conn = 0
            let target = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
            guard tailscale_dial(handle, "tcp", target, &conn) == 0 else {
                var buffer = [CChar](repeating: 0, count: 512)
                tailscale_errmsg(handle, &buffer, buffer.count)
                throw TailnetError.dialFailed(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            return conn
        }.value
    }

    /// The node handle once started; dialling before that throws.
    func readyHandle() async throws -> TailscaleHandle {
        if node == nil { start() }
        for _ in 0..<150 {
            if let handle, state == .running { return handle }
            if case .needsLogin = state { throw TailnetError.signedOut }
            if case .failed(let message) = state { throw TailnetError.dialFailed(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TailnetError.notRunning
    }
}

enum TailnetError: LocalizedError {
    case notRunning, signedOut
    case dialFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Tailscale is still starting."
        case .signedOut: "Sign in to Tailscale again."
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
