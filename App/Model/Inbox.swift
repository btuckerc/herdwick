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
    /// This agent as it is now; capture it when the user picks the agent, not when acting.
    @MainActor var stamp: AgentStamp? { connection.stamp(of: agent) }
}

/// One agent in its pane. herdr reuses a pane when its agent exits and another starts there,
/// with the same pane ID and, without an integration, no transcript reference to tell them
/// apart; `epoch` changes whenever a snapshot shows the pane's agent gone, or a different kind
/// or conversation in it. A confirmed action carries the stamp and runs only while it matches.
/// Not caught: an agent of the same kind with no reference that exits and restarts entirely
/// between two snapshots (herdr reports both status changes, so that window is short).
struct AgentStamp: Hashable {
    let session: String
    let paneID: String
    let epoch: Int
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

/// The one order of what wants the user, shared by the inbox's Needs You, the Overview, the
/// dock and Next/⌘J: needs you before an unread finish, then the latest turn first, as the
/// inbox lists them, so Next is always the top row the user sees (round 7: the three had three
/// orders, one of them by a sequence only comparable within a session). Ties fall back to the
/// address, never the title.
@MainActor
func attentionPrecedes(_ lhs: Thread, _ rhs: Thread) -> Bool {
    let left = inboxRank(lhs).priority, right = inboxRank(rhs).priority
    return left != right ? left < right : latestTurnPrecedes(lhs, rhs)
}

/// The latest turn first, unknown times last, then the address.
@MainActor
func latestTurnPrecedes(_ lhs: Thread, _ rhs: Thread) -> Bool {
    switch (lhs.connection.lastTurnAt(lhs.agent), rhs.connection.lastTurnAt(rhs.agent)) {
    case let (l?, r?) where l != r: return l > r
    case (.some, nil): return true
    case (nil, .some): return false
    default: return addressPrecedes(lhs.address, rhs.address)
    }
}

func addressPrecedes(_ lhs: PaneAddress, _ rhs: PaneAddress) -> Bool {
    if lhs.hostID != rhs.hostID { return lhs.hostID.uuidString < rhs.hostID.uuidString }
    if lhs.session != rhs.session { return lhs.session < rhs.session }
    return lhs.paneID < rhs.paneID
}

struct InboxSection: Identifiable {
    let id: String
    let title: String
    let threads: [Thread]
    let idle: [Thread]
}

/// Recent is one timeline by last turn (a user message or a finished reply). Priority orders
/// by status, then by last turn. Either way what needs you is pinned above, by its rank, so a
/// held order holds Needs You's membership too. Unknown times sort last; ties fall back to the
/// address, never the title, so a rename cannot move a row.
@MainActor
func inboxSections(
    _ threads: [Thread],
    grouping: InboxGrouping,
    sort: InboxSort,
    collapseIdle: Bool,
    allHosts: Bool,
    heldStatus: ((Thread) -> AgentStatus)? = nil,
    rank: (Thread) -> InboxRank,
    hidden: (Thread) -> Bool
) -> (needsYou: [Thread], sections: [InboxSection], hidden: [Thread]) {
    let ranks = Dictionary(threads.map { ($0.address, rank($0)) }) { first, _ in first }
    let visible = threads.filter { !hidden($0) }
    let urgent = visible.filter { ranks[$0.address]!.priority == 0 }
    let rest = visible.filter { ranks[$0.address]!.priority != 0 }
    func precedes(_ lhs: Thread, _ rhs: Thread) -> Bool {
        let left = ranks[lhs.address]!, right = ranks[rhs.address]!
        if sort == .priority, left.priority != right.priority { return left.priority < right.priority }
        switch (left.lastTurnAt, right.lastTurnAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        return addressPrecedes(lhs.address, rhs.address)
    }
    func status(_ thread: Thread) -> AgentStatus {
        heldStatus?(thread) ?? thread.connection.presentedStatus(thread.agent)
    }

    @MainActor func group(_ thread: Thread) -> (id: String, title: String) {
        switch grouping {
        case .none: return ("agents", "Agents")
        case .host: return (thread.address.hostID.uuidString, thread.connection.profile.name)
        case .workspace:
            let label = thread.workspace?.displayLabel ?? "Workspace"
            let id = "\(thread.address.hostID).\(thread.address.session).\(thread.agent.workspaceID)"
            return (id, allHosts ? "\(thread.connection.profile.name) · \(label)" : label)
        case .status:
            let label = status(thread).section
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
    let orderedKeys: [String]
    if grouping == .status {
        // The dock's lane order: results waiting to be read before agents still at work.
        let priority = ["Done", "Working", "Read", "Unknown"]
        orderedKeys = keys.sorted {
            let left = priority.firstIndex(of: group(groups[$0]![0]).title) ?? priority.count
            let right = priority.firstIndex(of: group(groups[$1]![0]).title) ?? priority.count
            return left == right ? keys.firstIndex(of: $0)! < keys.firstIndex(of: $1)! : left < right
        }
    } else {
        orderedKeys = keys
    }
    let sections = orderedKeys.map { key -> InboxSection in
        let sorted = groups[key]!
        // Grouped by status, idle rows already sit last under their own header.
        let idle = collapseIdle && grouping != .status ? sorted.filter { status($0) == .idle } : []
        let collapsed = idle.count >= 2
        let idleIDs = Set(idle.map(\.address))
        return InboxSection(id: key, title: group(sorted[0]).title, threads: collapsed ? sorted.filter { !idleIDs.contains($0.address) } : sorted, idle: collapsed ? idle : [])
    }
    return (urgent.sorted(by: precedes), sections, threads.filter(hidden).sorted(by: precedes))
}
extension AppModel {
    /// What the scene's inbox lists before search: one host or all of them, and only what
    /// needs you under Needs You Only.
    func inboxThreads(in scene: SceneState) -> [Thread] {
        scopedThreads(in: scene).filter { !scene.needsYouOnly || $0.connection.presentedStatus($0.agent) == .blocked }
    }

    /// The scene's hosts: every one under All Hosts, else the scene's.
    func scopedConnections(in scene: SceneState) -> [HostConnection] {
        settings.allHosts && demo == nil ? connections : connection(in: scene).map { [$0] } ?? []
    }

    /// The scene's hosts' agents, before Needs You Only.
    func scopedThreads(in scene: SceneState) -> [Thread] {
        let hosts = scopedConnections(in: scene)
        return threads.filter { thread in hosts.contains { $0 === thread.connection } }
    }

    /// What the agent dock offers: the scene's hosts' agents without Hidden or Ended. Not
    /// narrowed by Needs You Only, a filter on the inbox's list (round 40: sb#2, with it on, the
    /// dock and the keyboard's agent walk lost every working and finished agent).
    func dockThreads(in scene: SceneState) -> [Thread] {
        scopedThreads(in: scene).filter { $0.connection.hidden[$0.agent.paneID] == nil }
    }

    var threads: [Thread] {
        connections.flatMap { connection in
            guard let snapshot = connection.snapshot, connection.activeSession != nil else { return [Thread]() }
            let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
            let tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
            return snapshot.agents.filter { !connection.closing.contains($0.paneID) }.map { agent in
                Thread(address: connection.address(paneID: agent.paneID), connection: connection,
                       agent: agent, workspace: workspaces[agent.workspaceID], tab: tabs[agent.tabID])
            }
        }
    }
}
