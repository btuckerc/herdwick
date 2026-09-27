import Foundation
import HerdrAPI

/// Pane IDs are only unique within one herdr session on one saved host.
struct PaneAddress: Hashable {
    let hostID: HostProfile.ID
    let session: String
    let paneID: String
}

struct SessionAddress: Hashable {
    let hostID: HostProfile.ID
    let session: String
}

struct Thread: Identifiable {
    let address: PaneAddress
    let connection: HostConnection
    let agent: Agent
    let workspace: Workspace?
    let tab: Tab?
    var id: PaneAddress { address }
}


/// What a thread sorts by. The inbox can hold these still while the user browses.
struct InboxRank: Equatable {
    /// Needs you, unread finish, working, idle or read finish, unknown.
    var priority: Int
    /// When the user last sent a message or the agent last finished a turn; nil while unknown.
    var lastTurnAt: Date?
}

@MainActor
func inboxRank(_ thread: Thread) -> InboxRank {
    let priority = switch thread.connection.presentedStatus(thread.agent) {
    case .blocked: 0
    case .done: 1
    case .working: 2
    case .idle: 3
    case .unknown: 4
    }
    return InboxRank(priority: priority, lastTurnAt: thread.connection.lastTurnAt(thread.agent))
}

struct InboxSection: Identifiable {
    let id: String
    let title: String
    let threads: [Thread]
    let idle: [Thread]
}

/// Recent is one timeline by last turn (a user message or a finished reply). Priority pins
/// what needs you, then orders by status, then by last turn. Unknown times sort last; ties
/// fall back to the address, never the title, so a rename cannot move a row.
@MainActor
func inboxSections(
    _ threads: [Thread],
    grouping: InboxGrouping,
    sort: InboxSort,
    collapseIdle: Bool,
    allHosts: Bool,
    rank: (Thread) -> InboxRank,
    hidden: (Thread) -> Bool
) -> (needsYou: [Thread], sections: [InboxSection], hidden: [Thread]) {
    let ranks = Dictionary(threads.map { ($0.address, rank($0)) }) { first, _ in first }
    let visible = threads.filter { !hidden($0) }
    let pins = sort == .priority
    let urgent = pins ? visible.filter { $0.agent.agentStatus == .blocked } : []
    let rest = pins ? visible.filter { $0.agent.agentStatus != .blocked } : visible
    func precedes(_ lhs: Thread, _ rhs: Thread) -> Bool {
        let left = ranks[lhs.address]!, right = ranks[rhs.address]!
        if sort == .priority, left.priority != right.priority { return left.priority < right.priority }
        switch (left.lastTurnAt, right.lastTurnAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if lhs.address.hostID != rhs.address.hostID { return lhs.address.hostID.uuidString < rhs.address.hostID.uuidString }
        if lhs.address.session != rhs.address.session { return lhs.address.session < rhs.address.session }
        return lhs.address.paneID < rhs.address.paneID
    }
    @MainActor func group(_ thread: Thread) -> (id: String, title: String) {
        switch grouping {
        case .none: return ("agents", "Agents")
        case .host: return (thread.address.hostID.uuidString, thread.connection.profile.name)
        case .workspace:
            let label = thread.workspace?.label ?? "Workspace"
            let id = "\(thread.address.hostID).\(thread.address.session).\(thread.agent.workspaceID)"
            return (id, allHosts ? "\(thread.connection.profile.name) · \(label)" : label)
        case .status:
            let label = thread.connection.presentedStatus(thread.agent).label
            return (label, label)
        }
    }
    // A group sits where its first member would: the most urgent in Priority, the latest
    // message in Recent. Folded idle members count, so expanding them never moves sections.
    let ordered = rest.sorted(by: precedes)
    var keys: [String] = []
    var groups: [String: [Thread]] = [:]
    for thread in ordered {
        let key = group(thread).id
        if groups[key] == nil { keys.append(key) }
        groups[key, default: []].append(thread)
    }
    let sections = keys.map { key -> InboxSection in
        let sorted = groups[key]!
        let idle = collapseIdle ? sorted.filter { $0.connection.presentedStatus($0.agent) == .idle } : []
        let collapsed = idle.count >= 2
        let idleIDs = Set(idle.map(\.address))
        return InboxSection(id: key, title: group(sorted[0]).title, threads: collapsed ? sorted.filter { !idleIDs.contains($0.address) } : sorted, idle: collapsed ? idle : [])
    }
    return (urgent.sorted(by: precedes), sections, threads.filter(hidden).sorted(by: precedes))
}
extension AppModel {
    var threads: [Thread] {
        connections.flatMap { connection in
            guard let snapshot = connection.snapshot, connection.activeSession != nil else { return [Thread]() }
            let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
            let tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
            return snapshot.agents.map { agent in
                Thread(address: connection.address(paneID: agent.paneID), connection: connection,
                       agent: agent, workspace: workspaces[agent.workspaceID], tab: tabs[agent.tabID])
            }
        }
    }
}
