import ActivityKit
import Foundation
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
    private var detail: String?
    /// What the agent asks while it needs the user: the card's line then, not its last step
    /// (round 45: sb#2, "Needs you" over "Running bun test").
    private var asking: String?
    /// When the current run began; moves on when work resumes after an answer (`ContentState.since`).
    private var since: Date?
    /// What the finished run came to, its caution first, for the card it leaves (round 48: sb#5,
    /// a Done card kept "Running bun test…"). Nil without previews: then it says to open it.
    private var result: String?

    /// `since` is when the watched turn began, if known, else now; the card counts up from it.
    /// `detail` is its latest step, as `updateDetail` keeps it.
    func start(connection: HostConnection, agent: Agent, since: Date?, detail: String?, push: Push?) async {
        await stop(push: push)
        self.detail = detail
        self.since = since ?? .now
        asking = nil
        result = nil
        guard connection.isLive, agent.agentStatus == .working, let reference = agent.agentSession?.value else {
            error = "Watch a live, working conversation."; return
        }
        do {
            // Retire any activity left by a terminated app: there is only one watched run.
            for old in Activity<WatchedRunAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
            let address = connection.address(paneID: agent.paneID)
            let link = AttentionLink.url(host: address.hostID, session: address.session, pane: address.paneID)
            let place = connection.snapshot?.workspaces.first { $0.id == agent.workspaceID }?.displayLabel
            let attributes = WatchedRunAttributes(title: agent.conversationTitle, host: connection.profile.name,
                                                  place: place, link: link)
            let activity = try Activity.request(attributes: attributes,
                                                content: content("working"), pushType: .token)
            self.activity = activity
            self.address = address
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

    func changed(_ link: HostConnection, previews: Bool, push: Push?) {
        guard link.isLive, let address, address.hostID == link.identity.hostID, address.session == link.identity.session,
              let activity else { return }
        let agent = link.snapshot?.agents.first { $0.paneID == address.paneID && $0.agentSession?.value == reference }
        let presented = agent.map { link.presentedStatus($0) }
        let status: String
        switch presented {
        case .working: status = "working"
        case .blocked: status = "blocked"
        case .done, .idle: status = "done"
        // Gone from herdr (closed, or another agent in its pane) is not a finished run: no green
        // Done, no result from an earlier turn (round 49: sb#2).
        case nil: status = "closed"
        default: return
        }
        asking = status == "blocked" ? agent.flatMap { link.wait($0)?.summary } : nil
        if let agent, let presented {
            if let resumed = link.workingSince(agent, status: presented) { since = resumed }
            result = link.caution(agent, status: presented, previews: previews)
                ?? (status == "done" ? link.rowLine(agent, status: presented, previews: previews) : nil)
        }
        let id = activity.id, content = content(status)
        Task {
            if status == "done" || status == "closed" { await stop(push: push, finished: true, status: status) }
            else { await Self.live(id)?.update(content) }
        }
    }

    /// A fresh handle for the activity, so no main-actor-held reference crosses into ActivityKit.
    private nonisolated static func live(_ id: String) -> Activity<WatchedRunAttributes>? {
        Activity<WatchedRunAttributes>.activities.first { $0.id == id }
    }

    /// A finished run leaves its "done" (or "closed") card up for a while; removing it by hand
    /// clears it at once.
    func stop(push: Push?, finished: Bool = false, status: String = "done") async {
        let old = activity?.id
        tokenTask?.cancel(); tokenTask = nil
        stateTask?.cancel(); stateTask = nil
        activity = nil; address = nil; reference = nil
        push?.watchedRun = nil
        if let old { await Self.live(old)?.end(content(status), dismissalPolicy: finished ? .default : .immediate) }
    }

    private func content(_ status: String) -> ActivityContent<WatchedRunAttributes.ContentState> {
        let line = switch status {
        case "blocked": asking ?? detail
        case "done": result ?? "Finished. Open to read the result."
        case "closed": "No longer running in herdr."
        default: detail
        }
        return ActivityContent(state: .init(status: status, detail: line, since: since),
                               staleDate: .now.addingTimeInterval(4 * 3600))
    }

    /// The watched conversation's latest step; any other conversation's is ignored (round 46:
    /// sb#1, every open thread fed it, so another agent's command could show under this title).
    func updateDetail(_ detail: String?, from address: PaneAddress) {
        guard address == self.address, self.detail != detail else { return }
        self.detail = detail
        guard let activity else { return }
        let id = activity.id
        let content = content(activity.content.state.status)
        Task { await Self.live(id)?.update(content) }
    }
}
