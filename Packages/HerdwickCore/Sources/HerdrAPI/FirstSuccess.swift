import Synchronization

/// Starts every candidate at once and returns the first to succeed, with its index. It
/// returns the moment one wins: losers are cancelled but never awaited, so a slow or
/// blackholed candidate adds no time. A loser that succeeds anyway is handed to `discard`.
/// When all fail, the first candidate's error is thrown: it is the primary, whose failure
/// is the one worth showing.
public func firstSuccess<T: Sendable>(
    _ candidates: [@Sendable () async throws -> T],
    discard: @escaping @Sendable (T) async -> Void
) async throws -> (index: Int, value: T) {
    precondition(!candidates.isEmpty, "firstSuccess needs a candidate")
    let race = Race<T>(count: candidates.count)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard race.begin(continuation) else { return }
            for (index, candidate) in candidates.enumerated() {
                race.add(Task {
                    do {
                        let value = try await candidate()
                        if !race.win(index, value) { await discard(value) }
                    } catch {
                        race.lose(index, error)
                    }
                })
            }
        }
    } onCancel: {
        race.cancel()
    }
}

private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<(index: Int, value: T), Error>?
        var errors: [(any Error)?]
        var failed = 0
        var tasks: [Task<Void, Never>] = []
        var settled = false
    }

    private let state: Mutex<State>

    init(count: Int) {
        state = Mutex(State(errors: Array(repeating: nil, count: count)))
    }

    /// False if the caller was cancelled first; the continuation is then already resumed.
    func begin(_ continuation: CheckedContinuation<(index: Int, value: T), Error>) -> Bool {
        state.withLock { state in
            if state.settled {
                continuation.resume(throwing: CancellationError())
                return false
            }
            state.continuation = continuation
            return true
        }
    }

    func add(_ task: Task<Void, Never>) {
        let settled = state.withLock { state in
            if !state.settled { state.tasks.append(task) }
            return state.settled
        }
        if settled { task.cancel() }
    }

    /// True if `value` is the winner.
    func win(_ index: Int, _ value: T) -> Bool {
        let (won, continuation, losers) = state.withLock { state -> (Bool, CheckedContinuation<(index: Int, value: T), Error>?, [Task<Void, Never>]) in
            guard !state.settled else { return (false, nil, []) }
            state.settled = true
            defer { state.continuation = nil; state.tasks = [] }
            return (true, state.continuation, state.tasks)
        }
        guard won else { return false }
        continuation?.resume(returning: (index, value))
        for task in losers { task.cancel() }
        return true
    }

    func lose(_ index: Int, _ error: any Error) {
        let (continuation, primary) = state.withLock { state -> (CheckedContinuation<(index: Int, value: T), Error>?, (any Error)?) in
            state.errors[index] = error
            state.failed += 1
            guard !state.settled, state.failed == state.errors.count else { return (nil, nil) }
            state.settled = true
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.errors[0])
        }
        continuation?.resume(throwing: primary ?? error)
    }

    func cancel() {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<(index: Int, value: T), Error>?, [Task<Void, Never>]) in
            guard !state.settled else { return (nil, []) }
            state.settled = true
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        continuation?.resume(throwing: CancellationError())
        for task in tasks { task.cancel() }
    }
}
