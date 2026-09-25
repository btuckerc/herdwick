/// Why a connection attempt or a live connection failed.
public struct ConnectionFailure: Error, Equatable, Sendable {
    public var message: String
    /// False for problems only the user can fix (auth rejected, host key
    /// mismatch, herdr missing); the supervisor stops retrying those.
    public var retryable: Bool

    public init(_ message: String, retryable: Bool) {
        self.message = message
        self.retryable = retryable
    }
}

/// Reconnect policy as a pure state machine. The owner feeds it inputs and
/// performs the returned effects, so every transition is unit-testable
/// without sockets or clocks.
public struct ConnectionSupervisor: Sendable, Equatable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// App is in the background; the connection is intentionally closed.
        case suspended
        /// No usable network path; resumes on the next path change.
        case offline
        case connecting(attempt: Int)
        case live
        case waiting(attempt: Int, delay: Duration)
        case failed(ConnectionFailure)
    }

    public enum Input: Equatable, Sendable {
        case start
        case foregrounded
        case backgrounded
        case pathChanged(satisfied: Bool)
        case connected
        case connectFailed(ConnectionFailure)
        /// A live connection died (keepalive miss, stream EOF, socket error).
        case dropped(ConnectionFailure)
        case retryTimerFired
        /// The user tapped Retry, or changed the settings a failure asked them to fix.
        case userRetry
    }

    public enum Effect: Equatable, Sendable {
        case connect
        case disconnect
        case scheduleRetry(Duration)
        case cancelRetry
    }

    /// Delay after the n-th consecutive failure (1-based); the last value repeats.
    public static let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    public private(set) var phase: Phase = .idle
    private var networkAvailable = true

    public init() {}

    public mutating func handle(_ input: Input) -> [Effect] {
        switch (input, phase) {
        case (.backgrounded, .suspended):
            return []
        case (.backgrounded, _):
            phase = .suspended
            return [.cancelRetry, .disconnect]

        case (.foregrounded, .failed(let failure)) where !failure.retryable:
            return []
        case (.foregrounded, .live), (.foregrounded, .connecting):
            return []
        case (.foregrounded, _), (.start, _), (.userRetry, _):
            return connectNow()

        case (.pathChanged(let satisfied), _):
            networkAvailable = satisfied
            switch phase {
            case .suspended, .idle:
                return []
            case .failed(let failure) where !failure.retryable:
                return []
            case _ where !satisfied:
                // Keep a live connection: it may survive a brief blip; the
                // keepalive reports a real drop.
                if case .live = phase { return [] }
                phase = .offline
                return [.cancelRetry, .disconnect]
            default:
                // A new route (Wi-Fi <-> cellular, VPN up/down) strands the
                // old TCP connection; replace it instead of waiting for a timeout.
                return [.disconnect] + connectNow()
            }

        case (.connected, .connecting):
            phase = .live
            return []

        case (.connectFailed(let failure), .connecting(let attempt)):
            if !failure.retryable {
                phase = .failed(failure)
                return [.disconnect]
            }
            return retryLater(after: attempt)

        case (.dropped(let failure), .live):
            if !failure.retryable {
                phase = .failed(failure)
                return [.disconnect]
            }
            return [.disconnect] + connectNow()

        case (.retryTimerFired, .waiting(let attempt, _)):
            phase = .connecting(attempt: attempt + 1)
            return [.connect]

        default:
            // Stale inputs (a late timer, a drop after backgrounding) are ignored.
            return []
        }
    }

    private mutating func connectNow() -> [Effect] {
        guard networkAvailable else {
            phase = .offline
            return [.cancelRetry]
        }
        phase = .connecting(attempt: 1)
        return [.cancelRetry, .connect]
    }

    private mutating func retryLater(after attempt: Int) -> [Effect] {
        guard networkAvailable else {
            phase = .offline
            return [.disconnect]
        }
        let delay = Self.backoff[min(attempt, Self.backoff.count) - 1]
        phase = .waiting(attempt: attempt, delay: delay)
        return [.disconnect, .scheduleRetry(delay)]
    }
}
