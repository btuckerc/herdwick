import Foundation

/// Every visible agent across every host, as last seen. The app writes it to the shared App
/// Group container; the notification service updates the agent a push is about; widgets read.
struct AttentionSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        /// As presented in the app: `done` is an unread completion, a read one is `idle`.
        enum State: String, Codable, CaseIterable {
            case blocked, done, working, idle

            var label: String {
                switch self {
                case .blocked: "Needs you"
                case .done: "Done"
                case .working: "Working"
                case .idle: "Idle"
                }
            }

            var symbol: String {
                switch self {
                case .blocked: "exclamationmark.bubble.fill"
                case .done: "checkmark.circle.fill"
                case .working: "circle.dotted"
                case .idle: "moon.zzz.fill"
                }
            }
        }
        let id: String
        let title: String
        let place: String
        let state: State
        /// When the app saw this state begin; nil when it was already so at first sight.
        let since: Date?
        let url: URL
    }

    /// Needs you, unread completions, working, idle; the newest change first within each.
    var items: [Item]
    /// Every host answered this time. When false, an empty list is not "all clear".
    var complete: Bool
    var updated: Date

    func count(_ state: Item.State) -> Int { items.count { $0.state == state } }
    var blocked: Int { count(.blocked) }
    var done: Int { count(.done) }

    /// State order, then the newest change first.
    mutating func sort() {
        let order = Item.State.allCases
        items.sort { lhs, rhs in
            let left = order.firstIndex(of: lhs.state)!, right = order.firstIndex(of: rhs.state)!
            if left != right { return left < right }
            return (lhs.since ?? .distantPast) > (rhs.since ?? .distantPast)
        }
    }

    /// `host/session/pane`: an item's id, and the identifier of that agent's alert.
    static func key(host: UUID, session: String, pane: String) -> String {
        "\(host.uuidString)/\(session)/\(pane)"
    }

    static let appGroup = "group.dev.btuckerc.herdwick"
    /// Shared with the notification service: pane key → the change last alerted.
    static var shared: UserDefaults? { UserDefaults(suiteName: appGroup) }
    static let alertedKey = "attention.alerted"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("attention.json")
    }

    static func load() -> AttentionSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AttentionSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// `herdwick://open?host=<uuid>&session=<name>&pane=<id>` opens that agent's conversation.
enum AttentionLink {
    static func url(host: UUID, session: String, pane: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "herdwick"
        parts.host = "open"
        parts.queryItems = [.init(name: "host", value: host.uuidString), .init(name: "session", value: session),
                            .init(name: "pane", value: pane)]
        return parts.url!
    }

    static func parse(_ url: URL) -> (host: UUID, session: String, pane: String)? {
        guard url.scheme == "herdwick", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host").flatMap(UUID.init(uuidString:)), let session = value("session"),
              let pane = value("pane") else { return nil }
        return (host, session, pane)
    }
}
