import Foundation
import HerdrTestSupport
import Synchronization
import Testing
@testable import HerdrAPI

@Suite(.timeLimit(.minutes(1))) struct ChannelLifetimeTests {
    @Test func collectClosesOnSuccessAndFailure() async throws {
        let success = LifetimeChannel()
        success.continuation.yield([1, 2, 3])
        success.continuation.finish()
        #expect(try await HerdrClient.collect(success) == [1, 2, 3])
        #expect(success.closed.withLock { $0 })

        let failure = LifetimeChannel()
        failure.continuation.finish(throwing: CommandError.channelClosed)
        await #expect(throws: CommandError.channelClosed) { try await HerdrClient.collect(failure) }
        #expect(failure.closed.withLock { $0 })
    }

    @Test func cancelledCollectClosesEvenWhileEOFIsBlocked() async throws {
        let channel = LifetimeChannel(blockInput: true)
        let task = Task { try await HerdrClient.collect(channel) }
        for await _ in channel.started { break }
        task.cancel()
        _ = await task.result
        #expect(channel.closed.withLock { $0 })
    }

    @Test func terminalCloseDoesNotWaitForBlockedRelease() async {
        let channel = LifetimeChannel(blockInput: true)
        let start = ContinuousClock.now
        await TerminalSession(channel: channel).close()
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(channel.closed.withLock { $0 })
    }

    /// A child that exits before stdin closes must not leave a watcher holding the pipes.
    @Test func stdinWatcherReapsAfterEarlyChildExit() async throws {
        let channel = try await LocalProcessRunner().exec(HerdrClient.untilInputCloses("printf done"))
        var bytes: [UInt8] = []
        for try await chunk in channel.output { bytes += chunk }
        await channel.close()
        #expect(String(decoding: bytes, as: UTF8.self) == "done")
    }
}

private final class LifetimeChannel: ExecChannel {
    let output: AsyncThrowingStream<[UInt8], any Error>
    let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    let started: AsyncStream<Void>
    private let start: AsyncStream<Void>.Continuation
    private let blockInput: Bool
    let closed = Mutex(false)
    private let pending = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    init(blockInput: Bool = false) {
        self.blockInput = blockInput
        (output, continuation) = AsyncThrowingStream.makeStream()
        (started, start) = AsyncStream.makeStream()
    }

    private func input() async throws {
        guard blockInput else { return }
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            pending.withLock { pending in
                if closed.withLock({ $0 }) { waiter.resume(throwing: CommandError.channelClosed) }
                else { pending = waiter }
            }
            start.yield()
        }
    }

    func write(_ bytes: [UInt8]) async throws { try await input() }
    func closeInput() async throws { try await input() }
    func close() async {
        let waiter = pending.withLock { pending in
            closed.withLock { $0 = true }
            defer { pending = nil }
            return pending
        }
        waiter?.resume(throwing: CommandError.channelClosed)
        continuation.finish()
    }
}
