import Foundation

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

    var address: String {
        switch route {
        case .direct(let host, let port): port == 22 ? host : "\(host):\(port)"
        case .tailnet(_, let name, _): name
        }
    }

    var isTailnet: Bool {
        if case .tailnet = route { true } else { false }
    }

    var passwordAccount: String { "password.\(id.uuidString)" }
    var hostKeyAccount: String { "hostkey.\(id.uuidString)" }
}

/// Profiles are small and non-secret, so they live in UserDefaults; secrets go to the keychain.
enum ProfileStorage {
    private static let key = "hosts.v1"

    static func load() -> [HostProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let stored = (try? JSONDecoder().decode([HostProfile].self, from: data)) ?? []
        var ids = Set<HostProfile.ID>()
        return stored.filter { ids.insert($0.id).inserted }
    }

    static func save(_ profiles: [HostProfile]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: key)
    }
}
