import Testing
@testable import HerdrAPI

@Suite struct ReadStateTests {
    @Test func firstSightIsReadAndOnlyLaterChangesCount() {
        var state = ReadState()
        _ = state.observe([("p", .done, 4)])
        #expect(!state.isUnread(pane: "p", status: .done, sequence: 4))
        #expect(state.presented(pane: "p", status: .done, sequence: 4) == .idle)
        _ = state.observe([("p", .blocked, 5)])
        #expect(state.isUnread(pane: "p", status: .blocked, sequence: 5))
    }

    /// herdr skips `done` when the pane is focused at the desk; the phone still saw it finish.
    @Test func workingToIdleIsAnUnreadFinishUntilRead() {
        var state = ReadState()
        _ = state.observe([("p", .idle, 1)])
        _ = state.observe([("p", .working, 2)])
        _ = state.observe([("p", .idle, 3)])
        #expect(state.isUnread(pane: "p", status: .idle, sequence: 3))
        #expect(state.presented(pane: "p", status: .idle, sequence: 3) == .done)
        state.markRead(pane: "p", sequence: 3)
        #expect(state.presented(pane: "p", status: .idle, sequence: 3) == .idle)
    }

    @Test func deskAcknowledgingAReadFinishKeepsItRead() {
        var state = ReadState()
        _ = state.observe([("p", .working, 1)])
        _ = state.observe([("p", .done, 2)])
        state.markRead(pane: "p", sequence: 2)
        _ = state.observe([("p", .idle, 3)])
        #expect(!state.isUnread(pane: "p", status: .idle, sequence: 3))
    }

    @Test func markUnreadMakesAReadIdleAgentAFreshFinish() {
        var state = ReadState()
        _ = state.observe([("p", .idle, 7)])
        state.markUnread(pane: "p", sequence: 7)
        #expect(state.presented(pane: "p", status: .idle, sequence: 7) == .done)
    }

    @Test func goneAgentsAreForgotten() {
        var state = ReadState()
        _ = state.observe([("p", .working, 1), ("q", .idle, 1)])
        let changed = state.observe([("q", .idle, 1)])
        #expect(changed)
        _ = state.observe([("p", .idle, 9)])
        #expect(!state.isUnread(pane: "p", status: .idle, sequence: 9))
    }
}
