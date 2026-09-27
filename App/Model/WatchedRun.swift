import ActivityKit
import HerdrAPI
import Observation

@MainActor @Observable
final class WatchedRun {
    private(set) var address: PaneAddress?
    private(set) var error: String?
    private var reference: String?
    private var activity: Activity<WatchedRunAttributes>?
    private var tokenTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    func start(connection: HostConnection, agent: Agent, push: Push?) async {
        await stop(push: push)
        guard connection.isLive, agent.agentStatus == .working, let reference = agent.agentSession?.value else {
            error = "Watch a live, working conversation."; return
        }
        do {
            // Retire any activity left by a terminated app: there is only one watched run.
            for old in Activity<WatchedRunAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
            let activity = try Activity.request(attributes: WatchedRunAttributes(title: agent.conversationTitle, host: connection.profile.name),
                                                content: content("working"), pushType: .token)
            self.activity = activity
            self.address = connection.address(paneID: agent.paneID)
            self.reference = reference
            error = nil
            tokenTask = Task { [weak self] in
                for await token in activity.pushTokenUpdates {
                    guard let self, self.activity?.id == activity.id, let address = self.address else { return }
                    push?.watchedRun = (address, token.map { String(format: "%02x", $0) }.joined())
                }
            }
            stateTask = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    if state == .ended || state == .dismissed {
                        guard let self, self.activity?.id == activity.id else { return }
                        self.tokenTask?.cancel()
                        self.activity = nil; self.address = nil; self.reference = nil
                        push?.watchedRun = nil
                        return
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func changed(_ link: HostConnection, push: Push?) {
        guard link.isLive, let address, address.hostID == link.identity.hostID, address.session == link.identity.session,
              let activity else { return }
        let agent = link.snapshot?.agents.first { $0.paneID == address.paneID && $0.agentSession?.value == reference }
        let status: String
        switch agent?.agentStatus {
        case .working: status = "working"
        case .blocked: status = "blocked"
        case .done, .idle, nil: status = "done"
        default: return
        }
        let id = activity.id, content = content(status)
        Task {
            if status == "done" { await stop(push: push, status: status) }
            else { await Self.live(id)?.update(content) }
        }
    }

    /// A fresh handle for the activity, so no main-actor-held reference crosses into ActivityKit.
    private nonisolated static func live(_ id: String) -> Activity<WatchedRunAttributes>? {
        Activity<WatchedRunAttributes>.activities.first { $0.id == id }
    }

    func stop(push: Push?, status: String = "done") async {
        let old = activity?.id
        tokenTask?.cancel(); tokenTask = nil
        stateTask?.cancel(); stateTask = nil
        activity = nil; address = nil; reference = nil
        push?.watchedRun = nil
        if let old { await Self.live(old)?.end(content(status), dismissalPolicy: .default) }
    }

    private func content(_ status: String) -> ActivityContent<WatchedRunAttributes.ContentState> {
        ActivityContent(state: .init(status: status), staleDate: .now.addingTimeInterval(4 * 3600))
    }
}
