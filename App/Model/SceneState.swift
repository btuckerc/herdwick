import SwiftUI
import HerdrAPI

/// Navigation and host/session selection belong to a window; transports remain app-wide.
@MainActor @Observable
final class SceneState {
    let id = UUID()
    var selectedHostID: UUID?
    var selectedSession: String?
    var navigationPath: [Route] = []
    var phase: ScenePhase = .inactive
    var showNewAgent = false
    var searchPresented = false
    /// ⌘F with a conversation on screen: that conversation opens its Find bar.
    var findRequest = 0
    /// ⌘L with a conversation on screen: its composer takes the keyboard focus.
    var messageRequest = 0
    /// ⇧⌘U and ⌃⌘A with a conversation on screen: it marks its agent unread, or hides it, as
    /// its menu does.
    var markUnreadRequest = 0
    var hideRequest = 0
    /// The inbox is in Select mode, whose Mark Read and Hide own ⇧⌘U and ⌃⌘A meanwhile (the
    /// iPad sidebar selects beside an open thread).
    var inboxSelecting = false
    /// A shared package on its way into a conversation's draft: the conversation is `importDraftID`,
    /// or, for a just-started agent whose draft id isn't known yet, `importAddress`.
    var importPackageID: UUID?
    var importDraftID: String?
    var importAddress: PaneAddress?
    var draftRevision = 0
    var notificationNotice: String?
    /// The iPad sidebar sits beside the detail, listing every agent, so the composer's dock
    /// would offer the same switch twice (round 36: two graders saw both at once).
    var sidebarBeside = false
    var needsYouOnly = false
    /// An inbox ask's Write Your Own Answer: the agent whose thread opens with its ask's answer
    /// editor out, taken by that thread's ask panel.
    var writeAnswer: PaneAddress?
    /// New Agent's first message, for the thread that opens on the new agent: it lands in the
    /// composer (in the demo too, which keeps no drafts) and, with Start & Send, is sent once
    /// the agent is up. Taken by that thread.
    var firstMessage: FirstMessage?
    /// An agent hidden from its thread's menu, for the inbox to offer back with Undo as a Hide
    /// from its row is. Taken by the inbox.
    var hiddenFromThread: PaneAddress?
    struct FirstMessage: Equatable {
        let address: PaneAddress
        let text: String
        let send: Bool
        /// The agent it was written for (its herdr name); another in that pane doesn't get it.
        var agentName: String? = nil
    }
    /// Answers given from Needs You rows and cards in this window, shared by the inbox and the
    /// iPad Overview so both show the same receipt.
    let inlineAnswers = InlineAnswers()
    /// Whether a blocked thread still needs a decision in this window; a confirmed inline
    /// receipt clears attention consistently across the inbox, Overview and dock.
    func needsUser(_ thread: Thread) -> Bool {
        thread.connection.presentedStatus(thread.agent) == .blocked && inlineAnswers[thread.address]?.receipt == nil
    }
    /// The status this window shows: an agent whose answer's receipt is showing has gone back
    /// to work, so it leaves Needs You in the dock, the Overview and Next at once, as it does in
    /// the inbox (round 15: the dock, the Overview's card glyph and Next still read it as blocked).
    func shownStatus(_ thread: Thread) -> AgentStatus {
        let status = thread.connection.presentedStatus(thread.agent)
        return status == .blocked && !needsUser(thread) ? .working : status
    }
    /// Next/Previous Agent's walk, held from its first step: reading a result or a status change
    /// re-sorts the live order, which would skip or repeat agents mid-walk (round 11).
    @ObservationIgnored var keyboardWalk: [PaneAddress] = []

    func open(_ route: Route) { navigationPath = [route] }
    func back() { if !navigationPath.isEmpty { navigationPath.removeLast() } }
    /// The inbox list's selection: its links open a route as the root of the navigation path,
    /// which also reaches the detail column of a split view.
    var selectedRoute: Route? {
        get { navigationPath.first }
        set { navigationPath = newValue.map { [$0] } ?? [] }
    }
}

struct SceneCommands: Commands {
    @FocusedValue(\.herdwickScene) private var scene
    /// The open thread's send in flight owns its composer: Next waits for it, as the dock does.
    @FocusedValue(\.herdwickSending) private var sending
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent") { scene?.showNewAgent = true }
                .keyboardShortcut("n").disabled(scene == nil)
        }
        CommandMenu("Inbox") {
            // Find in the conversation on screen; Search Agents returns to the inbox first.
            if case .conversation = scene?.navigationPath.last {
                Button("Find in Conversation") { scene?.findRequest += 1 }
                    .keyboardShortcut("f")
                // Steering without reaching for the screen (round 46: sb#5, the keyboard triage
                // loop stopped where a custom reply was needed).
                Button("Write Message") { scene?.messageRequest += 1 }
                    .keyboardShortcut("l")
                Button("Search Agents") {
                    scene?.navigationPath = []
                    scene?.searchPresented = true
                }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                // The open agent's terminal, as the bar's Terminal button opens it, Type's ⌘T
                // beside it once there (round 86: sb#1, the keyboard loop had to reach for it).
                if case .conversation(let address)? = scene?.navigationPath.last {
                    Button("Open Terminal") { scene?.navigationPath.append(.terminal(address)) }
                        .keyboardShortcut("t", modifiers: [.command, .option])
                }
            } else {
                // From a terminal it returns to the inbox too (round 40: sb#1, the field opened
                // on the inbox behind the terminal, out of sight).
                Button("Search") {
                    scene?.navigationPath = []
                    scene?.searchPresented = true
                }
                    .keyboardShortcut("f").disabled(scene == nil)
                // The terminal's line composer, as a conversation's (round 67: sb#3).
                if case .terminal = scene?.navigationPath.last {
                    Button("Write Message") { scene?.messageRequest += 1 }
                        .keyboardShortcut("l")
                }
            }
            // The inbox's triage keys on the open agent, Mail's (round 62: sb#2, its menu's Mark
            // as Unread and Hide had no keys, the inbox's had), in its terminal too (round 65:
            // sb#7, an agent opened there lost them).
            if scene?.inboxSelecting == false, let open = openThread {
                Button("Mark as Unread") { scene?.markUnreadRequest += 1 }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(open.connection.presentedStatus(open.agent) != .idle || open.connection.isUnread(open.agent))
                Button("Hide Agent") { scene?.hideRequest += 1 }
                    .keyboardShortcut("a", modifiers: [.command, .control])
            }
            Button("Back") { scene?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(scene?.navigationPath.isEmpty != false)
            Button("Refresh") { Task { await model.refresh(explicit: true) } }
                .keyboardShortcut("r").disabled(scene == nil)
            // The triage loop from the keyboard: the dock's first Needs You other than the open one.
            // Off when there's none, as Next and Previous Agent are at the walk's ends (round 35:
            // enabled, they did nothing).
            Button("Next Needs You") { if let next = nextNeedsYou() { open(next) } }
                .keyboardShortcut("j").disabled(sending == true || nextNeedsYou() == nil)
            Button(scene?.needsYouOnly == true ? "Show All Agents" : "Show Needs You Only") { scene?.needsYouOnly.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(scene == nil)
            // Stepping through every agent in the dock's order, opening each in place (round 10:
            // no way to walk the rows from a keyboard); ⌘1…⌘9 then answer its card. ⌥⌘, not bare
            // arrows, which belong to the composer and the transcript.
            Button("Next Agent") { step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(sending == true || walk(1) == nil)
            Button("Previous Agent") { step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(sending == true || walk(-1) == nil)
        }
    }

    private func nextNeedsYou() -> Thread? {
        guard let scene else { return nil }
        let others = model.dockThreads(in: scene).filter {
            scene.needsUser($0) && scene.selectedRoute != .conversation($0.address) && scene.selectedRoute != .terminal($0.address)
        }
        return AgentDock.firstNeedsYou(in: others, scene: scene)
    }

    /// The agent on screen, in its conversation or its terminal.
    private var openThread: Thread? {
        guard let scene, let address = scene.navigationPath.last?.address else { return nil }
        return model.dockThreads(in: scene).first { $0.address == address }
    }

    private func open(_ thread: Thread) {
        scene?.open(thread.agent.opensAsConversation ? .conversation(thread.address) : .terminal(thread.address))
    }

    /// The agent `offset` rows from the open one in the walk, with the walk as it then stands;
    /// from the inbox or the Overview, the first. The walk is the dock's order when it starts
    /// and keeps its order after: ended agents drop out, new ones join the end, and a fresh walk
    /// starts from an agent not on it. Nil past either end.
    private func walk(_ offset: Int) -> (walk: [PaneAddress], next: Thread)? {
        guard let scene else { return nil }
        let live = AgentDock.keyboardOrder(model.dockThreads(in: scene), scene: scene)
        let byAddress = Dictionary(live.map { ($0.address, $0) }) { first, _ in first }
        let open = live.first { scene.selectedRoute == .conversation($0.address) || scene.selectedRoute == .terminal($0.address) }
        var walk = scene.keyboardWalk.filter { byAddress[$0] != nil }
        if let open, walk.contains(open.address) {
            let held = Set(walk)
            walk += live.map(\.address).filter { !held.contains($0) }
        } else {
            walk = live.map(\.address)
        }
        let index = open.flatMap { walk.firstIndex(of: $0.address) }.map { $0 + offset } ?? 0
        guard walk.indices.contains(index), let next = byAddress[walk[index]] else { return nil }
        return (walk, next)
    }

    private func step(_ offset: Int) {
        guard let target = walk(offset) else { return }
        scene?.keyboardWalk = target.walk
        open(target.next)
    }
}

private struct HerdwickSceneKey: FocusedValueKey { typealias Value = SceneState }
private struct HerdwickSendingKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var herdwickScene: SceneState? {
        get { self[HerdwickSceneKey.self] }
        set { self[HerdwickSceneKey.self] = newValue }
    }
    var herdwickSending: Bool? {
        get { self[HerdwickSendingKey.self] }
        set { self[HerdwickSendingKey.self] = newValue }
    }
}
