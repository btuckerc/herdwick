import Foundation
import Observation

/// Confirmed answers that should remain visible after a prompt leaves the screen. The demo's
/// are kept only for the run, so a capture or a second try starts clean.
@Observable @MainActor
final class DecisionLog {
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let key: String
        let afterItemID: String?
        let at: Date
        let receipt: String
        let detail: String?
        /// The detail is a command read off the screen that may have been cut short; the
        /// receipt says so, as the card did (round 24: the receipt looked more certain than the
        /// request it answered).
        let detailMayBeCut: Bool

        init(id: UUID = UUID(), key: String, afterItemID: String?, at: Date = .now,
             receipt: String, detail: String?, detailMayBeCut: Bool = false) {
            self.id = id
            self.key = key
            self.afterItemID = afterItemID
            self.at = at
            self.receipt = receipt
            self.detail = detail
            self.detailMayBeCut = detailMayBeCut
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            key = try c.decode(String.self, forKey: .key)
            afterItemID = try c.decodeIfPresent(String.self, forKey: .afterItemID)
            at = try c.decode(Date.self, forKey: .at)
            receipt = try c.decode(String.self, forKey: .receipt)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            detailMayBeCut = try c.decodeIfPresent(Bool.self, forKey: .detailMayBeCut) ?? false
        }
    }

    private var stored: [Entry]
    private var unsaved: [Entry] = []
    private let defaults: UserDefaults
    private static let storageKey = "decisionLog.v1"
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let capacity = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = (try? JSONDecoder().decode([Entry].self, from: defaults.data(forKey: Self.storageKey) ?? Data())) ?? []
        prune()
    }

    func record(key: String, afterItemID: String?, receipt: String, detail: String?, detailMayBeCut: Bool = false, saved: Bool) {
        let entry = Entry(key: key, afterItemID: afterItemID, receipt: receipt, detail: detail, detailMayBeCut: detailMayBeCut)
        guard saved else { unsaved.append(entry); return }
        prune()
        stored.append(entry)
        if stored.count > Self.capacity { stored.removeFirst(stored.count - Self.capacity) }
        persist()
    }

    /// Read in view bodies, so it filters rather than prunes.
    func entries(for key: String) -> [Entry] {
        let cutoff = Date.now.addingTimeInterval(-Self.lifetime)
        return (stored + unsaved).filter { $0.key == key && $0.at >= cutoff }
    }

    /// Answers given today in these host sessions: the all-clear's tally, scoped as the counts
    /// beside it are (round 66: sb#2, a decision on another host counted on this one's; round 67:
    /// sb#1, nor another session's on the same host). Keys lead with the host's id and the
    /// session (`key(address:transcriptPath:)`).
    func decidedToday(in sessions: [SessionAddress]) -> Int {
        let prefixes = sessions.map { "\($0.hostID.uuidString)|\($0.session)|" }
        return (stored + unsaved).count { entry in
            Calendar.current.isDateInToday(entry.at) && prefixes.contains { entry.key.hasPrefix($0) }
        }
    }

    /// Stable across visits, while isolating hosts, sessions, panes and known transcript files
    /// (round 8: without the session, the same pane ID in another session shared its answers
    /// when there was no transcript to tell them apart). Entries keyed without it age out.
    static func key(address: PaneAddress, transcriptPath: String?) -> String {
        [address.hostID.uuidString, address.session, address.paneID, transcriptPath ?? ""].joined(separator: "|")
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.lifetime)
        let recent = stored.filter { $0.at >= cutoff }
        let limited = Array(recent.suffix(Self.capacity))
        guard limited != stored else { return }
        stored = limited
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
