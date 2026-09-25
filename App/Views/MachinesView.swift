import HerdrAPI
import SwiftUI

struct MachinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @State private var collapsed: Set<SessionAddress> = []
    @State private var expanded: Set<SessionAddress> = []
    @State private var pendingClose: CloseTarget?
    @State private var closeError: String?

    @MainActor private enum CloseTarget: @MainActor Identifiable {
        case tab(HostConnection, HerdrAPI.Tab)
        case workspace(HostConnection, Workspace)
        var id: String {
            switch self {
            case .tab(let connection, let tab): "\(connection.identity.hostID)-\(connection.identity.session)-tab-\(tab.id)"
            case .workspace(let connection, let workspace): "\(connection.identity.hostID)-\(connection.identity.session)-workspace-\(workspace.id)"
            }
        }
        var title: String {
            switch self {
            case .tab(_, let tab): "Close Tab \(tab.label)?"
            case .workspace(_, let workspace): "Close Workspace \(workspace.label)?"
            }
        }
    }

    private var connections: [HostConnection] {
        settings.allHosts ? model.connections : model.connection.map { [$0] } ?? []
    }

    var body: some View {
        List {
            ForEach(connections, id: \.identity) { connection in
                Section("\(connection.profile.name) · \(connection.activeSession ?? connection.profile.session ?? "Session")") {
                    if let snapshot = connection.snapshot {
                        let workspaces = snapshot.workspaces.sorted { $0.number < $1.number }
                        ForEach(workspaces) { workspace in
                            workspaceGroup(workspace, connection: connection, snapshot: snapshot)
                        }
                    } else if case .failed(let failure) = connection.phase {
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    }
                }
            }
        }
        .overlay {
            if connections.isEmpty { ContentUnavailableView("No Machines", systemImage: "server.rack", description: Text("Add a host to see its workspaces.")) }
        }
        .confirmationDialog(pendingClose?.title ?? "", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }), presenting: pendingClose) { target in
            Button("Close", role: .destructive) { Task { await close(target) } }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: { _ in Text("This cannot be undone.") }
        .alert("Couldn't close", isPresented: Binding(get: { closeError != nil }, set: { if !$0 { closeError = nil } })) {
            Button("OK", role: .cancel) { closeError = nil }
        } message: { Text(closeError ?? "") }
    }

    @ViewBuilder private func workspaceGroup(_ workspace: Workspace, connection: HostConnection, snapshot: Snapshot) -> some View {
        let agents = snapshot.agents.filter { $0.workspaceID == workspace.id }
        DisclosureGroup(isExpanded: expansionBinding(connection, workspace)) {
            let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.id }.sorted { $0.number < $1.number }
            ForEach(tabs) { tab in
                VStack(alignment: .leading, spacing: 4) {
                    if tabs.count > 1 { Text(tab.label).font(.subheadline.weight(.medium)) }
                    ForEach(snapshot.panes.filter { $0.tabID == tab.id }.sorted { $0.id < $1.id }) { pane in
                        if let agent = snapshot.agents.first(where: { $0.paneID == pane.id }) {
                            let address = connection.address(paneID: pane.id)
                            NavigationLink(value: agent.hasTranscript ? Route.conversation(address) : Route.terminal(address)) {
                                AgentRow(agent: agent, status: connection.presentedStatus(agent),
                                         workspace: snapshot.workspaces.first(where: { $0.id == tab.workspaceID })?.label,
                                         unread: connection.isUnread(agent), host: settings.allHosts ? connection.profile.name : nil)
                            }
                        } else {
                            NavigationLink(value: Route.terminal(connection.address(paneID: pane.id))) { TerminalRow(pane: pane) }
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Close Tab", role: .destructive) { pendingClose = .tab(connection, tab) }
                }
            }
        } label: {
            HStack {
                Text(workspace.label)
                Text(agents.isEmpty ? "No agent yet" : "\(agents.count) agents").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if agents.contains(where: { $0.agentStatus == .blocked }) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange).accessibilityLabel("Needs you")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Close Workspace", role: .destructive) { pendingClose = .workspace(connection, workspace) }
            }
        }
    }

    private func expansionBinding(_ connection: HostConnection, _ workspace: Workspace) -> Binding<Bool> {
        let key = SessionAddress(hostID: connection.identity.hostID, session: "\(connection.identity.session)/\(workspace.id)")
        return Binding(get: { !collapsed.contains(key) }, set: { value in
            if value { collapsed.remove(key) } else { collapsed.insert(key) }
        })
    }

    @MainActor private func close(_ target: CloseTarget) async {
        pendingClose = nil
        do {
            switch target {
            case .tab(let connection, let tab):
                guard let client = connection.client else { throw CloseMessage("The host is not connected.") }
                try await client.closeTab(tab.id, session: connection.activeSession ?? connection.identity.session)
            case .workspace(let connection, let workspace):
                guard let client = connection.client else { throw CloseMessage("The host is not connected.") }
                try await client.closeWorkspace(workspace.id, session: connection.activeSession ?? connection.identity.session)
            }
        } catch {
            let message = String(describing: error).lowercased()
            if message.contains("confirmation") { closeError = "This close requires confirmation from herdr." }
            else if message.contains("group") { closeError = "This workspace belongs to a group. Close the workspace group in herdr first." }
            else { closeError = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        }
    }
}

private struct CloseMessage: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
