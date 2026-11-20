import HerdrAPI
import SwiftUI

/// Harnesses Herdwick can start in a pane. `agy` is Google's Antigravity CLI (Gemini 4 Neon):
/// Herdwick only ever sends what the user typed or tapped to it, never prompts of its own,
/// because Google's terms allow agy in a multiplexer only while the person drives it.
let startableAgentKinds = ["omp", "claude", "codex", "agy"]

func agentKindLabel(_ kind: String) -> String {
    switch kind {
    case "omp": "OMP"
    case "claude": "Claude"
    case "codex": "Codex"
    case "agy": "Neon"
    default: kind
    }
}

@MainActor @Observable
final class AgentStartFlow {
    struct Request {
        let connection: HostConnection
        let address: PaneAddress
        let kind: String
        /// Literal argv after the agent's command, from a launch preset or a resume.
        var arguments: [String] = []
        /// The pane was just created for this agent: no busy check, startup files waited out.
        var freshPane = false
    }

    var running = false
    var pending: Request?
    var errorTitle = "Couldn't Start Agent"
    /// Claude's folder check, waiting on the person: what it asks, where, and the start it holds.
    var trust: Trust?
    struct Trust { let prompt: ScreenPrompt; let address: PaneAddress; let name: String; let request: Request }
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
            switch try await request.connection.startAgent(kind: request.kind, arguments: request.arguments, paneID: request.address.paneID,
                                                           inNewTab: inNewTab, freshPane: request.freshPane) {
            case .busy(let command):
                pending = request
                busyCommand = command
            case .started(let agent, let address):
                await onStarted(agent, address)
            case .needsTrust(let prompt, let address, let name):
                trust = Trust(prompt: prompt, address: address, name: name, request: request)
            }
        } catch let unverified as HostConnection.TrustUnverified {
            self.error = unverified.localizedDescription
        } catch {
            self.error = "\(request.kind) didn't start on \(request.connection.profile.name). Is it installed? \(error.localizedDescription)"
        }
    }

    /// The person's answer to Claude's folder check: trusting it lets the start finish (and the
    /// first message go); not trusting it ends that Claude, leaving the shell.
    func answerTrust(_ trusted: Bool, _ held: Trust, onStarted: @MainActor (Agent, PaneAddress) async -> Void) async {
        guard !running else { return }
        if trust?.address == held.address { trust = nil }
        running = true
        defer { running = false }
        let label = trusted ? held.prompt.options.first { $0.label.hasPrefix("Yes, I trust") }?.label ?? "" : "No, exit"
        do {
            if let agent = try await held.request.connection.answerTrust(label, on: held.prompt, at: held.address, name: held.name, kind: held.request.kind) {
                await onStarted(agent, held.address)
            }
        } catch let pending as HostConnection.TrustPending {
            errorTitle = "Claude Is Still Starting"
            self.error = pending.localizedDescription
        } catch {
            self.error = "Couldn't answer Claude's folder check. Answer it from Needs You or the terminal. \(error.localizedDescription)"
        }
    }
}

struct AgentStartFeedback: ViewModifier {
    @Bindable var flow: AgentStartFlow
    let onStarted: @MainActor (Agent, PaneAddress) async -> Void

    private var trustTitle: String {
        let folder = (flow.trust?.prompt.folder ?? flow.trust?.prompt.subject).map { ($0 as NSString).lastPathComponent } ?? "this folder"
        return "Trust “\(folder)”?"
    }

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
            // Claude's own question, asked here so the start needn't go through the terminal.
            // Dismissed without a choice, Claude keeps asking: its Needs You card answers it later.
            .confirmationDialog(trustTitle, isPresented: .init(
                get: { flow.trust != nil }, set: { if !$0 { flow.trust = nil } }
            ), titleVisibility: .visible, presenting: flow.trust) { held in
                Button("Trust Folder") { Task { await flow.answerTrust(true, held, onStarted: onStarted) } }
                // Ends that Claude; Cancel leaves its question for Needs You.
                Button("Don't Trust", role: .destructive) { Task { await flow.answerTrust(false, held, onStarted: onStarted) } }
                Button("Cancel", role: .cancel) {}
            } message: { held in
                // The whole path and the computer: the grant lasts for exactly this folder.
                Text("\(held.prompt.folder ?? held.prompt.subject ?? "") on \(held.request.connection.profile.name)\n\nClaude asks before working in a folder it hasn't opened. Trust it only if it's your own code or from a source you trust: Claude will be able to read, edit and run files there.")
            }
            .alert(flow.errorTitle, isPresented: .init(
                get: { flow.error != nil }, set: { if !$0 { flow.error = nil; flow.errorTitle = "Couldn't Start Agent" } }
            )) { Button("OK", role: .cancel) { flow.error = nil } } message: {
                Text(flow.error ?? "")
            }
    }
}
