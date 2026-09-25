import HerdrAPI
import SwiftUI

func agentKindLabel(_ kind: String) -> String {
    switch kind {
    case "omp": "OMP"
    case "claude": "Claude"
    case "codex": "Codex"
    default: kind
    }
}

@MainActor @Observable
final class AgentStartFlow {
    struct Request {
        let connection: HostConnection
        let address: PaneAddress
        let kind: String
    }

    var running = false
    var pending: Request?
    var busyCommand: String?
    var error: String?

    func start(_ request: Request, inNewTab: Bool = false, onStarted: @MainActor (Agent, PaneAddress) async -> Void) async {
        guard !running else { return }
        running = true
        pending = nil
        busyCommand = nil
        defer { running = false }
        do {
            guard request.connection.activeSession == request.address.session else { throw HerdrError.noResponse }
            switch try await request.connection.startAgent(kind: request.kind, paneID: request.address.paneID, inNewTab: inNewTab) {
            case .busy(let command):
                pending = request
                busyCommand = command
            case .started(let agent, let address):
                await onStarted(agent, address)
            }
        } catch {
            self.error = "\(request.kind) didn't start on \(request.connection.profile.name). Is it installed? \(error.localizedDescription)"
        }
    }
}

struct AgentStartFeedback: ViewModifier {
    @Bindable var flow: AgentStartFlow
    let onStarted: @MainActor (Agent, PaneAddress) async -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Shell is running \(flow.busyCommand ?? "a command")", isPresented: .init(
                get: { flow.pending != nil }, set: { if !$0 { flow.pending = nil } }
            ), titleVisibility: .visible, presenting: flow.pending) { request in
                Button("Start in New Tab") {
                    Task { await flow.start(request, inNewTab: true, onStarted: onStarted) }
                }
                Button("Cancel", role: .cancel) { flow.pending = nil }
            }
            .alert("Couldn't Start Agent", isPresented: .init(
                get: { flow.error != nil }, set: { if !$0 { flow.error = nil } }
            )) { Button("OK", role: .cancel) { flow.error = nil } } message: {
                Text(flow.error ?? "")
            }
    }
}
