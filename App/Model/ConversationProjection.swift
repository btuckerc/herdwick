import HerdrAPI
import Foundation

/// One projection per visible conversation; drafts and scrolling never change its inputs.
@MainActor
final class ConversationProjection {
    private struct Key: Equatable {
        let feed: ObjectIdentifier
        let revision: Int
        let detail: DetailLevel
        let arrival: ReadCursors.Mark?
        let nowPinned: Bool
    }
    private var key: Key?
    private var rows: [ConversationRow] = []

    func rows(feed: ConversationFeed, detail: DetailLevel, arrival: ReadCursors.Mark?, nowPinned: Bool) -> [ConversationRow] {
        let next = Key(feed: ObjectIdentifier(feed), revision: feed.contentRevision, detail: detail,
                       arrival: arrival, nowPinned: nowPinned)
        if key == next { return rows }
        rows = RenderTrace.measure("conv.project") {
            let conversation = feed.conversation
            let items = conversation.items(at: detail)
            let children = Dictionary(grouping: conversation.subagents, by: \.spawnCallId)
            var since: ConversationRow.Since?
            if let arrival, let catchUp = conversation.catchUp(after: arrival.item),
               let seen = conversation.items.lastIndex(where: { $0.id == arrival.item }) {
                let shown = Set(items.map(\.id))
                if let first = conversation.items[(seen + 1)...].first(where: { shown.contains($0.id) }) {
                    since = .init(before: first.id, catchUp: catchUp, seen: arrival.seen)
                }
            }
            return ConversationRow.rows(items, waitingOn: conversation.waitingOn, answered: items.answeredBriefs(),
                                        since: since, finished: conversation.finishedTurns, nowPinned: nowPinned,
                                        subagents: { children[$0] ?? [] })
        }
        key = next
        return rows
    }
}
