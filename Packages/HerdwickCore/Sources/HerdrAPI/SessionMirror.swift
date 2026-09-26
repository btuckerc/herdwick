/// One step of `HerdrClient.mirror(session:)`.
public enum MirrorUpdate: Sendable, Equatable {
    /// A snapshot not yet covered by a subscription for each of its panes: the first one,
    /// taken before subscribing so the session shows sooner, or one that found panes the
    /// subscription lacks. Some status changes around it may not arrive as events.
    case preview(Snapshot)
    /// Taken after subscribing to every pane it shows: no change after it is missed.
    case live(Snapshot)

    public var snapshot: Snapshot {
        switch self {
        case .preview(let snapshot), .live(let snapshot): snapshot
        }
    }
}

extension HerdrClient {
    /// A live copy of one session: a preview snapshot at once, then a live one once every
    /// pane is subscribed, and a fresh one after every change.
    ///
    /// Gap-free per herdr's contract: subscribe first, then snapshot. Agent status events
    /// need one subscription per pane, so a change to the pane set re-subscribes. The
    /// stream throws when the event bridge dies; the caller treats that as a dropped
    /// connection and reconnects.
    public nonisolated func mirror(session: String) -> AsyncThrowingStream<MirrorUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let preview = try await snapshot(session: session)
                    continuation.yield(.preview(preview))
                    var panes = Set(preview.panes.map(\.id))
                    while !Task.isCancelled {
                        let subscriptions = Subscription.structural + panes.sorted().map { Subscription.agentStatusChanged(paneID: $0) }
                        let events = try await self.events(session: session, subscriptions: subscriptions)
                        var current = try await snapshot(session: session)
                        let latest = Set(current.panes.map(\.id))
                        guard latest == panes else {
                            continuation.yield(.preview(current))
                            panes = latest
                            continue
                        }
                        continuation.yield(.live(current))
                        var resubscribe = false
                        for try await event in events {
                            if let change = event.statusChange {
                                // Show the new status at once; the snapshot below refreshes aggregates.
                                current.apply(change)
                                continuation.yield(.live(current))
                            }
                            current = try await snapshot(session: session)
                            let latest = Set(current.panes.map(\.id))
                            if latest != panes {
                                continuation.yield(.preview(current))
                                panes = latest
                                resubscribe = true
                                break
                            }
                            continuation.yield(.live(current))
                        }
                        if !resubscribe { throw HerdrError.noResponse }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Snapshot {
    mutating func apply(_ change: HerdrEvent.StatusChange) {
        if let i = agents.firstIndex(where: { $0.paneID == change.paneID }) { agents[i].agentStatus = change.agentStatus }
        if let i = panes.firstIndex(where: { $0.id == change.paneID }) { panes[i].agentStatus = change.agentStatus }
    }
}
