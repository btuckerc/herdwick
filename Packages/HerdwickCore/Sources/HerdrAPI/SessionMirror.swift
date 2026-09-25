extension HerdrClient {
    /// A live copy of one session: yields a snapshot now and a fresh one after every change.
    ///
    /// Gap-free per herdr's contract: subscribe first, then snapshot. Agent status events
    /// need one subscription per pane, so a change to the pane set re-subscribes. The
    /// stream throws when the event bridge dies; the caller treats that as a dropped
    /// connection and reconnects.
    public nonisolated func mirror(session: String) -> AsyncThrowingStream<Snapshot, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var panes = Set(try await snapshot(session: session).panes.map(\.id))
                    while !Task.isCancelled {
                        let subscriptions = Subscription.structural + panes.sorted().map { Subscription.agentStatusChanged(paneID: $0) }
                        let events = try await self.events(session: session, subscriptions: subscriptions)
                        var current = try await snapshot(session: session)
                        continuation.yield(current)
                        if Set(current.panes.map(\.id)) != panes {
                            panes = Set(current.panes.map(\.id))
                            continue
                        }
                        var resubscribe = false
                        for try await event in events {
                            if let change = event.statusChange {
                                // Show the new status at once; the snapshot below refreshes aggregates.
                                current.apply(change)
                                continuation.yield(current)
                            }
                            current = try await snapshot(session: session)
                            continuation.yield(current)
                            let latest = Set(current.panes.map(\.id))
                            if latest != panes {
                                panes = latest
                                resubscribe = true
                                break
                            }
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
