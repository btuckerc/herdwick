import HerdrAPI
import SwiftUI

struct NewThreadSheet: View {
    enum Kind: Equatable { case agent, workspace }

    let connection: HostConnection
    let kind: Kind
    let workspaceID: String?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var agentKind = "omp"
    @State private var selectedWorkspace = ""
    @State private var label = ""
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var running = false
    @State private var error: String?
    @State private var createdPane: String?
    @State private var startFlow = AgentStartFlow()

    init(connection: HostConnection, kind: Kind, workspaceID: String?, onCreated: @escaping (String) -> Void) {
        self.connection = connection
        self.kind = kind
        self.workspaceID = workspaceID
        self.onCreated = onCreated
        _selectedWorkspace = State(initialValue: workspaceID ?? "")
        _agentKind = State(initialValue: connection.lastAgentKind)
    }

    private var workspaces: [Workspace] { connection.snapshot?.workspaces ?? [] }
    private var creatingWorkspace: Bool { kind == .workspace || selectedWorkspace == "__new" || workspaces.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if kind == .agent {
                    Picker("Agent", selection: $agentKind) {
                        ForEach(["omp", "claude", "codex"], id: \.self) { Text($0).tag($0) }
                    }
                    if !workspaces.isEmpty {
                        Picker("Workspace", selection: $selectedWorkspace) {
                            Text("New workspace").tag("__new")
                            ForEach(workspaces) { Text($0.label).tag($0.id) }
                        }
                    }
                }
                TextField("Label (optional)", text: $label)
                TextField("Working directory (optional)", text: $cwd)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if kind == .agent {
                    TextField("First prompt (optional)", text: $prompt, axis: .vertical).lineLimit(3...6)
                }
                if let createdPane {
                    Label("Terminal created: \(createdPane)", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if running || startFlow.running { ProgressView(startFlow.running ? "Starting \(agentKind)…" : "Creating terminal…") }
            }
            .navigationTitle(kind == .agent ? "New Agent" : "New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(running || startFlow.running) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }.disabled(running || startFlow.running || !connection.isLive)
                }
            }
        }
        .modifier(AgentStartFeedback(flow: startFlow, onStarted: finishStart))
    }

    @MainActor private func create() async {
        guard !running, let client = connection.client, let session = connection.activeSession else { return }
        running = true
        error = nil
        createdPane = nil
        defer { running = false }
        do {
            let root: Pane
            if creatingWorkspace {
                root = try await client.createWorkspace(label: clean(label), cwd: clean(cwd), session: session).rootPane
            } else {
                root = try await client.createTab(workspaceID: selectedWorkspace, label: clean(label), cwd: clean(cwd), session: session).rootPane
            }
            createdPane = root.id
            if kind == .workspace {
                onCreated(root.id)
                dismiss()
                return
            }
            let request = AgentStartFlow.Request(connection: connection,
                                                 address: PaneAddress(hostID: connection.profile.id, session: session, paneID: root.id),
                                                 kind: agentKind)
            await startFlow.start(request, onStarted: finishStart)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finishStart(_ agent: Agent, _ address: PaneAddress) async {
        do {
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let client = connection.client else { throw HerdrError.noResponse }
                _ = try await client.promptAgent(agent.paneID, text: prompt, session: address.session)
            }
            onCreated(address.paneID)
            dismiss()
        } catch {
            self.error = "The agent started, but the first prompt wasn't delivered: \(error.localizedDescription)"
        }
    }

    private func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
