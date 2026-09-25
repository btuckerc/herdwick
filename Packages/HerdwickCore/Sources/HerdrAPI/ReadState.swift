/// What this phone has read, per pane, kept apart from the host's own state.
///
/// herdr reports a finished agent as `done` only while nobody at the desk has looked; a
/// finish in the focused pane goes straight to `idle`. So a finish is either `done`, or a
/// `working` agent seen to stop. Reading records the `state_change_seq` on screen; the desk
/// acknowledging later bumps the sequence without making it unread again.
public struct ReadState: Codable, Equatable, Sendable {
    /// Pane → the sequence last read here.
    var seen: [String: Int] = [:]
    /// Pane → the sequence at which it was seen to stop working.
    var finished: [String: Int] = [:]
    /// Panes last seen working.
    var working: Set<String> = []

    public init() {}

    /// Records a snapshot's agents. A pane seen for the first time starts read.
    /// Returns whether anything worth saving changed.
    public mutating func observe(_ agents: [(pane: String, status: AgentStatus, sequence: Int)]) -> Bool {
        let before = self
        for agent in agents {
            if seen[agent.pane] == nil { seen[agent.pane] = agent.sequence }
            if agent.status == .working {
                working.insert(agent.pane)
            } else if working.remove(agent.pane) != nil, agent.status == .idle || agent.status == .done {
                finished[agent.pane] = agent.sequence
            }
        }
        let live = Set(agents.map(\.pane))
        seen = seen.filter { live.contains($0.key) }
        finished = finished.filter { live.contains($0.key) }
        working.formIntersection(live)
        return self != before
    }

    /// Waiting on you, or finished, since it was last read here.
    public func isUnread(pane: String, status: AgentStatus, sequence: Int) -> Bool {
        guard let last = seen[pane] else { return false }
        switch status {
        case .blocked, .done: return sequence > last
        case .idle: return (finished[pane] ?? .min) > last
        case .working, .unknown: return false
        }
    }

    /// What a row shows: an unread finish is done, a read one is idle.
    public func presented(pane: String, status: AgentStatus, sequence: Int) -> AgentStatus {
        guard status == .done || status == .idle else { return status }
        return isUnread(pane: pane, status: status, sequence: sequence) ? .done : .idle
    }

    public mutating func markRead(pane: String, sequence: Int) {
        seen[pane] = sequence
    }

    /// A local reminder: it reads as a fresh finish until opened again.
    public mutating func markUnread(pane: String, sequence: Int) {
        finished[pane] = sequence
        seen[pane] = sequence - 1
    }
}
