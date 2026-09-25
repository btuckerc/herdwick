import HerdrAPI
import SwiftUI

@main
struct HerdwickApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.tailnet)
                .environment(model.demo)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) {
            await model.backgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let connection = model.connection {
            NavigationStack(path: $model.navigationPath) {
                SessionView(connection: connection)
                    .navigationDestination(for: Route.self) { route in
                        let address = route.address
                        if let target = model.connection(for: address) {
                            switch route {
                            case .conversation:
                                ConversationView(connection: target, paneID: address.paneID) {
                                    model.navigationPath.append(.terminal(address))
                                }
                            case .subagent(_, let path, let rawFormat, let title):
                                if let format = TranscriptFormat(rawValue: rawFormat) {
                                    SubagentConversationView(connection: target, path: path, format: format, title: title)
                                } else {
                                    ContentUnavailableView("Transcript unavailable", systemImage: "text.document")
                                }
                            case .terminal:
                                PaneView(connection: target, paneID: address.paneID)
                            }
                        } else if model.connections.contains(where: { $0.profile.id == address.hostID && !$0.isLive }) {
                            // Opened from an alert or a widget while the host is still connecting.
                            ProgressView()
                        } else {
                            ContentUnavailableView("Session unavailable", systemImage: "network.slash",
                                                   description: Text("This host or session is no longer in the inbox."))
                        }
                    }
            }
        } else {
            OnboardingView()
        }
    }
}
