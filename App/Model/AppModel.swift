import Foundation
import Network
import SwiftUI

/// App-wide state. Primary links discover sessions; additional links mirror the rest.
@MainActor @Observable
final class AppModel {
    private(set) var profiles: [HostProfile]
    private var primary: [HostProfile.ID: HostConnection] = [:]
    private var additional: [SessionAddress: HostConnection] = [:]
    private var demoConnection: HostConnection?
    private(set) var selectedHostID: HostProfile.ID?
    var navigationPath: [Route] = []

    var connection: HostConnection? {
        demo != nil ? demoConnection : selectedHostID.flatMap { primary[$0] }
    }

    /// Profile order, then session name. Failed hosts remain present for inline recovery.
    var connections: [HostConnection] {
        if demo != nil { return demoConnection.map { [$0] } ?? [] }
        return profiles.flatMap { profile in
            let links = (primary[profile.id].map { [$0] } ?? [])
                + additional.filter { $0.key.hostID == profile.id }.map(\.value)
            return links.sorted { ($0.activeSession ?? $0.profile.session ?? "") < ($1.activeSession ?? $1.profile.session ?? "") }
        }
    }

    func connection(for address: SessionAddress) -> HostConnection? {
        connections.first { $0.profile.id == address.hostID && $0.activeSession == address.session }
    }

    func connection(for address: PaneAddress) -> HostConnection? {
        connection(for: SessionAddress(hostID: address.hostID, session: address.session))
    }
    /// Set while the demo host is showing (onboarding's "Explore a Demo", or a marketing capture).
    private(set) var demo: DemoDirector?
    let settings = Settings()
    let tailnet = Tailnet()

    private let pathMonitor = NWPathMonitor()
    private var pathSignature: String?
    private var isForeground = true

    init() {
        if let launch = DemoLaunch.current {
            profiles = []
            startDemo(launch)
            return
        }
        profiles = ProfileStorage.load()
        if profiles.contains(where: \.isTailnet) || tailnet.isConfigured {
            tailnet.start()
        }
        let lastID = UserDefaults.standard.string(forKey: "selected-host").flatMap(UUID.init(uuidString:))
        if let profile = profiles.first(where: { $0.id == lastID }) ?? profiles.first {
            select(profile.id)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in self?.pathChanged(satisfied: satisfied, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "herdwick.path"))
        observeScope()
    }

    // MARK: Hosts

    func select(_ id: HostProfile.ID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if demo == nil, selectedHostID == id { reconcile(); return }
        endDemoHost()
        selectedHostID = id
        if !settings.allHosts { navigationPath = [] }
        UserDefaults.standard.set(id.uuidString, forKey: "selected-host")
        reconcile()
    }

    func selectSession(_ name: String) {
        guard var profile = profiles.first(where: { $0.id == selectedHostID }) else { return }
        profile.session = name
        navigationPath = []
        update(profile)
    }

    private func observeScope() {
        withObservationTracking {
            _ = settings.allHosts
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.observeScope()
            }
        }
    }

    private func reconcile() {
        guard demo == nil else { return }
        let desired = Set(profiles.filter { settings.allHosts || $0.id == selectedHostID }.map(\.id))
        for id in Array(primary.keys) where !desired.contains(id) {
            primary.removeValue(forKey: id)?.stop()
        }
        for key in Array(additional.keys) where !settings.allHosts || !desired.contains(key.hostID) {
            additional.removeValue(forKey: key)?.stop()
        }
        for profile in profiles where desired.contains(profile.id) {
            if let link = primary[profile.id] {
                let changed = link.includesAllSessions != settings.allHosts
                link.includesAllSessions = settings.allHosts
                if changed {
                    if isForeground { link.handle(.userRetry) }
                }
            } else {
                let link = HostConnection(profile: profile, tailnet: tailnet, onSessions: { [weak self] link in
                    self?.reconcileSessions(link)
                }) { [weak self] updated in self?.store(updated) }
                link.includesAllSessions = settings.allHosts
                primary[profile.id] = link
                if isForeground { link.handle(.start) }
            }
        }
    }

    private func reconcileSessions(_ primaryLink: HostConnection) {
        guard demo == nil, settings.allHosts, primary[primaryLink.profile.id] === primaryLink else { return }
        let names = Set(primaryLink.sessions.filter(\.running).map(\.name))
        let desired = names.subtracting(primaryLink.activeSession.map { [$0] } ?? [])
        for key in Array(additional.keys) where key.hostID == primaryLink.profile.id && !desired.contains(key.session) {
            additional.removeValue(forKey: key)?.stop()
        }
        for name in desired.sorted() {
            let key = SessionAddress(hostID: primaryLink.profile.id, session: name)
            guard additional[key] == nil else { continue }
            var profile = primaryLink.profile
            profile.session = name
            // One transport per running session deliberately keeps supervisor, retry,
            // host-key failure and detail-stream lifetimes independent. Sharing SSH
            // would require a new host-level supervisor and cross-session cancellation
            // ownership. Cost: one SSH keepalive per session, all closed in background.
            let link = HostConnection(profile: profile, tailnet: tailnet) { _ in }
            additional[key] = link
            if isForeground { link.handle(.start) }
        }
    }

    func refresh() async {
        guard isForeground else { return }
        if let demoConnection, demo != nil {
            await demoConnection.refreshSessions()
            return
        }
        // Discover once per host, not once per mirrored session.
        let links = profiles.compactMap { primary[$0.id] }
        await withTaskGroup(of: Void.self) { group in
            for link in links { group.addTask { await link.refreshSessions() } }
        }
    }

    private func stopAll() {
        for link in connections { link.stop() }
        primary = [:]
        additional = [:]
        demoConnection = nil
    }

    func add(_ profile: HostProfile) {
        // Upsert: a sheet that finishes twice must not leave two hosts with one ID.
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        ProfileStorage.save(profiles)
        select(profile.id)
    }

    /// Saves edits; a changed route, user or auth reconnects with the new settings.
    func update(_ profile: HostProfile) {
        store(profile)
        primary.removeValue(forKey: profile.id)?.stop()
        for key in Array(additional.keys) where key.hostID == profile.id {
            additional.removeValue(forKey: key)?.stop()
        }
        reconcile()
    }

    func delete(_ id: HostProfile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        Keychain.delete(profile.passwordAccount)
        Keychain.delete(profile.hostKeyAccount)
        profiles.removeAll { $0.id == id }
        ProfileStorage.save(profiles)
        if selectedHostID == id {
            selectedHostID = profiles.first?.id
            navigationPath = []
        }
        reconcile()
    }

    private func store(_ profile: HostProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        ProfileStorage.save(profiles)
    }

    // MARK: Demo

    /// Connects to the bundled demo host. The host is never saved; adding a real host ends it.
    func startDemo(_ launch: DemoLaunch? = nil) {
        guard let director = try? DemoDirector(launch: launch) else { return }
        stopAll()
        navigationPath = []
        demo = director
        if launch?.scene == .tailscale, let tailnet = director.scenario.tailnet {
            self.tailnet.showDemo(name: tailnet.name, peers: director.tailnetPeers)
        }
        if launch?.scene.isOnboarding == true {
            director.run(connection: nil)
            return
        }
        let connection = HostConnection(profile: director.profile, tailnet: tailnet, demo: director.host) { _ in }
        self.demoConnection = connection
        connection.handle(.start)
        director.run(connection: connection)
    }

    /// Leaves the demo for the saved hosts, or onboarding when there are none.
    func endDemo() {
        stopAll()
        navigationPath = []
        endDemoHost()
        if let first = profiles.first { select(first.id) }
    }

    private func endDemoHost() {
        demoConnection?.stop()
        demoConnection = nil
        demo?.stop()
        demo = nil
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            reconcile()
            for link in connections { link.handle(.foregrounded) }
            Task { await refresh() }
        case .background:
            isForeground = false
            for link in connections { link.handle(.backgrounded) }
        default:
            break
        }
    }

    /// Only real route changes count (Wi-Fi ↔ cellular, a VPN coming up or down);
    /// NWPathMonitor also reports cosmetic updates that must not drop a live link.
    private func pathChanged(satisfied: Bool, signature: String) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature else { return }
        for link in connections { link.handle(.pathChanged(satisfied: satisfied)) }
    }
}
