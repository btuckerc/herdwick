import Foundation
import HerdrAPI
import HerdrDemo
import HerdwickSSH
import TailscaleKit

/// The live link to one host. It feeds scene, network and transport events into
/// `ConnectionSupervisor` and performs the effects it returns. The last snapshot
/// stays on screen while it reconnects.
@MainActor @Observable
final class HostConnection {
    private(set) var profile: HostProfile
    private(set) var phase: ConnectionSupervisor.Phase = .idle
    private(set) var snapshot: Snapshot?
    private(set) var sessions: [SessionInfo] = []
    private(set) var activeSession: String?
    /// Bumps each time a fresh transport goes live. Views key their streams on it.
    private(set) var liveID = 0
    private(set) var client: HerdrClient?
    /// Set when the host presented a key that differs from the pinned one.
    private(set) var rejectedHostKey: SSHHostKey?
    var hidden: [String: Int] = [:] {
        didSet {
            UserDefaults.standard.set(hidden, forKey: hiddenKey)
            if hidden != oldValue { onAttentionChange?(self) }
        }
    }
    /// Pane id → subagents last seen working in that agent's conversation. Feeds only run
    /// while a conversation is open, so this is last-known; the inbox gates it on the agent working.
    var workingSubagents: [String: Int] = [:]
    /// Called when a snapshot arrives or something is read, for alerts, the badge and widgets.
    var onAttentionChange: ((HostConnection) -> Void)?
    /// Called each time a fresh transport goes live.
    var onLive: ((HostConnection) -> Void)?
    private(set) var missingIntegrations: [IntegrationInfo] = []
    /// Host clock minus this device's, sampled once per connection; nil unless it is off by
    /// more than a minute beyond the round trip. Only warned about: times in the app come from the host.
    private(set) var clockSkew: TimeInterval?

    func checkIntegrations() async {
        guard demo == nil, let client, let session = activeSession else { return }
        let generation = generation
        guard let integrations = try? await client.integrations(session: session),
              generation == self.generation, session == activeSession else { return }
        missingIntegrations = integrations.filter {
            ["omp", "claude", "codex"].contains($0.target) && $0.available && $0.state == "not_installed"
        }
    }

    private func sampleClock(_ runner: any CommandRunner) async {
        let generation = generation
        let sent = Date()
        guard let channel = try? await runner.exec("date +%s") else { return }
        var bytes: [UInt8] = []
        do {
            for try await chunk in channel.output { bytes += chunk }
        } catch {
            await channel.close()
            return
        }
        await channel.close()
        let rtt = Date().timeIntervalSince(sent)
        guard generation == self.generation,
              let host = TimeInterval(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let offset = host - (sent.timeIntervalSince1970 + rtt / 2)
        clockSkew = abs(offset) - rtt > 60 ? offset : nil
    }

    func installIntegration(_ target: String) async throws {
        guard isLive, let client, let session = activeSession else { throw HerdrError.noResponse }
        try await client.installIntegration(target, session: session)
        await checkIntegrations()
    }

    private var supervisor: ConnectionSupervisor
    private var ssh: SSHConnection?
    private var attempt: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    /// A snapshot was on screen when this attempt began, so it is a reconnect.
    private var resuming = false
    private let tailnet: Tailnet
    /// The scripted host behind the demo; set instead of dialling SSH.
    private let demo: DemoHost?
    private let onProfileChange: (HostProfile) -> Void
    var includesAllSessions = false {
        didSet {
            // An aggregate fallback must not masquerade as the explicitly selected
            // session when returning to single-host mode.
            if !includesAllSessions, let wanted = profile.session, activeSession != wanted {
                activeSession = nil
                snapshot = nil
            }
        }
    }
    private let onSessions: ((HostConnection) -> Void)?

    init(profile: HostProfile, tailnet: Tailnet, demo: DemoHost? = nil, onSessions: ((HostConnection) -> Void)? = nil, onProfileChange: @escaping (HostProfile) -> Void) {
        self.profile = profile
        self.tailnet = tailnet
        self.demo = demo
        self.onProfileChange = onProfileChange
        self.onSessions = onSessions
        supervisor = ConnectionSupervisor(migratesAcrossRoutes: profile.isTailnet)
    }

    /// Usable: live, or live and being checked after its route moved.
    var isLive: Bool { phase == .live || phase == .resuming }

    var identity: SessionAddress {
        SessionAddress(hostID: profile.id, session: activeSession ?? profile.session ?? "")
    }

    func address(paneID: String) -> PaneAddress {
        PaneAddress(hostID: profile.id, session: activeSession ?? profile.session ?? "", paneID: paneID)
    }

    /// Reuse the live transport for discovery; retry a disconnected host.
    func refreshSessions() async {
        guard let client else {
            if case .connecting = phase { return }
            handle(.userRetry)
            return
        }
        let generation = generation
        do {
            let sessions = try await client.sessions()
            guard generation == self.generation, !Task.isCancelled else { return }
            self.sessions = sessions
            onSessions?(self)
            if let activeSession, !sessions.contains(where: { $0.running && $0.name == activeSession }) {
                handle(.userRetry)
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            handle(.dropped(failure(for: error)))
        }
    }

    /// What the link is doing, for a navigation subtitle; nil while live or idle.
    var statusText: String? {
        switch phase {
        case .live, .resuming, .idle, .suspended: nil
        case .failed: "Not connected"
        case .offline: "Offline"
        case .connecting: resuming ? "Reconnecting…" : "Connecting…"
        case .waiting(_, let delay):
            "Reconnecting in \(Int((Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18).rounded(.up)))s"
        }
    }

    // MARK: Read state

    /// What has been read on this phone; see `ReadState`. herdr's own "seen" belongs to the
    /// desk (it clears when a tab is focused there), so this stays local.
    private var read = ReadState()

    private var hiddenKey: String { "hidden.\(profile.id.uuidString).\(activeSession ?? "")" }
    private var readKey: String { "read.\(profile.id.uuidString).\(activeSession ?? "")" }

    private func loadRead() {
        read = UserDefaults.standard.data(forKey: readKey)
            .flatMap { try? JSONDecoder().decode(ReadState.self, from: $0) } ?? ReadState()
    }

    private func saveRead() {
        UserDefaults.standard.set(try? JSONEncoder().encode(read), forKey: readKey)
    }

    /// Needs you or finished since it was last read on this phone. Reading never changes the
    /// host's own state.
    func isUnread(_ agent: Agent) -> Bool {
        read.isUnread(pane: agent.paneID, status: agent.agentStatus, sequence: agent.stateChangeSeq ?? 0)
    }

    /// The state a row shows: an unread finish is done, a read one idle.
    func presentedStatus(_ agent: Agent) -> AgentStatus {
        read.presented(pane: agent.paneID, status: agent.agentStatus, sequence: agent.stateChangeSeq ?? 0)
    }

    func markSeen(_ agent: Agent) {
        guard isUnread(agent) else { return }
        read.markRead(pane: agent.paneID, sequence: agent.stateChangeSeq ?? 0)
        saveRead()
        onAttentionChange?(self)
    }

    func markUnread(_ agent: Agent) {
        read.markUnread(pane: agent.paneID, sequence: agent.stateChangeSeq ?? 0)
        saveRead()
        onAttentionChange?(self)
    }

    func hide(_ agent: Agent) {
        hidden[agent.paneID] = agent.stateChangeSeq ?? 0
    }

    func unhide(_ agent: Agent) {
        hidden.removeValue(forKey: agent.paneID)
    }

    private func reconcileHidden(_ snapshot: Snapshot) {
        for agent in snapshot.agents {
            guard let sequence = hidden[agent.paneID] else { continue }
            if agent.agentStatus == .blocked ||
                (agent.agentStatus == .done && (agent.stateChangeSeq ?? 0) > sequence) {
                hidden.removeValue(forKey: agent.paneID)
            }
        }
    }

    /// Agents seen for the first time start read; only later changes count.
    private func recordBaseline(_ snapshot: Snapshot) {
        if read.observe(snapshot.agents.map { ($0.paneID, $0.agentStatus, $0.stateChangeSeq ?? 0) }) {
            saveRead()
        }
    }

    // MARK: Message activity

    /// Pane id → how far its conversation's transcript has been read and when it last had a
    /// message; see `TranscriptActivity`. Kept per host and session across launches.
    private(set) var activity: [String: PaneActivity] = [:]
    private var activityRead: Task<Void, Never>?
    private var activityPending = false
    private var activityTimer: Task<Void, Never>?

    struct PaneActivity: Codable, Equatable, Sendable {
        /// The conversation this belongs to; a pane that starts another one starts over.
        var ref: AgentSessionRef
        /// Nil until the transcript file is found.
        var transcript: TranscriptActivity?
    }

    /// When the user last messaged `agent` or it last finished a turn, by the transcript's own
    /// clock; nil while unknown.
    func lastTurnAt(_ agent: Agent) -> Date? {
        guard let entry = activity[agent.paneID], entry.ref == agent.agentSession else { return nil }
        return entry.transcript?.lastTurnAt
    }

    /// A line of the newest message in `agent`'s transcript, for its inbox row; nil while unknown.
    func preview(_ agent: Agent) -> String? {
        guard let entry = activity[agent.paneID], entry.ref == agent.agentSession else { return nil }
        return entry.transcript?.preview
    }

    private var activityKey: String { "turns.\(profile.id.uuidString).\(activeSession ?? "")" }

    private func loadActivity() {
        // "activity.…" held times from any message, mid-turn narration included; its read
        // offsets would keep those, so it's dropped and the transcripts read afresh.
        UserDefaults.standard.removeObject(forKey: "activity.\(profile.id.uuidString).\(activeSession ?? "")")
        activity = UserDefaults.standard.data(forKey: activityKey)
            .flatMap { try? JSONDecoder().decode([String: PaneActivity].self, from: $0) } ?? [:]
    }

    /// Reads what each agent's transcript gained since the last look: one host command per
    /// round, parsed off the main actor. A request while one runs is folded into one more.
    func refreshActivity() {
        guard activityRead == nil else {
            activityPending = true
            return
        }
        guard let client, let session = activeSession, let agents = snapshot?.agents else { return }
        let generation = generation
        let current = activity
        activityRead = Task { [weak self] in
            let updated = await Self.readActivity(current, agents: agents, client: client, session: session)
            guard let self else { return }
            self.activityRead = nil
            if generation == self.generation, session == self.activeSession, updated != self.activity {
                self.activity = updated
                UserDefaults.standard.set(try? JSONEncoder().encode(updated), forKey: self.activityKey)
            }
            if self.activityPending {
                self.activityPending = false
                self.refreshActivity()
            }
        }
    }

    /// A failed read keeps what was known; the snapshot is authoritative for which panes remain.
    nonisolated private static func readActivity(_ current: [String: PaneActivity], agents: [Agent],
                                                 client: HerdrClient, session: String) async -> [String: PaneActivity] {
        var next: [String: PaneActivity] = [:]
        for agent in agents {
            guard let ref = agent.agentSession, TranscriptFormat(agent: ref.agent) != nil else { continue }
            var entry = current[agent.paneID].flatMap { $0.ref == ref ? $0 : nil } ?? PaneActivity(ref: ref)
            if entry.transcript == nil, let location = try? await client.locateTranscript(ref, pane: agent.paneID, session: session) {
                entry.transcript = TranscriptActivity(path: location.path, format: location.format)
            }
            next[agent.paneID] = entry
        }
        var panes = Set(next.keys)
        for _ in 0..<12 {
            let reads = next.filter { panes.contains($0.key) }.compactMapValues { entry in entry.transcript.map { ($0.path, $0.nextRead) } }
            guard !Task.isCancelled, !reads.isEmpty, let chunks = try? await client.readChunks(reads) else { break }
            for (pane, chunk) in chunks {
                next[pane]?.transcript?.absorb(size: chunk.size, from: chunk.from, bytes: chunk.bytes)
            }
            panes = panes.filter { next[$0]?.transcript?.needsMore == true }
            if panes.isEmpty { break }
        }
        return next
    }

    /// Messages can arrive without any status change, so a live link also looks on a timer.
    private func startActivityTimer() {
        activityTimer?.cancel()
        activityTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.refreshActivity()
            }
        }
    }

    // MARK: Inputs

    func handle(_ input: ConnectionSupervisor.Input) {
        let effects = supervisor.handle(input)
        phase = supervisor.phase
        for effect in effects {
            switch effect {
            case .connect:
                connect()
            case .verify:
                verify()
            case .disconnect:
                teardown()
            case .scheduleRetry(let delay):
                retry?.cancel()
                retry = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.handle(.retryTimerFired)
                }
            case .cancelRetry:
                retry?.cancel()
                retry = nil
            }
        }
    }

    /// Closes the link for good: its host or session was removed or replaced.
    func stop() {
        handle(.stop)
    }

    /// Pins the key the host now presents and reconnects.
    func trustPresentedHostKey() {
        guard let key = rejectedHostKey else { return }
        Keychain.set(key.publicKey, for: profile.hostKeyAccount)
        rejectedHostKey = nil
        handle(.userRetry)
    }

    func switchSession(to name: String) {
        guard name != activeSession else { return }
        profile.session = name
        onProfileChange(profile)
        snapshot = nil
        handle(.userRetry)
    }

    // MARK: Actions

    var lastAgentKind: String {
        get {
            let value = UserDefaults.standard.string(forKey: "lastAgentKind.\(profile.id.uuidString)") ?? "omp"
            return ["omp", "claude", "codex"].contains(value) ? value : "omp"
        }
        set { UserDefaults.standard.set(newValue, forKey: "lastAgentKind.\(profile.id.uuidString)") }
    }

    enum StartOutcome {
        case busy(String)
        case started(Agent, PaneAddress)
    }

    /// `freshPane`: the caller just created `paneID`, so its shell can't hold user work but may
    /// still be running startup files.
    func startAgent(kind: String, arguments: [String] = [], paneID: String, inNewTab: Bool = false, freshPane: Bool = false) async throws -> StartOutcome {
        guard let client, let session = activeSession, isLive else { throw HerdrError.noResponse }
        lastAgentKind = kind
        var target = paneID
        if inNewTab {
            guard let pane = snapshot?.panes.first(where: { $0.id == paneID }) else { throw HerdrError.noResponse }
            target = try await client.createTab(workspaceID: pane.workspaceID, label: nil, cwd: pane.cwd, session: session).rootPane.id
        }
        let fresh = inNewTab || freshPane
        // A fresh tab can't be busy with user work, but its shell may still be running startup
        // helpers (e.g. mise); the retry below waits those out instead.
        if demo == nil, !fresh, let info = try? await client.processInfo(paneID: target, session: session),
           let process = info.foregroundProcesses?.first(where: { !$0.isShell }) {
            return .busy(process.command)
        }
        // herdr names: lowercase, digits, '-' or '_', at most 32 characters.
        let name = "\(kind)-\(UUID().uuidString.lowercased().prefix(6))"
        var agent: Agent
        var attempts = 0
        while true {
            do {
                agent = try await client.startAgent(name: name, kind: kind, paneID: target,
                                                    args: arguments.isEmpty ? nil : arguments, session: session).agent
                break
            } catch HerdrError.api(code: "agent_pane_busy", _) where fresh && attempts < 20 {
                // A new tab's shell is still running its startup files.
                attempts += 1
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        // Waits for the mirror to show the agent, so the conversation doesn't open on "Agent
        // exited". Agents herdr has no integration for never report a transcript: don't wait for one.
        for _ in 0..<20 {
            if let live = snapshot?.agents.first(where: { $0.paneID == target }) {
                if live.hasTranscript || !agent.hasTranscript { agent = live }
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !agent.hasTranscript { await checkIntegrations() }
        return .started(agent, PaneAddress(hostID: profile.id, session: session, paneID: target))
    }

    /// Waits (bounded) until the mirror shows `paneID`, so a view opened on it has its pane.
    func awaitPane(_ paneID: String) async {
        for _ in 0..<20 {
            if snapshot?.panes.contains(where: { $0.id == paneID }) == true { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func sendText(_ text: String, pane: String, submit: Bool) async throws {
        guard let client, let activeSession else { throw HerdrError.noResponse }
        try await client.sendText(text, pane: pane, submit: submit, session: activeSession)
    }

    func upload(_ data: Data, filename: String, retention: AttachmentRetention) async throws -> String {
        guard let ssh, let activeSession, isLive else { throw HerdrError.noResponse }
        return try await AttachmentUpload.upload(data, session: activeSession, filename: filename,
                                                retentionMinutes: retention.minutes, runner: ssh)
    }

    func sendKeys(_ keys: [String], pane: String) async throws {
        guard let client, let activeSession else { throw HerdrError.noResponse }
        try await client.sendKeys(keys, pane: pane, session: activeSession)
    }

    /// Starts this session's push watcher with `config`, or stops it given nil. Over the SSH
    /// link, so only while it is live.
    func watch(_ config: PushWatch.Config?) async throws {
        guard let ssh, isLive, let activeSession else { throw HerdrError.noResponse }
        if let config {
            guard let herdrPath = Self.cachedHerdrPath(profile) else { throw HerdrError.noResponse }
            try await PushWatch.arm(config, session: activeSession, herdrPath: herdrPath, runner: ssh)
        } else {
            try await PushWatch.disarm(installationID: Push.installationID, hostID: profile.id, session: activeSession, runner: ssh)
        }
    }

    // MARK: Effects

    private func connect() {
        resuming = snapshot != nil
        teardown()
        let generation = generation
        let profile = profile
        let demo = demo
        attempt = Task { [weak self] in
            guard let self else { return }
            var wentLive = false
            do {
                let runner: any CommandRunner
                if let demo {
                    runner = demo
                } else {
                    let ssh = try await self.dial(profile)
                    guard generation == self.generation else {
                        await ssh.close()
                        return
                    }
                    self.ssh = ssh
                    runner = ssh
                }
                let client = HerdrClient(runner: runner, herdrPath: demo == nil ? Self.cachedHerdrPath(profile) : nil)
                let herdrPath = try await client.resolveHerdrPath()
                if demo == nil { Self.cache(herdrPath: herdrPath, for: profile) }
                guard generation == self.generation else { return }
                // Subscribe to the likely session while listing sessions; the list decides
                // whether that mirror is kept. Dropping an unused stream closes its bridge.
                let guess = profile.session ?? self.activeSession ?? Self.lastSession(profile)
                var speculative = guess.map { client.mirror(session: $0, panes: self.knownPanes(in: $0)) }
                let sessions = try await client.sessions()
                guard generation == self.generation else { return }
                self.sessions = sessions
                let wanted = self.includesAllSessions && !sessions.contains(where: { $0.running && $0.name == profile.session })
                    ? nil : profile.session
                guard sessions.contains(where: \.running) else {
                    self.activeSession = nil
                    self.snapshot = nil
                    self.onSessions?(self)
                    throw SessionError.none
                }
                let session = try Self.pickSession(wanted, from: sessions)
                if self.activeSession != session {
                    self.snapshot = nil
                    self.resuming = false
                }
                self.activeSession = session
                if demo == nil { Self.remember(session: session, for: profile) }
                self.hidden = UserDefaults.standard.dictionary(forKey: self.hiddenKey) as? [String: Int] ?? [:]
                self.loadRead()
                self.loadActivity()
                self.onSessions?(self)

                let snapshots = (session == guess ? speculative : nil) ?? client.mirror(session: session, panes: self.knownPanes(in: session))
                speculative = nil
                for try await update in snapshots {
                    guard generation == self.generation else { return }
                    self.apply(update.snapshot, authoritative: { if case .live = update { true } else { false } }())
                    if case .live = update, !wentLive {
                        wentLive = true
                        self.client = client
                        self.liveID += 1
                        self.handle(.connected)
                        self.onLive?(self)
                        self.startActivityTimer()
                        self.refreshActivity()
                        Task { await self.checkIntegrations() }
                        if demo == nil { Task { await self.sampleClock(runner) } }
                    }
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                self.handle(wentLive ? .dropped(ConnectionFailure("Connection closed", retryable: true)) : .connectFailed(ConnectionFailure("Connection closed", retryable: true)))
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                let failure = self.failure(for: error)
                self.handle(wentLive ? .dropped(failure) : .connectFailed(failure))
            }
        }
    }

    /// The tailnet moved the link to a new route by itself: one fresh snapshot shows that
    /// SSH and herdr still answer, and catches up on anything lost while the route moved.
    /// Streams carry on meanwhile; a link that does not answer is replaced.
    private func verify() {
        guard let client, let session = activeSession else {
            handle(.dropped(ConnectionFailure("Connection closed", retryable: true)))
            return
        }
        let generation = generation
        verification?.cancel()
        verification = Task { [weak self] in
            do {
                let snapshot = try await withTimeout(.seconds(10)) { try await client.snapshot(session: session) }
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.apply(snapshot, authoritative: true)
                self.handle(.connected)
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.handle(.dropped(self.failure(for: error)))
            }
        }
    }

    /// The panes of the snapshot on screen, if it shows `session`; a redial subscribes to
    /// them while it takes the preview.
    private func knownPanes(in session: String) -> Set<String>? {
        guard session == activeSession, let snapshot else { return nil }
        return Set(snapshot.panes.map(\.id))
    }

    private func apply(_ snapshot: Snapshot, authoritative: Bool) {
        if authoritative, demo == nil, let session = activeSession {
            let paths = activity.filter { pane, value in
                snapshot.agents.contains { $0.paneID == pane && $0.agentSession == value.ref }
            }.compactMapValues { $0.transcript?.path }
            EndedAgents.shared.observe(snapshot, hostID: profile.id, session: session, paths: paths)
        }
        self.snapshot = snapshot
        recordBaseline(snapshot)
        reconcileHidden(snapshot)
        onAttentionChange?(self)
        // A status change usually comes with a message; look now rather than at the next tick.
        refreshActivity()
    }

    private func teardown() {
        generation += 1
        attempt?.cancel()
        attempt = nil
        verification?.cancel()
        verification = nil
        activityTimer?.cancel()
        activityTimer = nil
        activityRead?.cancel()
        client = nil
        if let ssh {
            self.ssh = nil
            Task { await ssh.close() }
        }
    }

    private func dial(_ profile: HostProfile) async throws -> SSHConnection {
        let authentication: SSHAuthentication = switch profile.auth {
        case .deviceKey: .ed25519(DeviceKey.load(hostID: profile.id))
        case .password: .password(Keychain.string(for: profile.passwordAccount) ?? "")
        case .tailscaleSSH: .none
        }
        switch profile.route {
        case .direct(let host, let port):
            return try await SSHConnection.connect(
                host: host, port: port, username: profile.username,
                authentication: authentication, hostKeyValidator: validator(for: profile, tailnetKeys: [])
            )
        case .tailnet(let nodeID, _, let address):
            let handle = try await tailnet.readyHandle()
            let peer = tailnet.peer(id: nodeID)
            let fd = try await withTimeout(.seconds(15)) { [tailnet] in
                try await tailnet.dial(address: peer?.address ?? address, port: 22, handle: handle)
            }
            return try await SSHConnection.connect(
                adoptingConnectedSocket: fd, username: profile.username,
                authentication: authentication,
                hostKeyValidator: validator(for: profile, tailnetKeys: peer?.sshHostKeys ?? [])
            )
        }
    }

    /// Trust on first use, pinned in the keychain. For tailnet peers the first key must
    /// also be one Tailscale's coordination server lists for that machine.
    private func validator(for profile: HostProfile, tailnetKeys: [String]) -> HostKeyValidator {
        let account = profile.hostKeyAccount
        let pinned = Keychain.string(for: account)
        let known = Set(tailnetKeys.map(Self.keyIdentity))
        rejectedHostKey = nil
        return { [weak self] key in
            if let pinned {
                if Self.keyIdentity(pinned) == Self.keyIdentity(key.publicKey) { return true }
                Task { @MainActor in self?.rejectedHostKey = key }
                return false
            }
            if !known.isEmpty, !known.contains(Self.keyIdentity(key.publicKey)) {
                Task { @MainActor in self?.rejectedHostKey = key }
                return false
            }
            Keychain.set(key.publicKey, for: account)
            return true
        }
    }

    /// `ssh-ed25519 AAAA…` without any trailing comment.
    nonisolated private static func keyIdentity(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    private func failure(for error: any Error) -> ConnectionFailure {
        switch error {
        case SSHError.authenticationFailed:
            let hint = switch profile.auth {
            case .deviceKey: "Add this iPhone's key to ~/.ssh/authorized_keys on \(profile.address)."
            case .password: "Check the username and password."
            case .tailscaleSSH: "Tailscale SSH refused this device. Check the tailnet's SSH policy, or use this iPhone's key."
            }
            return ConnectionFailure("\(profile.username)@\(profile.address) rejected the login. \(hint)", retryable: false)
        case SSHError.hostKeyRejected(let fingerprint):
            return ConnectionFailure("The host key changed (\(fingerprint)). If you reinstalled or replaced this machine, trust the new key.", retryable: false)
        case SSHError.invalidPrivateKey(let reason):
            return ConnectionFailure(reason, retryable: false)
        case HerdrError.herdrNotFound:
            return ConnectionFailure("herdr isn't installed on \(profile.address), or isn't on the login shell's PATH.", retryable: false)
        case SessionError.notRunning(let name):
            return ConnectionFailure("The herdr session “\(name)” isn't running. Start herdr on \(profile.address), then retry.", retryable: false)
        case SessionError.none:
            return ConnectionFailure("No herdr session is running on \(profile.address). Start herdr there, then retry.", retryable: false)
        case TailnetError.signedOut:
            return ConnectionFailure("This iPhone is signed out of Tailscale.", retryable: false)
        case let error as CommandError:
            if case .exited(_, let stderr) = error, !stderr.isEmpty {
                return ConnectionFailure(stderr.trimmingCharacters(in: .whitespacesAndNewlines), retryable: true)
            }
            return ConnectionFailure("The host closed the connection.", retryable: true)
        default:
            return ConnectionFailure((error as? LocalizedError)?.errorDescription ?? "\(error)", retryable: true)
        }
    }

    // MARK: Sessions and caches

    enum SessionError: Error {
        case none
        case notRunning(String)
    }

    private static func pickSession(_ wanted: String?, from sessions: [SessionInfo]) throws -> String {
        if let wanted {
            guard let match = sessions.first(where: { $0.name == wanted }) else { throw SessionError.notRunning(wanted) }
            guard match.running else { throw SessionError.notRunning(wanted) }
            return wanted
        }
        let running = sessions.filter(\.running)
        if let preferred = running.first(where: \.isDefault) ?? running.first { return preferred.name }
        throw SessionError.none
    }

    private static func cachedHerdrPath(_ profile: HostProfile) -> String? {
        UserDefaults.standard.string(forKey: "herdr-path.\(profile.id.uuidString)")
    }

    private static func cache(herdrPath: String, for profile: HostProfile) {
        UserDefaults.standard.set(herdrPath, forKey: "herdr-path.\(profile.id.uuidString)")
    }

    /// The session last opened on this host; only a guess to subscribe early, never a choice.
    private static func lastSession(_ profile: HostProfile) -> String? {
        UserDefaults.standard.string(forKey: "last-session.\(profile.id.uuidString)")
    }

    private static func remember(session: String, for profile: HostProfile) {
        UserDefaults.standard.set(session, forKey: "last-session.\(profile.id.uuidString)")
    }
}

/// Runs `operation`, giving up after `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "The host didn't answer in time." }
}
