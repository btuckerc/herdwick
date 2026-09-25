import Foundation

/// What needs attention across every host, as the app last saw it. The app writes it to
/// the shared App Group container; widgets only read it.
struct AttentionSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        enum State: String, Codable { case blocked, done }
        let id: String
        let title: String
        let place: String
        let state: State
        let url: URL
    }

    /// Blocked first, then unread completions, newest change first within each.
    var items: [Item]
    /// Every host answered this time. When false, an empty list is not "all clear".
    var complete: Bool
    var updated: Date

    var blocked: Int { items.count { $0.state == .blocked } }
    var done: Int { items.count { $0.state == .done } }

    static let appGroup = "group.dev.btuckerc.herdwick"

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
