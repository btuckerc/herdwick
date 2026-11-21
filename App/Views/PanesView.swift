import HerdrAPI
import SwiftUI

struct PanesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(SceneState.self) private var scene
    @State private var collapsed: Set<SessionAddress> = []
    @State private var expanded: Set<SessionAddress> = []
    @State private var pendingClose: CloseTarget?
    @State private var closeError: String?
    /// The inbox row's unread gutter, scaled with its text: tab names and shells line up with
    /// the agents' titles and glyphs (round 8: three leading edges in one group).
    @ScaledMetric(relativeTo: .body) private var dotSize = 9.0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// What the user asked to close, in the session it was in then: a host can switch sessions
    /// while the alert is open, and tab and workspace IDs repeat across sessions.
    @MainActor private enum CloseTarget: @MainActor Identifiable {
        case tab(HostConnection, session: String, HerdrAPI.Tab)
        case workspace(HostConnection, session: String, Workspace)
        var id: String {
            switch self {
            case .tab(let connection, let session, let tab): "\(connection.identity.hostID)-\(session)-tab-\(tab.id)"
            case .workspace(let connection, let session, let workspace): "\(connection.identity.hostID)-\(session)-workspace-\(workspace.id)"
            }
        }
        var title: String {
            switch self {
            case .tab(_, _, let tab): "Close Tab \(tab.label)?"
            case .workspace(_, _, let workspace): "Close Workspace \(workspace.label)?"
            }
        }
    }

    private var connections: [HostConnection] {
        settings.allHosts ? model.connections : model.connection(in: scene).map { [$0] } ?? []
    }

    var body: some View {
        @Bindable var scene = scene
        List(selection: $scene.selectedRoute) {
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
                    if let skew = connection.clockSkew {
                        Label("This host's clock is \(Duration.seconds(abs(skew)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))) \(skew > 0 ? "ahead" : "behind"). Times shown may be off.",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .overlay {
            if connections.isEmpty { ContentUnavailableView("No Machines", systemImage: "server.rack", description: Text("Add a host to see its workspaces.")) }
        }
        .alert(pendingClose?.title ?? "", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }), presenting: pendingClose) { target in
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
                    if tabs.count > 1 {
                        // Under the workspace and over the agent, quieter than both (round 38: sa#13,
                        // tab names at nearly the title's scale read as rows of their own).
                        Text(tab.label).font(.footnote).foregroundStyle(Tokens.secondaryText)
                            .padding(.leading, typeSize.isAccessibilitySize ? 0 : dotSize + 6 + 22 + 10)
                    }
                    ForEach(snapshot.panes.filter { $0.tabID == tab.id }.sorted { $0.id < $1.id }) { pane in
                        if let agent = snapshot.agents.first(where: { $0.paneID == pane.id }) {
                            let address = connection.address(paneID: pane.id)
                            NavigationLink(value: agent.opensAsConversation ? Route.conversation(address) : Route.terminal(address)) {
                                // The workspace heads the group; the row needn't repeat it (round 6).
                                // Its age as the inbox's row has it (round 18 capture: "waiting 6m"
                                // here from the turn's start beside the inbox's 4m; working rows' ages).
                                let status = connection.presentedStatus(agent)
                                AgentRow(agent: agent, status: status,
                                         workspace: snapshot.workspaces.first(where: { $0.id == tab.workspaceID })?.label,
                                         unread: connection.isUnread(agent), host: settings.allHosts ? connection.profile.name : nil,
                                         lastTurnAt: connection.ageDate(agent, status: status),
                                         // Gone still, as the inbox shows it (round 31: blue Working here).
                                         quietSince: status == .working ? connection.stillSince(agent) : nil, showsPlace: false)
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                        } else {
                            NavigationLink(value: Route.terminal(connection.address(paneID: pane.id))) { shellRow(pane) }
                                .navigationLinkIndicatorVisibility(.hidden)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Close Tab", role: .destructive) {
                        pendingClose = connection.activeSession.map { .tab(connection, session: $0, tab) }
                    }
                }
            }
        } label: {
            HStack {
                Text(workspace.label)
                Text(agents.isEmpty ? "No agent yet" : "^[\(agents.count) agent](inflect: true)").font(.caption).foregroundStyle(Tokens.secondaryText)
                Spacer()
                // The app's one mark for waiting on the user.
                if agents.contains(where: { connection.presentedStatus($0) == .blocked }) {
                    Image(systemName: AgentStatus.blocked.symbol).foregroundStyle(AgentStatus.blocked.tint).accessibilityLabel("Needs you")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Close Workspace", role: .destructive) {
                    pendingClose = connection.activeSession.map { .workspace(connection, session: $0, workspace) }
                }
            }
        }
    }

    /// A pane without an agent, in the agent rows' columns: the unread gutter left empty, a
    /// terminal glyph where the status would be.
    private func shellRow(_ pane: Pane) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: dotSize, height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "apple.terminal")
                    .foregroundStyle(Tokens.secondaryText)
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
                TerminalRow(pane: pane)
            }
        }
    }

    private func expansionBinding(_ connection: HostConnection, _ workspace: Workspace) -> Binding<Bool> {
        let key = SessionAddress(hostID: connection.identity.hostID, session: "\(connection.identity.session)/\(workspace.id)")
        return Binding(get: { !collapsed.contains(key) }, set: { value in
            if value { collapsed.remove(key) } else { collapsed.insert(key) }
        })
    }

    /// Sends the close only while the host still shows that tab (in the same workspace) or
    /// workspace (same label) in the same session: herdr reuses IDs after a restart.
    @MainActor private func close(_ target: CloseTarget) async {
        pendingClose = nil
        do {
            switch target {
            case .tab(let connection, let session, let tab):
                guard let client = connection.client else { throw CloseMessage("The host is not connected.") }
                guard connection.activeSession == session,
                      connection.snapshot?.tabs.contains(where: { $0.id == tab.id && $0.workspaceID == tab.workspaceID }) == true else {
                    throw CloseMessage("Tab \(tab.label) changed or closed since you chose it. Nothing was closed.")
                }
                try await client.closeTab(tab.id, session: session)
            case .workspace(let connection, let session, let workspace):
                guard let client = connection.client else { throw CloseMessage("The host is not connected.") }
                guard connection.activeSession == session,
                      connection.snapshot?.workspaces.contains(where: { $0.id == workspace.id && $0.label == workspace.label }) == true else {
                    throw CloseMessage("Workspace \(workspace.label) changed or closed since you chose it. Nothing was closed.")
                }
                try await client.closeWorkspace(workspace.id, session: session)
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
