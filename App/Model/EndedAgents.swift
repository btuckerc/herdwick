import Foundation
import HerdrAPI
import SwiftUI

struct EndedAgent: Codable, Identifiable, Hashable {
    let hostID: UUID
    let session: String
    let harness: String
    let reference: AgentSessionRef
    var transcriptPath: String?
    var paneID: String
    var cwd: String?
    var workspaceID: String
    var workspaceLabel: String
    var title: String
    var observedAt: Date
    var ended = false
    var id: String { [hostID.uuidString, session, harness, reference.kind, reference.value].joined(separator: "\u{1f}") }
    var arguments: [String] { [harness == "codex" ? "resume" : "--resume", reference.value] }
}

/// A descriptor shelf, not a transcript archive. Only authoritative snapshots reconcile exits.
@MainActor @Observable
final class EndedAgents {
    static let shared = EndedAgents()
    private(set) var entries: [EndedAgent]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "endedAgents.v1").flatMap { try? JSONDecoder().decode([EndedAgent].self, from: $0) } ?? []
    }

    func observe(_ snapshot: Snapshot, hostID: UUID, session: String, paths: [String: String]) {
        let now = Date()
        var next = entries
        var live = Set<String>()
        for agent in snapshot.agents {
            guard let ref = agent.agentSession, ["omp", "claude", "codex"].contains(ref.agent),
                  !ref.value.isEmpty, ref.agent != "omp" || ref.transcriptPath != nil else { continue }
            let workspace = snapshot.workspaces.first { $0.id == agent.workspaceID }
            var item = EndedAgent(hostID: hostID, session: session, harness: ref.agent, reference: ref,
                                  transcriptPath: paths[agent.paneID] ?? ref.transcriptPath, paneID: agent.paneID,
                                  cwd: agent.cwd, workspaceID: agent.workspaceID, workspaceLabel: workspace?.label ?? agent.workspaceID,
                                  title: agent.conversationTitle, observedAt: now)
            live.insert(item.id)
            if let index = next.firstIndex(where: { $0.id == item.id }) {
                let previous = next[index]
                item.transcriptPath = item.transcriptPath ?? previous.transcriptPath
                item.observedAt = previous.observedAt
                if item != previous { item.observedAt = now }
                next[index] = item
            } else { next.append(item) }
        }
        for index in next.indices where next[index].hostID == hostID && next[index].session == session {
            if !next[index].ended, !live.contains(next[index].id) {
                // A temporarily missing session reference is not proof of an exit.
                let occupant = snapshot.agents.first { $0.paneID == next[index].paneID }
                if occupant == nil || occupant?.agentSession != nil {
                    next[index].ended = true
                    next[index].observedAt = now
                }
            }
        }
        next.sort { $0.observedAt > $1.observedAt }
        next = Array(next.prefix(50))
        guard next != entries else { return }
        entries = next
        save()
    }

    func remove(_ item: EndedAgent) {
        guard entries.contains(where: { $0.id == item.id }) else { return }
        entries.removeAll { $0.id == item.id }
        save()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(entries), forKey: "endedAgents.v1") }
}

/// A confirmed `integration.install` for harnesses the host has but herdr isn't hooked into.
/// Contextual surfaces pass the agent's harness; host settings pass nil to list every missing one.
/// Never gates agent launch or the terminal.
struct IntegrationOffer: View {
    let connection: HostConnection
    var harness: String? = nil
    /// A toolbar icon rather than a labelled button.
    var compact = false
    @State private var installing: String?
    @State private var confirmation: IntegrationInfo?
    @State private var error: String?

    var body: some View {
        ForEach(connection.missingIntegrations.filter { harness == nil || $0.target == harness }) { integration in
            let button = Button { confirmation = integration } label: {
                Label("Install \(integration.label) Integration", systemImage: "puzzlepiece.extension")
            }
            .disabled(!connection.isLive || installing != nil)
            if compact { button.labelStyle(.iconOnly) } else { button }
        }
        .confirmationDialog("Install \(confirmation?.label ?? "") integration on \(connection.profile.name)?",
                            isPresented: .init(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { integration in
            Button("Install Integration") {
                Task {
                    installing = integration.target
                    defer { installing = nil }
                    do { try await connection.installIntegration(integration.target) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { integration in
            Text("Lets Herdwick open \(integration.label) conversations and see when it's working, waiting for you or idle. This changes \(integration.label)'s configuration on \(connection.profile.name); restart running \(integration.label) agents afterwards. The terminal works without it.")
        }
        .alert("Integration Installation Failed", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct EndedAgentView: View {
    let item: EndedAgent
    let connection: HostConnection
    let resume: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let path, let format = TranscriptFormat(agent: item.harness) {
                    SubagentConversationView(connection: connection, path: path, format: format, title: item.title)
                } else if let error {
                    ContentUnavailableView("Transcript Unavailable", systemImage: "text.document", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Resume in New Tab", systemImage: "play", action: resume)
                    .buttonStyle(.glassProminent).disabled(!connection.isLive).padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .navigationTitle(item.title)
            .task(id: connection.liveID) {
                if let known = item.transcriptPath { path = known; return }
                guard let client = connection.client else { error = "Reconnect to read this ended conversation."; return }
                do {
                    path = try await client.locateTranscript(item.reference, pane: item.paneID, session: item.session)?.path
                    if path == nil { error = "The agent's transcript isn't on the host." }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
