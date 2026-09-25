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


struct InboxSection: Identifiable {
    let id: String
    let title: String
    let threads: [Thread]
    let idle: [Thread]
}

@MainActor
func inboxSections(
    _ threads: [Thread],
    grouping: InboxGrouping,
    sort: InboxSort,
    collapseIdle: Bool,
    allHosts: Bool,
    lastChange: [PaneAddress: Date],
    hidden: (Thread) -> Bool
) -> (needsYou: [Thread], sections: [InboxSection], hidden: [Thread]) {
    let visible = threads.filter { !hidden($0) }
    let urgent = visible.filter { $0.agent.agentStatus == .blocked }
    let rest = visible.filter { $0.agent.agentStatus != .blocked }
    @MainActor func priority(_ thread: Thread) -> Int {
        let status = thread.agent.agentStatus
        if status == .blocked { return 0 }
        if status == .done && thread.connection.isUnread(thread.agent) { return 1 }
        if status == .working { return 2 }
        if status == .done || status == .idle { return 3 }
        return 4
    }
    @MainActor func precedes(_ lhs: Thread, _ rhs: Thread) -> Bool {
        if sort == .priority, priority(lhs) != priority(rhs) {
            return priority(lhs) < priority(rhs)
        }
        let left = lastChange[lhs.address] ?? .distantPast
        let right = lastChange[rhs.address] ?? .distantPast
        if left != right { return left > right }
        let titleOrder = lhs.agent.conversationTitle.localizedCaseInsensitiveCompare(rhs.agent.conversationTitle)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
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
        case .status: return (thread.agent.agentStatus.label, thread.agent.agentStatus.label)
        }
    }
    // In priority mode the most urgent member determines a group's position.
    // In recent mode the most recently changed member does.
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
        let idle = collapseIdle ? sorted.filter { $0.agent.agentStatus == .idle && !$0.connection.isUnread($0.agent) } : []
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
