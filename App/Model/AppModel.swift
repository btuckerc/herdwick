import BackgroundTasks
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
    private var initialHostID: HostProfile.ID?
    private var scenes: [UUID: SceneState] = [:]
    private var activeSceneID: UUID?
    private var pendingAddress: PaneAddress?
    private var pendingReply: (address: PaneAddress, draftID: String)?
    let watchedRun = WatchedRun()
    private var activeScene: SceneState? { activeSceneID.flatMap { scenes[$0] } }
    var selectedHostID: HostProfile.ID? { activeScene?.selectedHostID ?? initialHostID }
    var connection: HostConnection? { activeScene.flatMap { connection(in: $0) } ?? selectedHostID.flatMap { primary[$0] } ?? demoConnection }

    func connection(in scene: SceneState) -> HostConnection? {
        if demo != nil { return demoConnection }
        guard let id = scene.selectedHostID ?? initialHostID else { return nil }
        if let session = scene.selectedSession {
            return connection(for: SessionAddress(hostID: id, session: session)) ?? primary[id]
        }
        return primary[id]
    }

    func register(_ scene: SceneState) {
        scene.selectedHostID = scene.selectedHostID ?? initialHostID
        scenes[scene.id] = scene
        activeSceneID = scene.id
        if let pendingAddress { self.pendingAddress = nil; open(pendingAddress, in: scene) }
        reconcile()
        resolveReply()
    }

    func unregister(_ scene: SceneState) {
        scenes.removeValue(forKey: scene.id)
        if activeSceneID == scene.id { activeSceneID = scenes.values.first(where: { $0.phase == .active })?.id }
        reconcile()
        if scenes.values.allSatisfy({ $0.phase == .background }) { scenePhaseChanged(.background) }
    }

    func scenePhaseChanged(_ phase: ScenePhase, in scene: SceneState) {
        scene.phase = phase
        if phase == .active { activeSceneID = scene.id }
        if phase == .active || scenes.values.allSatisfy({ $0.phase == .background }) {
            scenePhaseChanged(phase)
        }
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
    @ObservationIgnored private var attention: Attention?
    @ObservationIgnored private(set) var push: Push?
    /// Arming push watchers after leaving the foreground, under a UIKit background assertion.
    @ObservationIgnored private var handoff: (id: Int, task: Task<Void, Never>, assertion: UIBackgroundTaskIdentifier)?
    @ObservationIgnored private var handoffCount = 0
    static let refreshTask = "dev.btuckerc.herdwick.refresh"

    init() {
        if let launch = DemoLaunch.current {
            profiles = []
            startDemo(launch)
            return
        }
        profiles = ProfileStorage.load()
        attention = Attention(settings: settings, links: { [weak self] in self?.connections ?? [] },
                              profiles: { [weak self] in self?.profiles ?? [] },
                              pushOwns: { [weak self] in self?.push?.ownsAlerts(for: $0) ?? false },
                              onScreen: { [weak self] in self?.onScreen ?? [] },
                              open: { [weak self] address, draftID in
                                  guard let self else { return }
                                  if let draftID { self.pendingReply = (address, draftID) }
                                  self.open(address)
                                  self.resolveReply()
                              })
        push = Push(settings: settings)
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

    func select(_ id: HostProfile.ID, in scene: SceneState? = nil) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        endDemoHost()
        if let scene = scene ?? activeScene {
            if scene.selectedHostID != id {
                scene.selectedHostID = id
                scene.selectedSession = nil
                if !settings.allHosts { scene.navigationPath = [] }
            }
        }
        initialHostID = id
        UserDefaults.standard.set(id.uuidString, forKey: "selected-host")
        reconcile()
    }

    func selectSession(_ name: String, in scene: SceneState? = nil) {
        guard let scene = scene ?? activeScene else { return }
        scene.selectedSession = name
        scene.navigationPath = []
        reconcile()
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
        let selected = Set(scenes.values.compactMap(\.selectedHostID) + [initialHostID, watchedRun.address?.hostID].compactMap { $0 })
        let desired = Set(profiles.filter { settings.allHosts || selected.contains($0.id) }.map(\.id))
        for id in Array(primary.keys) where !desired.contains(id) {
            primary.removeValue(forKey: id)?.stop()
        }
        for key in Array(additional.keys) where !desired.contains(key.hostID) {
            additional.removeValue(forKey: key)?.stop()
        }
        for profile in profiles where desired.contains(profile.id) {
            if let link = primary[profile.id] {
                let changed = !link.includesAllSessions
                link.includesAllSessions = true
                if changed {
                    if isForeground { link.handle(.userRetry) }
                }
            } else {
                let link = HostConnection(profile: profile, tailnet: tailnet, onSessions: { [weak self] link in
                    self?.reconcileSessions(link)
                }) { [weak self] updated in self?.store(updated) }
                link.includesAllSessions = true
                link.onAttentionChange = { [weak self] in self?.changed($0) }
                link.onLive = { [weak self] in self?.wentLive($0) }
                primary[profile.id] = link
                if isForeground { link.handle(.start) }
            }
        }
    }

    private func reconcileSessions(_ primaryLink: HostConnection) {
        guard demo == nil, primary[primaryLink.profile.id] === primaryLink else { return }
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
            link.onAttentionChange = { [weak self] in self?.changed($0) }
            link.onLive = { [weak self] in self?.wentLive($0) }
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

    /// The user's host order: the title swipe, menus and the all-hosts inbox follow it.
    func moveProfiles(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        ProfileStorage.save(profiles)
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
        try? TranscriptCache.remove(hostID: profile.id)
        Keychain.delete(profile.passwordAccount)
        Keychain.delete(profile.hostKeyAccount)
        profiles.removeAll { $0.id == id }
        ProfileStorage.save(profiles)
        if initialHostID == id { initialHostID = profiles.first?.id }
        for scene in scenes.values where scene.selectedHostID == id {
            scene.selectedHostID = profiles.first?.id
            scene.selectedSession = nil
            scene.navigationPath = []
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
        for scene in scenes.values { scene.navigationPath = [] }
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
        for scene in scenes.values { scene.navigationPath = [] }
        endDemoHost()
        if let first = profiles.first { select(first.id) }
    }

    private func endDemoHost() {
        demoConnection?.stop()
        demoConnection = nil
        demo?.stop()
        demo = nil
    }

    // MARK: Attention

    func requestNotifications() async -> Bool {
        await attention?.requestAuthorization() ?? false
    }

    /// Settings turned alerts while away on.
    func registerForPush() {
        push?.register()
    }

    private func changed(_ link: HostConnection) {
        attention?.changed(link)
        if isForeground { watchedRun.changed(link, push: push) }
        resolveReply()
    }

    private func resolveReply() {
        guard let pendingReply, let scene = activeScene,
              let link = connection(for: pendingReply.address), link.isLive else { return }
        self.pendingReply = nil
        if let agent = link.snapshot?.agents.first(where: {
            DraftStore.id(host: link.identity, agent: $0) == pendingReply.draftID
        }) {
            scene.open(.conversation(link.address(paneID: agent.paneID)))
            scene.draftRevision += 1
        } else {
            scene.navigationPath = []
            scene.notificationNotice = "The original conversation is no longer live. Your reply is saved in its draft; it was not sent."
        }
    }
    /// An alert or a widget asked for this agent: show its host, then its conversation.
    func open(_ address: PaneAddress, in scene: SceneState? = nil) {
        guard demo == nil, profiles.contains(where: { $0.id == address.hostID }) else { return }
        guard let scene = scene ?? activeScene else { pendingAddress = address; return }
        select(address.hostID, in: scene)
        scene.selectedSession = address.session
        if pendingReply == nil { scene.open(.conversation(address)) }
        else { scene.navigationPath = [] }
        reconcile()
    }

    func open(_ url: URL, in scene: SceneState? = nil) {
        if url.scheme == "herdwick", ["inbox", "needs-you"].contains(url.host ?? "") {
            guard let scene = scene ?? activeScene else { return }
            scene.needsYouOnly = url.host == "needs-you"
            scene.navigationPath = []
            return
        }
        guard let link = AttentionLink.parse(url) else { return }
        open(PaneAddress(hostID: link.host, session: link.session, paneID: link.pane), in: scene)
    }

    private var onScreen: Set<PaneAddress> {
        Set(scenes.values.compactMap { scene in
            guard scene.phase == .active, case .conversation(let address)? = scene.navigationPath.last else { return nil }
            return address
        })
    }

    /// iOS wakes the app now and then: bring each link up long enough for one fresh snapshot,
    /// which raises any alerts and refreshes the widgets, then close them again.
    func backgroundRefresh() async {
        scheduleRefresh()
        guard demo == nil, !isForeground else { return }
        let links = connections
        let before = links.map(\.liveID)
        for link in links { link.handle(.foregrounded) }
        let deadline = ContinuousClock.now + .seconds(20)
        func settled(_ link: HostConnection, _ id: Int) -> Bool {
            if case .failed = link.phase { return true }
            return link.phase == .offline || link.liveID != id
        }
        while ContinuousClock.now < deadline, !isForeground, !zip(links, before).allSatisfy(settled) {
            // Out of time (iOS cancelled the task): stop waiting.
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { break }
        }
        guard !isForeground else { return }
        for link in links { link.handle(.backgrounded) }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
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
            guard demo == nil, let push else {
                for link in connections { link.handle(.backgrounded) }
                return
            }
            scheduleRefresh()
            // One already in flight closes the links when it ends.
            guard handoff == nil else { return }
            // Hand each host its push watcher over its live link, then close every link. Arming
            // is bounded well inside the time iOS grants, and stops early if that runs out.
            handoffCount += 1
            let id = handoffCount
            let links = connections
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "push-arm") { [weak self] in
                // Out of time: stop arming and close up now.
                MainActor.assumeIsolated {
                    guard let self, self.handoff?.id == id else { return }
                    self.handoff?.task.cancel()
                    self.finishHandoff(id)
                }
            }
            let task = Task {
                let known = self.profiles
                let hosts = Set(links.map { $0.profile.id })
                _ = try? await withTimeout(.seconds(10)) { @MainActor in
                    await push.arm(links, profiles: known, selectedHostIDs: hosts)
                }
                let back = isForeground
                finishHandoff(id)
                // Back before the watchers were up: the app watches for itself again.
                if back { for link in links where link.isLive { await push.disarm(link) } }
            }
            handoff = (id, task, assertion)
        default:
            break
        }
    }

    /// Ends handoff `id`: closes every link unless the app is back, and lets iOS suspend it.
    private func finishHandoff(_ id: Int) {
        guard let handoff, handoff.id == id else { return }
        self.handoff = nil
        if !isForeground { for link in connections { link.handle(.backgrounded) } }
        UIApplication.shared.endBackgroundTask(handoff.assertion)
    }

    /// Back in the foreground, the app watches for itself.
    private func wentLive(_ link: HostConnection) {
        guard isForeground, let push else { return }
        Task { await push.disarm(link) }
    }

    /// Only real route changes count (Wi-Fi ↔ cellular, a VPN coming up or down);
    /// NWPathMonitor also reports cosmetic updates that must not drop a live link.
    private func pathChanged(satisfied: Bool, signature: String) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature else { return }
        for link in connections { link.handle(.pathChanged(satisfied: satisfied)) }
    }
}
