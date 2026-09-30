import Foundation

/// Where the reader left each conversation: the last item they saw at its end, and when.
/// Keyed like drafts (`DraftStore.id`); entries unseen for a month are dropped.
@MainActor
enum ReadCursors {
    struct Mark: Codable, Equatable {
        let item: String
        let seen: Date
    }

    private static let key = "readCursors"
    private static let lifetime: TimeInterval = 30 * 24 * 3600
    private static var cached: [String: Mark]?

    static func load(_ conversation: String) -> Mark? { all()[conversation] }

    static func save(_ item: String, for conversation: String) {
        var marks = all()
        guard marks[conversation]?.item != item else { return }
        marks = marks.filter { $0.value.seen > .now - lifetime }
        marks[conversation] = Mark(item: item, seen: .now)
        cached = marks
        UserDefaults.standard.set(try? JSONEncoder().encode(marks), forKey: key)
    }

    private static func all() -> [String: Mark] {
        if let cached { return cached }
        let marks = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) } ?? [:]
        cached = marks
        return marks
    }
}
