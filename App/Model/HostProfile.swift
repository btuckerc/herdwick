import Foundation
import HerdrAPI

/// One computer running herdr, as the user set it up.
struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    enum Route: Codable, Hashable, Sendable {
        /// Any hostname or IP the phone can reach itself (LAN, public DNS, a system VPN).
        case direct(host: String, port: Int)
        /// A peer on the tailnet the embedded Tailscale node joined; dialled in-app.
        case tailnet(nodeID: String, name: String, address: String)
    }

    enum Auth: String, Codable, Sendable, CaseIterable, Identifiable {
        case deviceKey, password, tailscaleSSH
        var id: Self { self }

        var label: String {
            switch self {
            case .deviceKey: "This iPhone's key"
            case .password: "Password"
            case .tailscaleSSH: "Tailscale SSH"
            }
        }
    }

    var id = UUID()
    var name: String
    var route: Route
    var username: String
    var auth: Auth
    /// herdr session to open; nil follows the host's default session.
    var session: String?
    /// Another way to reach the same machine on a local network (`192.168.1.20`,
    /// `mac.local:2222`), dialled alongside `route`; whichever answers first is used.
    var lanAddress: String?
    /// Turned off: kept, but never dialled or retried (a laptop that's shut, a host only
    /// reachable at home). Optional so hosts saved before it still decode.
    var disabled: Bool?

    var isEnabled: Bool {
        get { disabled != true }
        set { disabled = newValue ? nil : true }
    }

    var address: String {
        switch route {
        case .direct(let host, let port): port == 22 ? host : "\(host):\(port)"
        case .tailnet(_, let name, _): name
        }
    }

    var isTailnet: Bool {
        if case .tailnet = route { true } else { false }
    }

    /// `lanAddress` as something to dial: never with Tailscale SSH, which only the tailnet
    /// address accepts, nor when it names the same place `route` does.
    var lanRoute: (host: String, port: Int)? {
        guard auth != .tailscaleSSH, let lanAddress, let parsed = HostAddress.parse(lanAddress) else { return nil }
        let port = parsed.port ?? 22
        if case .direct(let host, let routePort) = route, host == parsed.host, routePort == port { return nil }
        return (parsed.host, port)
    }

    var passwordAccount: String { "password.\(id.uuidString)" }
    var hostKeyAccount: String { "hostkey.\(id.uuidString)" }
}

/// Profiles are small and non-secret, so they live in UserDefaults; secrets go to the keychain.
enum ProfileStorage {
    private static let key = "hosts.v1"

    static func load() -> [HostProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        // One by one: a host this build can't read is dropped, not every host with it.
        let stored = ((try? JSONDecoder().decode([Lenient].self, from: data)) ?? []).compactMap(\.profile)
        var ids = Set<HostProfile.ID>()
        return stored.filter { ids.insert($0.id).inserted }
    }

    static func save(_ profiles: [HostProfile]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: key)
    }

    private struct Lenient: Decodable {
        let profile: HostProfile?
        init(from decoder: Decoder) throws { profile = try? HostProfile(from: decoder) }
    }
}
