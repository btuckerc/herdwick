import Foundation
import Synchronization

public struct TimeoutError: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "The host didn't answer in time." }
}

/// Runs `operation`, giving up after `limit`. Giving up returns at once: the operation is
/// cancelled but never awaited, so one stuck in a call that ignores cancellation (a blocking
/// libtailscale call, a channel that never answers) can't hold the caller past `limit`.
public func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = Gate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard gate.begin(continuation) else { return }
            gate.add(Task {
                do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
            })
            gate.add(Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                gate.finish(.failure(TimeoutError()))
            })
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// The first result wins; the rest, and every task still running, are dropped.
private final class Gate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var tasks: [Task<Void, Never>] = []
        var result: Result<T, Error>?
    }

    private let state = Mutex(State())

    /// False if it already finished (the caller was cancelled first); the continuation is then resumed.
    func begin(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let result = state.withLock { state -> Result<T, Error>? in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        guard let result else { return true }
        continuation.resume(with: result)
        return false
    }

    func add(_ task: Task<Void, Never>) {
        let done = state.withLock { state in
            if state.result == nil { state.tasks.append(task) }
            return state.result != nil
        }
        if done { task.cancel() }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        continuation?.resume(with: result)
        for task in tasks { task.cancel() }
    }
}
