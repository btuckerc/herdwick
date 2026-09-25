import HerdrAPI
import Testing

private let transient = ConnectionFailure("timed out", retryable: true)
private let authRejected = ConnectionFailure("key rejected", retryable: false)

@Suite struct ConnectionSupervisorTests {
    @Test func backoffGrowsThenCaps() {
        var s = ConnectionSupervisor()
        #expect(s.handle(.start) == [.cancelRetry, .connect])
        var delays: [Duration] = []
        for _ in 0..<7 {
            let effects = s.handle(.connectFailed(transient))
            guard case .scheduleRetry(let delay) = effects.last else {
                Issue.record("expected a retry, got \(effects)")
                return
            }
            delays.append(delay)
            #expect(s.handle(.retryTimerFired) == [.connect])
        }
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)])
    }

    @Test func successResetsBackoff() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        _ = s.handle(.connectFailed(transient))
        _ = s.handle(.retryTimerFired)
        _ = s.handle(.connected)
        #expect(s.phase == .live)
        // A later drop reconnects immediately, then starts over at 500 ms.
        #expect(s.handle(.dropped(transient)) == [.disconnect, .cancelRetry, .connect])
        #expect(s.handle(.connectFailed(transient)) == [.disconnect, .scheduleRetry(.milliseconds(500))])
    }

    @Test func backgroundClosesAndIgnoresStaleInputs() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        _ = s.handle(.connected)
        #expect(s.handle(.backgrounded) == [.cancelRetry, .disconnect])
        #expect(s.handle(.dropped(transient)) == [])
        #expect(s.handle(.retryTimerFired) == [])
        #expect(s.handle(.pathChanged(satisfied: true)) == [])
        #expect(s.phase == .suspended)
        #expect(s.handle(.foregrounded) == [.cancelRetry, .connect])
        #expect(s.phase == .connecting(attempt: 1))
    }

    @Test func foregroundCutsAPendingBackoffShort() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        for _ in 0..<4 {
            _ = s.handle(.connectFailed(transient))
            _ = s.handle(.retryTimerFired)
        }
        _ = s.handle(.connectFailed(transient))
        #expect(s.phase == .waiting(attempt: 5, delay: .seconds(8)))
        _ = s.handle(.backgrounded)
        #expect(s.handle(.foregrounded) == [.cancelRetry, .connect])
    }

    @Test func networkChangeReplacesLiveConnection() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        _ = s.handle(.connected)
        #expect(s.handle(.pathChanged(satisfied: true)) == [.disconnect, .cancelRetry, .connect])
    }

    @Test func offlineWaitsForNetwork() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        _ = s.handle(.connected)
        // A lost path alone keeps the live connection; the drop decides.
        #expect(s.handle(.pathChanged(satisfied: false)) == [])
        #expect(s.handle(.dropped(transient)) == [.disconnect, .cancelRetry])
        #expect(s.phase == .offline)
        #expect(s.handle(.pathChanged(satisfied: true)) == [.disconnect, .cancelRetry, .connect])
    }

    @Test func nonRetryableFailureWaitsForUser() {
        var s = ConnectionSupervisor()
        _ = s.handle(.start)
        #expect(s.handle(.connectFailed(authRejected)) == [.disconnect])
        #expect(s.phase == .failed(authRejected))
        #expect(s.handle(.foregrounded) == [])
        #expect(s.handle(.pathChanged(satisfied: true)) == [])
        #expect(s.handle(.userRetry) == [.cancelRetry, .connect])
    }
}
