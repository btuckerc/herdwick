import HerdrAPI
import UIKit
import Observation
import CryptoKit

/// Push alerts while the app is away, opt-in. Leaving the foreground, the app starts a watcher on
/// each live host over the SSH link it already has (`PushWatch`); coming back, it stops them.
/// A watcher posts opaque ids to the relay, which forwards them through APNs; the
/// notification service fills in names from what the phone already knows.
@MainActor @Observable
final class Push {
    var watchedRun: (address: PaneAddress, activityToken: String)?
    /// The relay's base URL, from the `HerdwickPushRelay` Info.plist key; none hides the option.
    /// A build signed by another team points it at a relay holding that team's APNs key.
    static let relay: URL? = (Bundle.main.object(forInfoDictionaryKey: "HerdwickPushRelay") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    struct Coverage: Identifiable {
        let hostID: UUID
        let session: String
        let message: String
        let lastArmed: Date?
        var id: String { "\(hostID.uuidString)/\(session)" }
    }
    private(set) var coverage: [String: Coverage] = [:]

    static var installationID: UUID {
        let defaults = AttentionSnapshot.shared!
        if let value = defaults.string(forKey: AttentionSnapshot.installationKey).flatMap(UUID.init(uuidString:)) { return value }
        let value = UUID()
        defaults.set(value.uuidString, forKey: AttentionSnapshot.installationKey)
        return value
    }

    private static var secret: String {
        let defaults = AttentionSnapshot.shared!
        if let value = defaults.string(forKey: AttentionSnapshot.secretKey) { return value }
        let value = SymmetricKey(size: .bits256).withUnsafeBytes {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        defaults.set(value, forKey: AttentionSnapshot.secretKey)
        return value
    }
    private let settings: Settings
    /// `host/session` of every watcher started and not yet stopped, across launches: one left
    /// running by an app that was then closed is stopped when its link next comes up.
    private var armed: Set<String> {
        didSet { UserDefaults.standard.set(Array(armed), forKey: "push.armed") }
    }
    /// Activity-only watchers must not take ordinary alerts away from background refresh.
    private var alertArmed: Set<String> {
        didSet { UserDefaults.standard.set(Array(alertArmed), forKey: "push.alertArmed") }
    }
    /// Reservations cover SSH requests too, before a watcher is confirmed or stopped.
    private var pending: [String: (generation: Int, task: Task<Void, Never>, alerts: Bool)] = [:]
    private var generation = 0

    init(settings: Settings) {
        self.settings = settings
        armed = Set(UserDefaults.standard.stringArray(forKey: "push.armed") ?? [])
        alertArmed = Set(UserDefaults.standard.stringArray(forKey: "push.alertArmed")
                         ?? UserDefaults.standard.stringArray(forKey: "push.armed") ?? [])
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
        return alertArmed.contains(key) || pending[key]?.alerts == true
    }

    /// Starts a watcher on every live link, within the few seconds iOS grants after backgrounding.
    func arm(_ links: [HostConnection], profiles: [HostProfile], selectedHostIDs: Set<UUID>) async {
        let states = (settings.notifyNeedsYou ? ["blocked"] : []) + (settings.notifyFinished ? ["done"] : [])
        let watched = watchedRun
        let token = UserDefaults.standard.string(forKey: "push.token")
        for profile in profiles {
            let known = links.filter { $0.profile.id == profile.id }
            let sessions = Set(known.flatMap { $0.sessions.filter(\.running).map(\.name) }
                + known.map { $0.identity.session } + [profile.session].compactMap { $0 })
            for session in sessions.isEmpty ? Set(["—"]) : sessions {
                let address = SessionAddress(hostID: profile.id, session: session)
                let key = Self.key(address)
                let reason: String
                let watchesSession = watched?.address.hostID == profile.id && watched?.address.session == session
                if !settings.pushWhileAway || (states.isEmpty && !watchesSession) { reason = "Skipped: alerts off" }
                else if !selectedHostIDs.contains(profile.id) && !watchesSession { reason = "Skipped: not selected" }
                else if !known.contains(where: { $0.identity.session == session && $0.isLive }) { reason = "Skipped: not connected" }
                else { reason = "Arming…" }
                coverage[key] = Coverage(hostID: profile.id, session: session, message: reason,
                                         lastArmed: coverage[key]?.lastArmed)
            }
        }
        guard settings.pushWhileAway, !states.isEmpty || watched != nil else { return }
        guard let relay = Self.relay else {
            for (key, value) in coverage where value.message == "Arming…" {
                coverage[key] = Coverage(hostID: value.hostID, session: value.session,
                                         message: "Error: push registration unavailable", lastArmed: value.lastArmed)
            }
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for link in links where link.isLive {
                let activity: PushWatch.Config.Activity? = watched.flatMap {
                    $0.address.hostID == link.profile.id && $0.address.session == link.identity.session
                        ? .init(pane: $0.address.paneID, token: $0.activityToken) : nil
                }
                guard selectedHostIDs.contains(link.profile.id) || activity != nil else { continue }
                guard (!states.isEmpty && token != nil) || activity != nil else {
                    if !states.isEmpty {
                        let key = Self.key(link.identity)
                        coverage[key] = Coverage(hostID: link.profile.id, session: link.identity.session,
                                                 message: "Error: push registration unavailable",
                                                 lastArmed: coverage[key]?.lastArmed)
                    }
                    continue
                }
                let config = PushWatch.Config(relay: relay, deviceToken: token ?? "", environment: Self.environment,
                                              hostID: link.profile.id, states: token == nil ? [] : states,
                                              installationID: Self.installationID, secret: Self.secret,
                                              mutes: Mutes.shared.watcherMutes(link), activity: activity)
                // Reserve before dispatch: mirror events can arrive during the SSH request.
                let task = watch(config, on: link)
                group.addTask { await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() } }
            }
        }
    }

    /// A link came up in the foreground: its host no longer needs to watch.
    func disarm(_ link: HostConnection) async {
        let key = Self.key(link.identity)
        guard armed.contains(key) || pending[key] != nil else { return }
        await watch(nil, on: link).value
    }

    /// Serialize each session's handoffs, including a foreground return that overtakes arming.
    private func watch(_ config: PushWatch.Config?, on link: HostConnection) -> Task<Void, Never> {
        let key = Self.key(link.identity)
        let previous = pending[key]?.task
        generation += 1
        let generation = generation
        let alerts = config.map { !$0.states.isEmpty } ?? false
        let task = Task { @MainActor in
            await previous?.value
            do {
                try await link.watch(config)
                if config != nil { armed.insert(key) } else { armed.remove(key) }
                if alerts { alertArmed.insert(key) } else { alertArmed.remove(key) }
                coverage[key] = Coverage(hostID: link.profile.id, session: link.identity.session,
                                         message: config.map { $0.deviceToken.isEmpty ? "Last armed · Live Activity only; alert token unavailable" : "Last armed" } ?? "Stopped",
                                         lastArmed: config != nil ? .now : coverage[key]?.lastArmed)
            } catch {
                // A start that failed or was cut short may still have left a watcher running:
                // count it as armed, so the next foreground link stops it. A failed stop
                // leaves the watcher owned.
                if config != nil { armed.insert(key) }
                if alerts { alertArmed.insert(key) }
                coverage[key] = Coverage(hostID: link.profile.id, session: link.identity.session,
                                         message: "Error: \(error.localizedDescription)",
                                         lastArmed: coverage[key]?.lastArmed)
            }
            if pending[key]?.generation == generation {
                pending.removeValue(forKey: key)
            }
        }
        pending[key] = (generation, task, alerts || alertArmed.contains(key) || pending[key]?.alerts == true)
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
