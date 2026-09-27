import SwiftUI

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
    /// A shared package on its way into a conversation's draft: the conversation is `importDraftID`,
    /// or, for a just-started agent whose draft id isn't known yet, `importAddress`.
    var importPackageID: UUID?
    var importDraftID: String?
    var importAddress: PaneAddress?
    var draftRevision = 0
    var notificationNotice: String?
    var needsYouOnly = false

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
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent") { scene?.showNewAgent = true }
                .keyboardShortcut("n").disabled(scene == nil)
        }
        CommandMenu("Inbox") {
            Button("Search") { scene?.searchPresented = true }
                .keyboardShortcut("f").disabled(scene == nil)
            Button("Back") { scene?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(scene?.navigationPath.isEmpty != false)
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r").disabled(scene == nil)
        }
    }
}

private struct HerdwickSceneKey: FocusedValueKey { typealias Value = SceneState }
extension FocusedValues {
    var herdwickScene: SceneState? {
        get { self[HerdwickSceneKey.self] }
        set { self[HerdwickSceneKey.self] = newValue }
    }
}
