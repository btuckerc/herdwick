import HerdrAPI
import SwiftUI

@main
struct HerdwickApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var dictation = DictationController()
    @State private var model = AppModel()

    init() {
        AgentsTip.configure(demo: UserDefaults.standard.string(forKey: "HerdwickDemo")?.isEmpty == false)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.tailnet)
                .environment(model.demo)
                .environment(dictation)
                .environment(model.decisionLog)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .commands { SceneCommands(model: model) }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) { await model.backgroundRefresh() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(DictationController.self) private var dictation
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var width
    @State private var scene = SceneState()
    /// The split view's width, for its sidebar's share.
    @State private var windowWidth: CGFloat = 1_024

    var body: some View {
        @Bindable var scene = scene
        Group {
            if let connection = model.connection(in: scene) {
                if width == .regular {
                    NavigationSplitView {
                        // As wide as a phone, whose rows these are: at the default 320 pt a title
                        // wrapped and the last report and caution cut while the detail had room
                        // (round 52: opus#11, sa#10, sb#4); in portrait no more than two-fifths of
                        // the window, as Mail's and Notes' columns (round 70: opus#3, sa#3, at
                        // 402 pt it took nearly half and pinched the thread).
                        SessionView(connection: connection, sidebar: true)
                            .navigationSplitViewColumnWidth(min: 320, ideal: min(402, max(320, (windowWidth * 0.4).rounded())), max: 440)
                    } detail: {
                        NavigationStack(path: detailPath) {
                            detailRoot
                                .navigationDestination(for: Route.self) { destination($0) }
                        }
                        // Beside, not over: an overlaid sidebar leaves the detail at the edge.
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minX > 1 } action: { scene.sidebarBeside = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
                } else {
                    // A plain push, not a zoom out of the row (round 42: sa#4, sb#8, opus#4: the
                    // 550 ms zoom, rows and transcript scaling, was conspicuous on the most
                    // repeated move; a push settles in about 380). The row it came from shows as
                    // selected on the way back, then fades, as UIKit lists deselect.
                    NavigationStack(path: $scene.navigationPath) {
                        SessionView(connection: connection)
                            .navigationDestination(for: Route.self) { destination($0) }
                    }
                }
            } else { OnboardingView() }
        }
        .environment(scene)
        .focusedSceneValue(\.herdwickScene, scene)
        .onAppear { model.register(scene); model.scenePhaseChanged(phase, in: scene); SharedInbox.shared.refresh() }
        .onChange(of: width) { _, width in if width != .regular { scene.sidebarBeside = false } }
        .onDisappear { model.unregister(scene) }
        .onChange(of: phase) { _, phase in
            model.scenePhaseChanged(phase, in: scene)
            if phase == .background { dictation.backgrounded() }
            if phase == .active { SharedInbox.shared.refresh() }
        }
        .onOpenURL { model.open($0, in: scene) }
        .alert("Reply saved", isPresented: Binding(get: { scene.notificationNotice != nil }, set: { if !$0 { scene.notificationNotice = nil } })) {
            Button("OK") { scene.notificationNotice = nil }
        } message: { Text(scene.notificationNotice ?? "") }
        .modifier(AppPrivacyModifier())
    }

    /// The split view's detail column shows the selected thread as its root, swapped in place;
    /// only what that thread opens (its terminal, a subagent) is pushed. Pushing the selection
    /// itself left the column blank whenever the selection changed (iOS 26 and 27).
    private var detailPath: Binding<[Route]> {
        Binding(get: { Array(scene.navigationPath.dropFirst()) },
                set: { scene.navigationPath = Array(scene.navigationPath.prefix(1)) + $0 })
    }

    @ViewBuilder private var detailRoot: some View {
        if let route = scene.navigationPath.first {
            destination(route)
        } else {
            OverviewView()
        }
    }

    /// One view per route: the agent dock replaces the root in place, and a reused view
    /// would carry the last thread's composer, scroll and read state across.
    private func destination(_ route: Route) -> some View {
        destinationContent(route).id(route)
    }

    @ViewBuilder private func destinationContent(_ route: Route) -> some View {
        let address = route.address
        if let target = model.connection(for: address) {
            switch route {
            case .conversation:
                ConversationView(connection: target, paneID: address.paneID) {
                    scene.navigationPath.append(.terminal(address))
                }
            case .subagent(_, let path, let rawFormat, let title):
                if let format = TranscriptFormat(rawValue: rawFormat) {
                    SubagentConversationView(connection: target, path: path, format: format, title: title)
                } else { ContentUnavailableView("Transcript unavailable", systemImage: "text.document") }
            case .terminal: PaneView(connection: target, paneID: address.paneID)
            }
        } else if model.connections.contains(where: { $0.profile.id == address.hostID && !$0.isLive }) {
            ProgressView()
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "network.slash",
                                   description: Text("This host or session is no longer in the inbox."))
        }
    }
}
