import HerdrAPI
import UIKit

/// Push alerts while the app is away, opt-in. Leaving the foreground, the app starts a watcher on
/// each live host over the SSH link it already has (`PushWatch`); coming back, it stops them.
/// A watcher posts opaque ids to the relay, which forwards them through APNs; the
/// notification service fills in names from what the phone already knows.
@MainActor
final class Push {
    /// The relay's base URL, from the `HerdwickPushRelay` Info.plist key; none hides the option.
    /// A build signed by another team points it at a relay holding that team's APNs key.
    static let relay: URL? = (Bundle.main.object(forInfoDictionaryKey: "HerdwickPushRelay") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    private let settings: Settings
    /// `host/session` of every watcher started and not yet stopped, across launches: one left
    /// running by an app that was then closed is stopped when its link next comes up.
    private var armed: Set<String> {
        didSet { UserDefaults.standard.set(Array(armed), forKey: "push.armed") }
    }

    init(settings: Settings) {
        self.settings = settings
        armed = Set(UserDefaults.standard.stringArray(forKey: "push.armed") ?? [])
        register()
    }

    /// Asks APNs for this device's token, once opted in; iOS asks nothing of the user here.
    func register() {
        if Self.relay != nil, settings.pushWhileAway { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// From the app delegate; APNs may change the token at any launch.
    static func received(token: Data) {
        UserDefaults.standard.set(token.map { String(format: "%02x", $0) }.joined(), forKey: "push.token")
    }

    /// Starts a watcher on every live link, within the few seconds iOS grants after backgrounding.
    func arm(_ links: [HostConnection]) async {
        let states = (settings.notifyNeedsYou ? ["blocked"] : []) + (settings.notifyFinished ? ["done"] : [])
        guard let relay = Self.relay, settings.pushWhileAway, !states.isEmpty,
              let token = UserDefaults.standard.string(forKey: "push.token") else { return }
        await withTaskGroup(of: String?.self) { group in
            for link in links where link.isLive {
                let config = PushWatch.Config(relay: relay, deviceToken: token, environment: Self.environment,
                                              hostID: link.profile.id, states: states)
                let key = Self.key(link.identity)
                group.addTask { (try? await link.watch(config)) != nil ? key : nil }
            }
            for await key in group {
                if let key { armed.insert(key) }
            }
        }
    }

    /// A link came up in the foreground: its host no longer needs to watch.
    func disarm(_ link: HostConnection) async {
        let key = Self.key(link.identity)
        guard armed.contains(key), (try? await link.watch(nil)) != nil else { return }
        armed.remove(key)
    }

    private nonisolated static func key(_ address: SessionAddress) -> String {
        "\(address.hostID.uuidString)/\(address.session)"
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.received(token: deviceToken)
    }
}
