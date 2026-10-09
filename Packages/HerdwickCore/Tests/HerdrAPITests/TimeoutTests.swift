import Foundation
import HerdrAPI
import Testing

@Suite struct TimeoutTests {
    /// A call that ignores cancellation, like a blocking libtailscale call parked on GCD.
    private func stuck(_ seconds: Double) async -> Int {
        await withCheckedContinuation { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume(returning: 1) }
        }
    }

    @Test func givesUpAtTheLimitEvenWhenTheWorkIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(100)) { await self.stuck(3) }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func returnsTheResultOrErrorOfWorkThatFinishesInTime() async throws {
        #expect(try await withTimeout(.seconds(5)) { 7 } == 7)
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            try await withTimeout(.seconds(5)) { () async throws -> Int in throw Refused() }
        }
    }

    @Test func cancellingTheCallerReturnsAtOnce() async {
        let start = ContinuousClock.now
        let task = Task { try await withTimeout(.seconds(5)) { await self.stuck(3) } }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
