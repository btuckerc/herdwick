import Foundation
import HerdrAPI
import UIKit

struct PendingSend: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    let text: String
    /// The conversation's last stable item when this was sent (any kind, so a window of only tool
    /// output still has one): a record boundary, never a count in a sliding transcript window.
    /// Nil only when nothing had loaded.
    let afterItemID: String?
    /// omp holds it until the agent next takes input.
    let held: Bool

    /// Whitespace aside, the sent text inside a transcript message (attachments add paths around it).
    func matches(_ transcript: String) -> Bool {
        let key = text.filter { !$0.isWhitespace }
        return !key.isEmpty && transcript.filter { !$0.isWhitespace }.contains(key)
    }

    /// Whitespace aside, the transcript message is exactly the sent text.
    func matchesExactly(_ transcript: String) -> Bool {
        let key = text.filter { !$0.isWhitespace }
        return !key.isEmpty && transcript.filter { !$0.isWhitespace } == key
    }
}

struct PendingLedger: Codable, Sendable, Equatable {
    var messages: [PendingSend] = []
    /// Reservations prevent two identical sends claiming one transcript record, across relaunches.
    var matchedUserIDs: Set<String> = []

    /// Exact records are claimed first: an older send whose text only appears inside a later
    /// message ("deploy" inside "Commit push deploy.") must not take that message's record and
    /// leave its own send pending forever.
    mutating func settle(in conversation: Conversation) {
        let items = conversation.items
        for exact in [true, false] where !messages.isEmpty {
            messages.removeAll { message in
                // A boundary outside the loaded window lies before it, so every loaded message is later.
                let start = message.afterItemID.flatMap { boundary in items.firstIndex { $0.id == boundary } }.map { $0 + 1 } ?? 0
                for case .user(let id, let text, _) in items[start...] where !matchedUserIDs.contains(id)
                    && (exact ? message.matchesExactly(text) : message.matches(text)) {
                    matchedUserIDs.insert(id)
                    return true
                }
                return false
            }
        }
        if messages.isEmpty { matchedUserIDs = [] }
    }
}

/// Parsed off-main from the exact forward bytes already fetched for inbox activity.
struct WarmConversation: Sendable {
    var location: TranscriptLocation
    var conversation = Conversation()
    /// Where the parsed bytes begin in the file.
    var start = 0
    var offset: Int?
    var hasEarlier = false
    var title: String?

    /// Takes one activity read. A forward read may start behind `offset` (the activity reader
    /// lags a conversation that was just followed); both are line ends, so the overlap is
    /// skipped. A gap, a truncated file or a tail with no line end returns false.
    mutating func absorb(_ chunk: HerdrClient.FileChunk, initial: Bool) -> Bool {
        guard let size = chunk.size, chunk.from <= size else { return false }
        var bytes = chunk.bytes[...]
        var from = chunk.from
        if initial {
            conversation = Conversation()
            hasEarlier = from > 0
            start = from
            title = from == 0 ? TranscriptReader.title(inHead: chunk.bytes, format: location.format) : nil
        } else {
            guard let offset, offset <= size, from <= offset, offset <= from + bytes.count else { return false }
            bytes = bytes.dropFirst(offset - from)
            from = offset
        }
        // Keep only complete lines: activity rereads the partial suffix on its next round.
        guard let newline = bytes.lastIndex(of: 10) else {
            if initial, from > 0 { return false }
            offset = from
            return true
        }
        var reader = TranscriptReader(format: location.format, startsMidFile: initial && from > 0)
        conversation.apply(records: reader.appendRecords(Array(bytes[...newline])))
        offset = chunk.from + newline + 1 // slice indices are the chunk's own
        return true
    }
}

@MainActor @Observable
final class ConversationState {
    let feed = ConversationFeed()
    var location: TranscriptLocation?
    let id: String
    private var ledger: PendingLedger
    var pending: [PendingSend] {
        get { ledger.messages }
        set { ledger.messages = newValue; persist() }
    }
    @ObservationIgnored var viewers = Set<UUID>()
    /// Opened here, or the last turn when only warmed; ranks what is kept.
    @ObservationIgnored var lastUse = Date.distantPast
    /// A fresh tail read was spent on warming this one this launch; a failed one isn't retried
    /// every round (a tail that is one long line would be read again and again).
    @ObservationIgnored var warmAttempted = false
    let persistent: Bool

    init(id: String, persistent: Bool) {
        self.id = id
        self.persistent = persistent
        ledger = persistent ? DraftStore.pending(id) : PendingLedger()
    }

    func settlePending() {
        guard feed.isCaughtUp else { return }
        let previous = ledger
        ledger.settle(in: feed.conversation)
        if ledger != previous { persist() }
    }

    /// The pending sends the shown conversation doesn't hold yet, settled or not.
    var unsettled: [PendingSend] {
        guard !ledger.messages.isEmpty else { return [] }
        var copy = ledger
        copy.settle(in: feed.conversation)
        return copy.messages
    }

    func adoptPending(from previous: ConversationState) {
        ledger.messages = previous.ledger.messages + ledger.messages.filter { candidate in
            !previous.ledger.messages.contains { $0.id == candidate.id }
        }
        ledger.matchedUserIDs.formUnion(previous.ledger.matchedUserIDs)
        persist()
        previous.pending = []
    }

    private func persist() {
        if persistent { DraftStore.savePending(ledger, for: id) }
    }
}

/// App-owned data, not channels. At most eight inactive parsed conversations; pending
/// ledgers are never evicted. A view's task owns the live follow and closes it on departure.
@MainActor
final class ConversationRegistry {
    private var entries: [String: ConversationState] = [:]
    private var panes: [String: String] = [:]
    private var memoryObserver: NSObjectProtocol?
    var persistent = true

    init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.discardInactive() }
        }
    }

    func entry(host: SessionAddress, pane: String, agent: Agent?, ref: AgentSessionRef? = nil,
               location: TranscriptLocation? = nil) -> ConversationState {
        let reference = ref ?? agent?.agentSession
        let paneKey = [host.hostID.uuidString, host.session, pane].joined(separator: "\u{1F}")
        let id = reference == nil ? panes[paneKey] ?? DraftStore.id(host: host, ref: nil, pane: pane, name: agent?.name)
            : DraftStore.id(host: host, ref: reference, pane: pane, name: agent?.name)
        if let old = panes[paneKey], old != id, old.split(separator: "\u{1F}").last?.hasPrefix("pane:") == true,
           id.split(separator: "\u{1F}").last?.hasPrefix("session:") == true {
            if let previous = entries.removeValue(forKey: old) {
                let next = entries[id] ?? ConversationState(id: id, persistent: persistent)
                next.adoptPending(from: previous)
                entries[id] = next
            } else if persistent { DraftStore.movePending(from: old, to: id) }
        }
        panes[paneKey] = id
        if entries[id] == nil { entries[id] = ConversationState(id: id, persistent: persistent) }
        let entry = entries[id]!
        if let location, entry.location == nil { entry.location = location }
        return entry
    }

    func activate(_ entry: ConversationState, viewer: UUID) {
        entry.viewers.insert(viewer)
        entry.lastUse = .now
        trim()
    }

    func deactivate(_ entry: ConversationState, viewer: UUID) {
        entry.viewers.remove(viewer)
        entry.lastUse = .now
        if entry.viewers.isEmpty { entry.feed.markStale() }
        trim()
    }

    /// The eight most recent conversations per host: opened here (`lastUse`), else by their last
    /// turn. The same ones are kept by `trim`, so a warmed conversation isn't dropped and refetched.
    private var warmTargets: [String: Set<String>] = [:]

    func warmInputs(host: SessionAddress, agents: [Agent], lastTurn: [String: Date]) -> [String: (state: WarmConversation?, revision: Int)] {
        var ranked: [(agent: Agent, recency: Date, index: Int)] = []
        for (index, agent) in agents.enumerated() {
            let turn: Date = lastTurn[agent.paneID] ?? .distantPast
            let known: ConversationState? = DraftStore.id(host: host, agent: agent).flatMap { entries[$0] }
            ranked.append((agent, max(turn, known?.lastUse ?? .distantPast), index))
        }
        ranked.sort { $0.recency != $1.recency ? $0.recency > $1.recency : $0.index < $1.index }
        var result: [String: (state: WarmConversation?, revision: Int)] = [:]
        var targets = Set<String>()
        defer { warmTargets["\(host.hostID.uuidString)|\(host.session)"] = targets }
        for candidate in ranked.prefix(8) {
            let entry = entry(host: host, pane: candidate.agent.paneID, agent: candidate.agent)
            entry.lastUse = max(entry.lastUse, candidate.recency)
            targets.insert(entry.id)
            guard !entry.feed.isFollowing else { continue }
            if let warm = entry.feed.warmSnapshot(location: entry.location) {
                result[candidate.agent.paneID] = (warm, entry.feed.revision)
            } else if !entry.warmAttempted {
                // Nil asks `readActivity` for a fresh tail read to warm it from.
                entry.warmAttempted = true
                result[candidate.agent.paneID] = (nil, entry.feed.revision)
            }
        }
        return result
    }

    /// A failed warm leaves what the conversation had: following it catches up from there.
    func publish(_ updates: [String: WarmConversation?], revisions: [String: Int], host: SessionAddress, agents: [Agent]) {
        for agent in agents {
            guard let update = updates[agent.paneID] ?? nil, let revision = revisions[agent.paneID] else { continue }
            let entry = entry(host: host, pane: agent.paneID, agent: agent)
            guard !entry.feed.isFollowing, entry.feed.revision == revision else { continue }
            entry.location = update.location
            entry.feed.warm(update, host: host)
            // A later discard (memory warning, outgrown window) may ask for a fresh tail again.
            entry.warmAttempted = false
        }
        trim()
    }

    /// The conversation already parsed for `agent`, open or warmed; never creates or fetches one.
    func parsed(host: SessionAddress, agent: Agent) -> Conversation? {
        DraftStore.id(host: host, agent: agent).flatMap { entries[$0] }?.feed.conversation
    }

    private func trim() {
        let targets = warmTargets.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let inactive = entries.values.filter { $0.viewers.isEmpty }.sorted {
            let (left, right) = (targets.contains($0.id), targets.contains($1.id))
            return left != right ? left : $0.lastUse > $1.lastUse
        }
        // Eight per host at most, as each host warms its own eight.
        for entry in inactive.dropFirst(max(8, targets.count)) {
            if entry.pending.isEmpty { entries.removeValue(forKey: entry.id) }
            else { entry.feed.discardParsedData() }
        }
        panes = panes.filter { entries[$0.value] != nil }
    }

    private func discardInactive() {
        for entry in entries.values where entry.viewers.isEmpty { entry.feed.discardParsedData() }
        trim()
    }
}
