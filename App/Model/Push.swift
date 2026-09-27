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
    /// Reservations cover SSH requests too, before a watcher is confirmed or stopped.
    private var pending: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var generation = 0

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

    /// Local alerts yield until the watcher has been confirmed stopped.
    func ownsAlerts(for address: SessionAddress) -> Bool {
        let key = Self.key(address)
        return armed.contains(key) || pending[key] != nil
    }

    /// Starts a watcher on every live link, within the few seconds iOS grants after backgrounding.
    func arm(_ links: [HostConnection]) async {
        let states = (settings.notifyNeedsYou ? ["blocked"] : []) + (settings.notifyFinished ? ["done"] : [])
        guard let relay = Self.relay, settings.pushWhileAway, !states.isEmpty,
              let token = UserDefaults.standard.string(forKey: "push.token") else { return }
        await withTaskGroup(of: Void.self) { group in
            for link in links where link.isLive {
                let config = PushWatch.Config(relay: relay, deviceToken: token, environment: Self.environment,
                                              hostID: link.profile.id, states: states)
                // Reserve before dispatch: mirror events can arrive during the SSH request.
                let task = watch(config, on: link)
                group.addTask { await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() } }
            }
        }
    }

    /// A link came up in the foreground: its host no longer needs to watch.
    func disarm(_ link: HostConnection) async {
        guard ownsAlerts(for: link.identity) else { return }
        await watch(nil, on: link).value
    }

    /// Serialize each session's handoffs, including a foreground return that overtakes arming.
    private func watch(_ config: PushWatch.Config?, on link: HostConnection) -> Task<Void, Never> {
        let key = Self.key(link.identity)
        let previous = pending[key]?.task
        generation += 1
        let generation = generation
        let task = Task { @MainActor in
            await previous?.value
            do {
                try await link.watch(config)
                if config != nil { armed.insert(key) } else { armed.remove(key) }
            } catch {
                // A start that failed or was cut short may still have left a watcher running:
                // count it as armed, so the next foreground link stops it. A failed stop
                // leaves the watcher owned.
                if config != nil { armed.insert(key) }
            }
            if pending[key]?.generation == generation {
                pending.removeValue(forKey: key)
            }
        }
        pending[key] = (generation, task)
        return task
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
