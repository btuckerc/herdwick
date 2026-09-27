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
        /// Checking that a live connection still answers after the route under it moved.
        case resuming
        case live
        case waiting(attempt: Int, delay: Duration)
        case failed(ConnectionFailure)
    }

    public enum Input: Equatable, Sendable {
        case start
        case foregrounded
        case backgrounded
        /// The link is removed or replaced; close it for good.
        case stop
        case pathChanged(satisfied: Bool)
        /// A fresh connection went live, or a checked one answered.
        case connected
        case connectFailed(ConnectionFailure)
        /// A live connection died (keepalive miss, stream EOF, socket error), or a
        /// checked one did not answer.
        case dropped(ConnectionFailure)
        case retryTimerFired
        /// The user tapped Retry, or changed the settings a failure asked them to fix.
        case userRetry
    }

    public enum Effect: Equatable, Sendable {
        case connect
        /// Check that the live connection still answers; report `.connected` or `.dropped`.
        case verify
        case disconnect
        case scheduleRetry(Duration)
        case cancelRetry
    }

    /// Delay after the n-th consecutive failure (1-based); the last value repeats.
    public static let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    public private(set) var phase: Phase = .idle
    private var networkAvailable = true
    /// The transport rides a route of its own (the in-app tailnet), which moves to a new
    /// physical path by itself; such a connection is checked on a route change, not replaced.
    private let migratesAcrossRoutes: Bool

    public init(migratesAcrossRoutes: Bool = false) {
        self.migratesAcrossRoutes = migratesAcrossRoutes
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch (input, phase) {
        case (.stop, _):
            phase = .idle
            return [.cancelRetry, .disconnect]

        case (.backgrounded, .suspended):
            return []
        case (.backgrounded, _):
            // Nothing stays open while suspended: the app could not read what a host sends,
            // and a host would keep streaming to it.
            phase = .suspended
            return [.cancelRetry, .disconnect]

        case (.foregrounded, .failed(let failure)) where !failure.retryable:
            return []
        case (.foregrounded, .live), (.foregrounded, .connecting), (.foregrounded, .resuming):
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
            case .live where migratesAcrossRoutes:
                phase = .resuming
                return [.verify]
            case .resuming where migratesAcrossRoutes:
                return []
            default:
                // A new route (Wi-Fi <-> cellular, VPN up/down) strands the
                // old TCP connection; replace it instead of waiting for a timeout.
                return [.disconnect] + connectNow()
            }

        case (.connected, .connecting), (.connected, .resuming):
            phase = .live
            return []

        case (.connectFailed(let failure), .connecting(let attempt)):
            if !failure.retryable {
                phase = .failed(failure)
                return [.disconnect]
            }
            return retryLater(after: attempt)

        case (.dropped(let failure), .live), (.dropped(let failure), .resuming):
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
