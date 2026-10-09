import Foundation
import HerdrAPI
import Synchronization
import Testing

private struct Failed: Error, Equatable { var name: String }
private typealias Candidate = @Sendable () async throws -> String

/// Sleeps for `seconds` whatever cancellation says, like a TCP dial to a blackholed address
/// that only gives up at its own timeout.
private func stubbornSleep(_ seconds: Double) async {
    await withCheckedContinuation { done in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
    }
}

@Suite struct FirstSuccessTests {
    @Test func winnerReturnsWithoutWaitingForAStuckLoser() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let candidates: [Candidate] = [
            { await stubbornSleep(3); return "lan" },
            { try await Task.sleep(for: .milliseconds(50)); return "tailnet" },
        ]
        let result = try await firstSuccess(candidates, discard: { _ in })
        #expect(result.index == 1 && result.value == "tailnet")
        #expect(clock.now - start < .seconds(1))
    }

    @Test func aLoserThatSucceedsLateIsDiscarded() async throws {
        let discarded = Mutex<[String]>([])
        let candidates: [Candidate] = [
            { "fast" },
            { await stubbornSleep(0.2); return "late" },
        ]
        let result = try await firstSuccess(candidates, discard: { value in discarded.withLock { $0.append(value) } })
        #expect(result.value == "fast")
        try await Task.sleep(for: .milliseconds(500))
        #expect(discarded.withLock { $0 } == ["late"])
    }

    @Test func aFailedPrimaryLeavesTheOtherToWin() async throws {
        let candidates: [Candidate] = [
            { throw Failed(name: "tailnet") },
            { try await Task.sleep(for: .milliseconds(50)); return "lan" },
        ]
        let result = try await firstSuccess(candidates, discard: { _ in })
        #expect(result.index == 1 && result.value == "lan")
    }

    @Test func whenAllFailThePrimaryErrorIsThrown() async {
        // The primary fails first, then last: either way its error is the one shown.
        for primaryDelay in [0, 100] {
            let candidates: [Candidate] = [
                {
                    try await Task.sleep(for: .milliseconds(primaryDelay))
                    throw Failed(name: "primary")
                },
                {
                    try await Task.sleep(for: .milliseconds(50))
                    throw Failed(name: "secondary")
                },
            ]
            do {
                _ = try await firstSuccess(candidates, discard: { _ in })
                Issue.record("expected a failure")
            } catch {
                #expect(error as? Failed == Failed(name: "primary"))
            }
        }
    }

    @Test func cancellingTheCallerEndsTheRaceAtOnce() async {
        let clock = ContinuousClock()
        let start = clock.now
        let candidates: [Candidate] = [
            { await stubbornSleep(3); return "a" },
            { try await Task.sleep(for: .seconds(3)); return "b" },
        ]
        let race = Task { try await firstSuccess(candidates, discard: { _ in }) }
        try? await Task.sleep(for: .milliseconds(50))
        race.cancel()
        let result = await race.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.now - start < .seconds(1))
    }
}
