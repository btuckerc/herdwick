import Synchronization

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
    /// need one subscription per pane, so a change to the pane set re-subscribes. Events that
    /// arrive while a snapshot is in flight (a burst, or the backlog after the app was
    /// suspended) are taken together and cost one more snapshot, not one each. The stream
    /// throws when the event bridge dies; the caller treats that as a dropped connection
    /// and reconnects.
    ///
    /// `panes`, the pane set last seen (a snapshot still on screen), lets the subscription
    /// start alongside the preview instead of after it. If a listed pane has gone, herdr
    /// refuses the subscription and the preview's panes are used as without a hint.
    public nonisolated func mirror(session: String, panes hint: Set<String>? = nil) -> AsyncThrowingStream<MirrorUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    async let first = snapshot(session: session)
                    async let hinted = subscribe(session: session, panes: hint)
                    let preview = try await first
                    continuation.yield(.preview(preview))
                    var early = await hinted
                    var panes = early?.panes ?? Set(preview.panes.map(\.id))
                    while !Task.isCancelled {
                        let events: AsyncThrowingStream<HerdrEvent, any Error>
                        if let subscribed = early?.events {
                            events = subscribed
                            early = nil
                        } else {
                            events = try await self.events(session: session, subscriptions: Self.subscriptions(panes))
                        }
                        var current = try await snapshot(session: session)
                        let latest = Set(current.panes.map(\.id))
                        guard latest == panes else {
                            continuation.yield(.preview(current))
                            panes = latest
                            continue
                        }
                        continuation.yield(.live(current))
                        let inbox = EventInbox()
                        let reader = Task {
                            do {
                                for try await event in events { inbox.add(event) }
                                inbox.finish(nil)
                            } catch {
                                inbox.finish(error)
                            }
                        }
                        defer { reader.cancel() }
                        var resubscribe = false
                        while let batch = try await inbox.next() {
                            if !batch.isEmpty {
                                // Show the new statuses at once; the snapshot below refreshes aggregates.
                                for change in batch.values { current.apply(change) }
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

    private static func subscriptions(_ panes: Set<String>) -> [Subscription] {
        Subscription.structural + panes.sorted().map { Subscription.agentStatusChanged(paneID: $0) }
    }

    /// Subscribes to `panes` if given; nil without them, or when herdr refuses one that has gone.
    private func subscribe(session: String, panes: Set<String>?) async -> (panes: Set<String>, events: AsyncThrowingStream<HerdrEvent, any Error>)? {
        guard let panes, let events = try? await events(session: session, subscriptions: Self.subscriptions(panes)) else { return nil }
        return (panes, events)
    }
}

/// Coalesces structural changes and the latest status per pane while a snapshot is in flight.
/// An empty batch still means a snapshot is needed; nil means the stream ended.
final class EventInbox: Sendable {
    private struct State {
        var pending: [String: HerdrEvent.StatusChange] = [:]
        var dirty = false
        var end: Result<Void, any Error>?
        var waiter: CheckedContinuation<[String: HerdrEvent.StatusChange]?, any Error>?
    }

    private let state = Mutex(State())

    func add(_ event: HerdrEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<[String: HerdrEvent.StatusChange]?, any Error>? in
            guard state.end == nil else { return nil }
            guard let waiter = state.waiter else {
                state.dirty = true
                if let change = event.statusChange { state.pending[change.paneID] = change }
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: event.statusChange.map { [$0.paneID: $0] } ?? [:])
    }

    /// Ends the inbox after any pending events are taken; `error` makes `next()` throw.
    func finish(_ error: (any Error)?) {
        let waiter = state.withLock { state -> CheckedContinuation<[String: HerdrEvent.StatusChange]?, any Error>? in
            guard state.end == nil else { return nil }
            state.end = error.map { .failure($0) } ?? .success(())
            defer { state.waiter = nil }
            return state.waiter
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    func next() async throws -> [String: HerdrEvent.StatusChange]? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Outcome { case wait, events([String: HerdrEvent.StatusChange]), end(Result<Void, any Error>) }
                let outcome = state.withLock { state -> Outcome in
                    if state.dirty {
                        defer { state.pending = [:]; state.dirty = false }
                        return .events(state.pending)
                    }
                    if let end = state.end { return .end(end) }
                    state.waiter = continuation
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .events(let events): continuation.resume(returning: events)
                case .end(.success): continuation.resume(returning: nil)
                case .end(.failure(let error)): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            finish(CancellationError())
        }
    }
}

extension Snapshot {
    mutating func apply(_ change: HerdrEvent.StatusChange) {
        if let i = agents.firstIndex(where: { $0.paneID == change.paneID }) { agents[i].agentStatus = change.agentStatus }
        if let i = panes.firstIndex(where: { $0.id == change.paneID }) { panes[i].agentStatus = change.agentStatus }
    }
}
