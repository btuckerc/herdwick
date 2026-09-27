import HerdrAPI
import SwiftUI

@main
struct HerdwickApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.tailnet)
                .environment(model.demo)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .commands { SceneCommands(model: model) }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) { await model.backgroundRefresh() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var width
    @State private var scene = SceneState()

    var body: some View {
        @Bindable var scene = scene
        Group {
            if let connection = model.connection(in: scene) {
                if width == .regular {
                    NavigationSplitView {
                        SessionView(connection: connection)
                    } detail: {
                        NavigationStack(path: $scene.navigationPath) {
                            ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
                                .navigationDestination(for: Route.self) { destination($0) }
                        }
                    }
                } else {
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
        .onDisappear { model.unregister(scene) }
        .onChange(of: phase) { _, phase in
            model.scenePhaseChanged(phase, in: scene)
            if phase == .active { SharedInbox.shared.refresh() }
        }
        .onOpenURL { model.open($0, in: scene) }
        .alert("Reply saved", isPresented: Binding(get: { scene.notificationNotice != nil }, set: { if !$0 { scene.notificationNotice = nil } })) {
            Button("OK") { scene.notificationNotice = nil }
        } message: { Text(scene.notificationNotice ?? "") }
        .modifier(AppPrivacyModifier())
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
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
