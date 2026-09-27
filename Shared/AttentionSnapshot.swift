import Foundation
import CryptoKit

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
        /// The conversation's `DraftStore` id when it has a transcript session: what the share
        /// sheet offers as a destination. Nil for terminal-only agents.
        var draftID: String? = nil
    }

    /// Needs you, unread completions, working, idle; the newest change first within each.
    var items: [Item]
    /// Every host answered this time. When false, an empty list is not "all clear".
    var complete: Bool
    var updated: Date
    /// Pane key → the name of every agent the app last saw, hidden ones and ones on hosts not
    /// shown now included, so a pushed alert can say which thread. Stays on this phone.
    var names: [String: Name] = [:]
    /// Host id → its name here, for an alert about an agent this phone never saw.
    var hosts: [String: String] = [:]

    struct Name: Codable, Equatable {
        let title: String
        let place: String
    }

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
    static let secretKey = "push.secret"
    static let installationKey = "push.installation"
    /// Last live observation or authenticated push. An unsigned event never advances it.
    static let sequencesKey = "push.sequences"
    static let referencesKey = "attention.references"
    static let mutesKey = "attention.mutes"
    static func muteKey(_ paneKey: String, reference: String) -> String {
        paneKey + "/" + Data(reference.utf8).base64EncodedString()
    }

    struct Mute: Codable {
        let reference: String
        let expires: Date?
        func active(reference: String, now: Date = .now) -> Bool {
            self.reference == reference && (expires.map { $0 > now } ?? true)
        }
    }

    static var mutes: [String: Mute] {
        get {
            shared?.data(forKey: mutesKey)
                .flatMap { try? JSONDecoder().decode([String: Mute].self, from: $0) } ?? [:]
        }
        set { shared?.set(try? JSONEncoder().encode(newValue), forKey: mutesKey) }
    }

    static func authentic(host: String, session: String, pane: String, state: String, seq: Int, mac: String?) -> Bool {
        guard let secret = shared?.string(forKey: secretKey), let mac, mac.count == 64,
              [host, session, pane, state].allSatisfy({ !$0.contains("|") }),
              seq >= 0 else { return false }
        let message = Data("v1|\(host)|\(session)|\(pane)|\(state)|\(seq)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        let expected = signature.map { String(format: "%02x", $0) }.joined()
        return zip(expected.utf8, mac.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

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

extension AttentionSnapshot {
    private enum CodingKeys: String, CodingKey { case items, complete, updated, names, hosts }

    /// A snapshot saved before `names` and `hosts` existed still loads until the app rewrites it.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Item].self, forKey: .items)
        complete = try c.decode(Bool.self, forKey: .complete)
        updated = try c.decode(Date.self, forKey: .updated)
        names = try c.decodeIfPresent([String: Name].self, forKey: .names) ?? [:]
        hosts = try c.decodeIfPresent([String: String].self, forKey: .hosts) ?? [:]
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
