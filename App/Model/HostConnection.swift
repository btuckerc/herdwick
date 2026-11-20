import Foundation
import HerdrAPI
import HerdrDemo
import HerdwickSSH
import os
import TailscaleKit

/// The live link to one host. It feeds scene, network and transport events into
/// `ConnectionSupervisor` and performs the effects it returns. The last snapshot
/// stays on screen while it reconnects.
@MainActor @Observable
final class HostConnection {
    private(set) var profile: HostProfile
    private(set) var phase: ConnectionSupervisor.Phase = .idle
    /// While the link is down: when the host was last heard from (a snapshot or an activity
    /// read), so what's on screen is as of then (round 8: the time the loss was noticed, which
    /// a quiet link could make minutes newer than the last word from the host).
    private(set) var lostAt: Date?
    @ObservationIgnored private var heardAt: Date?
    private(set) var snapshot: Snapshot? { didSet { updateEpochs(from: oldValue) } }
    /// Each pane's current agent's `AgentStamp.epoch`.
    @ObservationIgnored private var epochs: [String: Int] = [:]
    @ObservationIgnored private var lastEpoch = 0
    /// When each pane's agent last went back to work, seen here: its status turning to working
    /// or its screen prompt clearing. `stillSince` and `resumed` count from it.
    @ObservationIgnored private var resumedAt: [String: Date] = [:]
    private(set) var sessions: [SessionInfo] = []
    private(set) var activeSession: String? {
        // Pane IDs repeat across sessions: closes sent in another session don't hide this one's panes.
        didSet { if let activeSession, activeSession != closingSession { closing = [] } }
    }
    /// Bumps each time a fresh transport goes live. Views key their streams on it.
    private(set) var liveID = 0
    private(set) var client: HerdrClient?
    /// Set when the host presented a key that differs from the pinned one.
    private(set) var rejectedHostKey: SSHHostKey?
    /// Panes a close was sent for, kept out of every list until a snapshot drops them.
    private(set) var closing: Set<String> = []
    /// The session `closing` belongs to.
    private var closingSession: String?
    var hidden: [String: Int] = [:] {
        didSet {
            UserDefaults.standard.set(hidden, forKey: hiddenKey)
            if hidden != oldValue { onAttentionChange?(self) }
        }
    }
    /// Pane id → subagents last seen working in that agent's conversation. Feeds only run
    /// while a conversation is open, so this is last-known; the inbox gates it on the agent working.
    var workingSubagents: [String: Int] = [:]
    let conversations: ConversationRegistry
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
    /// Ends an attempt that has no live snapshot within `connectBudget`.
    private var deadline: Task<Void, Never>?
    private var generation = 0
    /// A snapshot was on screen when this attempt began, so it is a reconnect.
    private var resuming = false
    private let tailnet: Tailnet
    /// The scripted host behind the demo; set instead of dialling SSH.
    private let demo: DemoHost?
    var includesAllSessions = false
    private let onSessions: ((HostConnection) -> Void)?

    init(profile: HostProfile, tailnet: Tailnet, conversations: ConversationRegistry, demo: DemoHost? = nil, onSessions: ((HostConnection) -> Void)? = nil) {
        self.profile = profile
        self.tailnet = tailnet
        self.conversations = conversations
        self.demo = demo
        self.onSessions = onSessions
        supervisor = ConnectionSupervisor(migratesAcrossRoutes: profile.isTailnet)
        restore()
    }

    /// Paints the last authoritative snapshot of the likely session before any network: the
    /// inbox shows at launch, dimmed until live, and the first connect subscribes to its panes
    /// alongside the preview. `connect` replaces it, or drops it if another session is chosen.
    private func restore() {
        guard demo == nil, profile.isEnabled, let session = profile.session ?? Self.lastSession(profile),
              let copy = SnapshotStore.load(hostID: profile.id, session: session) else { return }
        activeSession = session
        sessions = copy.sessions
        snapshot = copy.snapshot
        hidden = UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: Int] ?? [:]
        loadRead()
        loadSeenWaits()
        loadActivity()
    }

    /// Usable: live, or live and being checked after its route moved.
    var isLive: Bool { phase == .live || phase == .resuming }

    /// The live link, if any, rides the in-app tailnet.
    var ridesTailnet: Bool { isLive && supervisor.migratesAcrossRoutes }

    var identity: SessionAddress {
        SessionAddress(hostID: profile.id, session: activeSession ?? profile.session ?? "")
    }

    func address(paneID: String) -> PaneAddress {
        PaneAddress(hostID: profile.id, session: activeSession ?? profile.session ?? "", paneID: paneID)
    }

    /// Reuse the live transport for discovery; retry a disconnected host. `explicit`: the user
    /// asked, so an attempt still under way starts over too (the automatic refresh on every
    /// foreground leaves it be). A live link that doesn't answer within `checkBound` is taken
    /// as dead and redialled: its transport can stall silently, and the 60 s keepalive and
    /// channel deadlines are far too long to hold a pull to refresh.
    func refreshSessions(explicit: Bool = false) async {
        guard let client else {
            if case .connecting = phase, !explicit { return }
            handle(.userRetry)
            return
        }
        let generation = generation
        do {
            let sessions = try await withTimeout(Self.checkBound) { try await client.sessions() }
            guard generation == self.generation, !Task.isCancelled else { return }
            self.sessions = sessions
            onSessions?(self)
            if let activeSession, !sessions.contains(where: { $0.running && $0.name == activeSession }) {
                handle(.userRetry)
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            ConnectTrace.note("refresh check failed (\(ConnectTrace.kind(of: error)))")
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

    /// Dialling, or waiting to dial again: the screen shows the last state it had.
    var isConnecting: Bool {
        switch phase {
        case .connecting, .waiting: true
        default: false
        }
    }

    /// Unreachable after trying: failed, offline, or retrying after a failed attempt.
    var isDown: Bool {
        switch phase {
        case .failed, .offline, .waiting: true
        case .connecting(let attempt): attempt > 1
        case .idle, .suspended, .resuming, .live: false
        }
    }

    /// Stopped on a failure only the user can fix; the inbox shows its `FailureCard`.
    var isFailed: Bool {
        if case .failed = phase { true } else { false }
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
        if let wait = wait(agent), !seenWaits.contains(wait.id) { return true }
        return read.isUnread(pane: agent.paneID, status: agent.agentStatus, sequence: agent.stateChangeSeq ?? 0)
    }

    /// The state a row shows: an unread finish is done, a read one idle; a wait herdr doesn't
    /// report (see `Wait`) needs you.
    func presentedStatus(_ agent: Agent) -> AgentStatus {
        if wait(agent) != nil { return .blocked }
        return read.presented(pane: agent.paneID, status: agent.agentStatus, sequence: agent.stateChangeSeq ?? 0)
    }

    func markSeen(_ agent: Agent) {
        guard isUnread(agent) else { return }
        if let wait = wait(agent) { seeWait(wait.id) }
        read.markRead(pane: agent.paneID, sequence: agent.stateChangeSeq ?? 0)
        saveRead()
        onAttentionChange?(self)
    }

    func markUnread(_ agent: Agent) {
        if let wait = wait(agent) { seenWaits.removeAll { $0 == wait.id }; saveSeenWaits() }
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

    /// The stamp of `agent` while the newest snapshot still has it in its pane, in this session.
    func stamp(of agent: Agent) -> AgentStamp? {
        guard let session = activeSession, let epoch = epochs[agent.paneID],
              let current = snapshot?.agents.first(where: { $0.paneID == agent.paneID }),
              Self.sameAgent(current, agent) else { return nil }
        return AgentStamp(session: session, paneID: agent.paneID, epoch: epoch)
    }

    /// The agent `stamp` names, if it's still there and still the same one.
    func agent(for stamp: AgentStamp) -> Agent? {
        guard stamp.session == activeSession, epochs[stamp.paneID] == stamp.epoch else { return nil }
        return snapshot?.agents.first { $0.paneID == stamp.paneID }
    }

    private static func sameAgent(_ a: Agent, _ b: Agent) -> Bool {
        a.agent == b.agent && a.agentSession == b.agentSession
    }

    /// `agent` as the newest snapshot has it; nil once it's gone from its pane or replaced.
    private func latest(_ agent: Agent) -> Agent? {
        snapshot?.agents.first { $0.paneID == agent.paneID && Self.sameAgent($0, agent) }
    }

    /// A pane keeps its epoch while each snapshot shows the same agent in it; anything else in
    /// the pane (gone, another kind, another conversation) gets a new one.
    private func updateEpochs(from old: Snapshot?) {
        guard let snapshot else {
            epochs = [:]
            return
        }
        let previous = Dictionary((old?.agents ?? []).map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [String: Int] = [:]
        for agent in snapshot.agents where next[agent.paneID] == nil {
            if let prior = previous[agent.paneID], Self.sameAgent(prior, agent), let epoch = epochs[agent.paneID] {
                next[agent.paneID] = epoch
                if prior.agentStatus != .working && agent.agentStatus == .working { resumedAt[agent.paneID] = .now }
            } else {
                lastEpoch += 1
                resumedAt[agent.paneID] = nil
                next[agent.paneID] = lastEpoch
            }
        }
        epochs = next
        resumedAt = resumedAt.filter { next[$0.key] != nil }
    }

    /// Ends an agent and its terminal. Its thread leaves every list as this is called (inside
    /// the caller's animation) rather than when herdr's next snapshot drops it, and comes back
    /// if herdr refuses; the task carries herdr's answer. Nil, and nothing sent, when the agent
    /// the user chose is no longer in its pane (`AgentStamp`).
    @discardableResult
    func close(_ stamp: AgentStamp) -> Task<Void, Error>? {
        guard agent(for: stamp) != nil else { return nil }
        if closingSession != activeSession { closing = [] }
        closingSession = activeSession
        closing.insert(stamp.paneID)
        let client = client, session = stamp.session, paneID = stamp.paneID
        return Task {
            do {
                guard let client else { throw HerdrError.noResponse }
                try await client.closePane(paneID, session: session)
            } catch {
                if closingSession == session { closing.remove(paneID) }
                throw error
            }
        }
    }

    /// Names an agent's thread in herdr, so every client and herdr itself show it; blank goes
    /// back to the agent's own title. The name arrives with herdr's next pane update.
    func rename(paneID: String, to name: String) async throws {
        guard let client, let session = activeSession else { throw HerdrError.noResponse }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.renamePane(paneID, label: name.isEmpty ? nil : name, session: session)
    }

    private func reconcileHidden(_ snapshot: Snapshot) {
        for agent in snapshot.agents {
            guard let sequence = hidden[agent.paneID] else { continue }
            if presentedStatus(agent) == .blocked ||
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

    // MARK: Waits

    /// A terminal-confirmed question/approval, Plan Review, or PTY input wait. Screen
    /// prompts are probed even without a parsed transcript: integrations can report them
    /// as working or idle instead of blocked.
    struct Wait: Equatable, Sendable {
        /// Unlike the pane's `state_change_seq`, which a wait doesn't move, this tells one
        /// wait from the next: the PTY call's id, or the plan's.
        let id: String
        let ref: AgentSessionRef?
        let console: ConsoleScreen?
        let prompt: ScreenPrompt?

        init(id: String, ref: AgentSessionRef?, console: ConsoleScreen?, prompt: ScreenPrompt? = nil) {
            self.id = id; self.ref = ref; self.console = console; self.prompt = prompt
        }

        /// One line for the inbox: the console's prompt, or the screen prompt and what it's about
        /// ("Allow bash? bun test"), so a halted agent says why. Its line breaks become spaces, so
        /// a two-line row isn't spent on a wrapped command's first half.
        var summary: String? {
            if let prompt = console?.prompt { return prompt }
            guard let prompt else { return nil }
            return ([prompt.title] + (prompt.subject.map { [$0] } ?? [])).joined(separator: " ")
                .split(whereSeparator: \.isNewline).joined(separator: " ")
        }
    }

    private var waits: [String: Wait] = [:]
    /// Pane → the console last read for a PTY call, and since when it has looked the same.
    private var consoleReads: [String: (id: String, screen: ConsoleScreen, since: Date)] = [:]
    private var waitProbe: Task<Void, Never>?
    /// Pane → the `state_change_seq` its conversation was last checked for a wait at. A
    /// finish isn't alerted before this passes it, so a Plan Review never alerts as "Finished".
    private var waitChecked: [String: Int] = [:]
    /// Waits present at the first check after the link went live: the push watcher alerted
    /// for them while the app was away, so they don't alert again here.
    private(set) var silentWaits: Set<String> = []
    private var waitBaselinePending = true
    private var consoleBaselinePending = true
    /// PTY call id → its console at the first read after the link went live. A wait confirmed
    /// on that same console is one the watcher could have alerted for; a later prompt isn't.
    private var baselineConsoles: [String: ConsoleScreen] = [:]
    private var seenWaits: [String] = []
    private var seenWaitsKey: String { "waitsSeen.\(profile.id.uuidString).\(activeSession ?? "")" }

    /// A screen-confirmed prompt holds while the agent isn't working (herdr may call it idle);
    /// once it works again the prompt was answered, whatever the last probe saw.
    func wait(_ agent: Agent) -> Wait? {
        guard let wait = waits[agent.paneID], wait.ref == agent.agentSession else { return nil }
        if wait.prompt != nil { return agent.agentStatus == .working ? nil : wait }
        let working = agent.agentStatus == .working
        return wait.console == nil ? (agent.agentStatus == .idle || agent.agentStatus == .done ? wait : nil)
            : (working ? wait : nil)
    }

    /// Whether `agent`'s conversation was checked for a wait since its last state change.
    func waitChecked(_ agent: Agent) -> Bool {
        (waitChecked[agent.paneID] ?? -1) >= (agent.stateChangeSeq ?? 0)
    }

    private func seeWait(_ id: String) {
        guard !seenWaits.contains(id) else { return }
        seenWaits = Array((seenWaits + [id]).suffix(64))
        saveSeenWaits()
    }

    private func loadSeenWaits() {
        seenWaits = UserDefaults.standard.stringArray(forKey: seenWaitsKey) ?? []
    }

    private func saveSeenWaits() {
        UserDefaults.standard.set(seenWaits, forKey: seenWaitsKey)
    }

    /// Plan Reviews settle from the transcript. Screens are read only where a prompt can be:
    /// agents herdr calls blocked, stopped agents with a tool call still open (an approval
    /// holds it) or with no transcript reference (omp without herdr's integration shows an
    /// approval as idle), and PTY calls. A working agent's output is never read as a prompt.
    /// PTY consoles retain their ten-second settling rule; a structured prompt settles at once.
    private func updateWaits(_ agents: [Agent]) {
        waitProbe?.cancel()
        waitProbe = nil
        let host = identity
        var found: [String: Wait] = [:]
        var candidates: [String: TerminalInputWait] = [:]
        var probes: [Agent] = []
        for agent in agents {
            let conversation = conversations.parsed(host: host, agent: agent)
            if let slug = conversation?.pendingPlanReview {
                found[agent.paneID] = Wait(id: "plan:\(agent.agentSession?.value ?? agent.paneID):\(slug)",
                                           ref: agent.agentSession, console: nil)
            } else if agent.agentStatus == .working, let call = conversation?.pendingTerminalInput,
                      call.startedAt.map({ Date.now.timeIntervalSince($0) >= 10 }) ?? true {
                candidates[agent.paneID] = call
            }
            guard ["omp", "claude", "codex"].contains(agent.agent ?? "") else { continue }
            let stopped = agent.agentStatus != .working
            if candidates[agent.paneID] != nil || agent.agentStatus == .blocked
                || stopped && (agent.agentSession == nil || conversation?.runningTools.isEmpty == false) {
                probes.append(agent)
            }
        }
        let checked = Dictionary(agents.map { ($0.paneID, $0.stateChangeSeq ?? 0) }) { first, _ in first }
        let baseline = waitBaselinePending
        waitBaselinePending = false
        if baseline { silentWaits.formUnion(found.values.map(\.id)) }
        var settled = found
        for agent in probes {
            if let wait = waits[agent.paneID], wait.ref == agent.agentSession,
               wait.prompt != nil || wait.id == candidates[agent.paneID]?.toolCallId {
                settled[agent.paneID] = wait
            }
        }
        // Don't call a freshly finished agent done before checking its approval screen.
        settleWaits(settled, checked: waitChecked)
        let ids = Set(candidates.values.map(\.toolCallId))
        baselineConsoles = baselineConsoles.filter { ids.contains($0.key) }
        guard !probes.isEmpty, let client, let session = activeSession else {
            settleWaits(found, checked: checked)
            return
        }
        let generation = generation
        waitProbe = Task { [weak self] in
            var visible: [String: String] = [:]
            var skipped: Set<String> = []
            for agent in probes {
                if Task.isCancelled { return }
                // `probes` was chosen before these awaits: never read a screen whose agent has
                // since started working (unless a terminal tool of its waits) or been replaced.
                guard let latest = self?.latest(agent), self?.activeSession == session,
                      latest.agentStatus != .working || candidates[agent.paneID] != nil else {
                    skipped.insert(agent.paneID)
                    continue
                }
                if let text = try? await withTimeout(.seconds(3), { try await client.readPane(agent.paneID, session: session).text }) {
                    visible[agent.paneID] = text
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.waitProbe = nil
            guard generation == self.generation, session == self.activeSession else { return }
            let consoleBaseline = self.consoleBaselinePending
            self.consoleBaselinePending = false
            var reads: [String: (id: String, screen: ConsoleScreen, since: Date)] = [:]
            for agent in probes {
                let pane = agent.paneID
                if skipped.contains(pane) { continue }
                guard let text = visible[pane] else {
                    // A failed read isn't evidence that a known prompt closed.
                    if let wait = self.waits[pane], wait.ref == agent.agentSession { found[pane] = wait }
                    continue
                }
                let latest = self.latest(agent)
                // A trust prompt only as the folder the agent runs in; one that doesn't match is
                // left to the terminal.
                if let latest, latest.agentStatus != .working,
                   let prompt = ScreenPrompt.parse(text)?.trustResolved(cwd: latest.workingDirectory ?? self.snapshot?.panes.first { $0.id == pane }?.workingDirectory),
                   prompt.phase == .question || prompt.phase == .review {
                    // Cursor/check changes don't create new debts; a new screen context does.
                    let id: String
                    if let previous = self.waits[pane], previous.ref == agent.agentSession,
                       previous.prompt?.representsSameWait(as: prompt) == true {
                        id = previous.id
                    } else {
                        id = "prompt:\(agent.agentSession?.value ?? pane):\(UUID().uuidString)"
                    }
                    found[pane] = Wait(id: id, ref: agent.agentSession, console: nil, prompt: prompt)
                    // Herdr's blocked transition already owns its sequence-based alert.
                    if baseline || latest.agentStatus == .blocked { self.silentWaits.insert(id) }
                    continue
                }
                guard let call = candidates[pane], let screen = ConsoleScreen.parse(text) else { continue }
                let id = call.toolCallId
                if consoleBaseline { self.baselineConsoles[id] = screen }
                let last = self.consoleReads[pane]
                let since = last.flatMap { $0.id == id && $0.screen == screen ? $0.since : nil } ?? .now
                reads[pane] = (id, screen, since)
                if screen.asksForInput || Date.now.timeIntervalSince(since) >= 10 {
                    if self.baselineConsoles[id] == screen { self.silentWaits.insert(id) }
                    found[pane] = Wait(id: id, ref: agent.agentSession, console: screen)
                }
            }
            self.consoleReads = reads
            self.settleWaits(found, checked: checked)
        }
    }

    private func settleWaits(_ found: [String: Wait], checked: [String: Int]) {
        let changed = found != waits || checked.contains { waitChecked[$0.key] != $0.value }
        for pane in waits.keys where found[pane] == nil { resumedAt[pane] = .now }
        waits = found
        waitChecked = checked
        guard changed else { return }
        if let snapshot { reconcileHidden(snapshot) }
        onAttentionChange?(self)
    }

    // MARK: Settled turns

    /// Pane → the Claude turn-settle check (`TurnSettle`) for the agent and change it ran at; a
    /// nil settle is a failed read, which alerts as before.
    private var settles: [String: (seq: Int, ref: AgentSessionRef?, settle: TurnSettle?)] = [:]
    private var settleProbe: Task<Void, Never>?
    private var settleRelease: Task<Void, Never>?

    enum FinishGate: Equatable { case open, checking, held }

    /// Whether a finished Claude turn may alert yet: `checking` until its transcript has been
    /// read at this change, `held` while it is a background task's wake turn with others still
    /// running (until `TurnSettle.backstop`). Anything else, and any agent but Claude, is open.
    /// The away watcher runs the same scan, so a turn it held doesn't alert on return either.
    func finishGate(_ agent: Agent, now: Date = .now) -> FinishGate {
        guard agent.agent == "claude", agent.agentStatus == .idle || agent.agentStatus == .done else { return .open }
        guard let entry = settles[agent.paneID], entry.ref == agent.agentSession,
              entry.seq == agent.stateChangeSeq ?? 0 else {
            return client != nil && claudeTranscript(agent) != nil ? .checking : .open
        }
        return entry.settle?.holds(now: now) == true ? .held : .open
    }

    /// The latest check of a finished Claude turn, at its current change; nil while unknown.
    func turnSettle(_ agent: Agent) -> TurnSettle? {
        guard let entry = settles[agent.paneID], entry.ref == agent.agentSession,
              entry.seq == agent.stateChangeSeq ?? 0 else { return nil }
        return entry.settle
    }

    /// For the away watcher as the app leaves: unread finishes still held, with the seconds
    /// left before their backstop, and each Claude pane's transcript as found here.
    func watcherHandoff(now: Date = .now) -> (held: [PushWatch.Config.Held], transcripts: [String: String]) {
        let agents = snapshot?.agents ?? []
        let alerted = AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.alertedKey) as? [String: Int] ?? [:]
        let held = agents.compactMap { agent -> PushWatch.Config.Held? in
            let seq = agent.stateChangeSeq ?? 0
            let reference = agent.agentSession?.value
            let address = address(paneID: agent.paneID)
            let key = AttentionSnapshot.key(host: address.hostID, session: address.session, pane: address.paneID)
            // Unread and not already alerted (a relaunch rechecks a finish it alerted before).
            let alert = isUnread(agent) && (alerted[key] ?? -1) < seq
            switch finishGate(agent, now: now) {
            // Open but not yet alerted here (a backstop passing as the app leaves): the watcher
            // checks it at once and delivers it.
            case .open:
                guard agent.agent == "claude", agent.agentStatus == .idle || agent.agentStatus == .done, alert else { return nil }
                // Only a recent one: an old unread finish isn't news to deliver now.
                if let age = turnSettle(agent)?.age(now: now), age > 2 * TurnSettle.backstop { return nil }
                return .init(pane: agent.paneID, seq: seq, deadline: nil, reference: reference, alert: true)
            // Still being checked: the watcher checks it as it starts.
            case .checking: return .init(pane: agent.paneID, seq: seq, deadline: nil, reference: reference, alert: alert)
            case .held:
                guard let ended = turnSettle(agent)?.endedAt else { return nil }
                // On the host's clock. Read here, its Live Activity still ends then; only the alert is skipped.
                return .init(pane: agent.paneID, seq: seq, deadline: Int(ended.timeIntervalSince1970 + TurnSettle.backstop),
                             reference: reference, alert: alert)
            }
        }
        var transcripts: [String: String] = [:]
        for agent in agents { if let path = claudeTranscript(agent) { transcripts[agent.paneID] = path } }
        return (held, transcripts)
    }

    private func claudeTranscript(_ agent: Agent) -> String? {
        guard let entry = activity[agent.paneID], entry.ref == agent.agentSession,
              let transcript = entry.transcript, transcript.format == .claude else { return nil }
        return transcript.path
    }

    /// Checks Claude agents that stopped at a change not yet checked. A turn the file doesn't
    /// show ending yet gets one more look two seconds on, then counts as it stands.
    private func updateSettles(_ agents: [Agent]) {
        // Holds known from before a reconnect still need their release timer.
        if settleRelease == nil { scheduleSettleRelease() }
        guard settleProbe == nil, let client else { return }
        let due = agents.compactMap { agent -> (Agent, String)? in
            guard agent.agent == "claude", agent.agentStatus == .idle || agent.agentStatus == .done,
                  let path = claudeTranscript(agent) else { return nil }
            if let entry = settles[agent.paneID], entry.ref == agent.agentSession, entry.seq == agent.stateChangeSeq ?? 0 { return nil }
            return (agent, path)
        }
        guard !due.isEmpty else { return }
        let generation = generation
        settleProbe = Task { [weak self] in
            for (agent, path) in due {
                var settle: TurnSettle? = (try? await withTimeout(.seconds(5)) { try await client.turnSettle(path: path) }) ?? nil
                // The finish seen was the person's turn: a later look can't make it a wake.
                if settle?.ended == false, settle?.origin != .human {
                    try? await Task.sleep(for: .seconds(2))
                    settle = (try? await withTimeout(.seconds(5)) { try await client.turnSettle(path: path) }) ?? nil
                }
                // Each as it comes, so one slow host read doesn't hold another pane's alert.
                guard let self, generation == self.generation else { return }
                self.settles[agent.paneID] = (agent.stateChangeSeq ?? 0, agent.agentSession, settle)
                self.scheduleSettleRelease()
                self.onAttentionChange?(self)
            }
            guard let self else { return }
            self.settleProbe = nil
            // Agents that stopped while this ran are checked now.
            if generation == self.generation, let agents = self.snapshot?.agents { self.updateSettles(agents) }
        }
    }

    /// A held finish alerts at its backstop if nothing has moved by then.
    private func scheduleSettleRelease() {
        settleRelease?.cancel()
        let next = settles.values.compactMap { $0.settle?.holds() == true ? $0.settle?.releaseAt() : nil }.min()
        guard let next else { return }
        settleRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled, let self else { return }
            self.scheduleSettleRelease()
            self.onAttentionChange?(self)
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

    /// A finished agent's closing warning ("Before deploying: apply 0042 first"), for the rows
    /// that show its verdict; message text, so only when `previews` allows it.
    func caution(_ agent: Agent, status: AgentStatus, previews: Bool) -> String? {
        guard previews, status == .done || status == .idle,
              let entry = activity[agent.paneID], entry.ref == agent.agentSession else { return nil }
        return entry.transcript?.caution
    }

    /// What `agent` is running now in its Now line's words ("Running swift test"); nil while
    /// no call is open or unknown.
    func step(_ agent: Agent) -> String? {
        guard let entry = activity[agent.paneID], entry.ref == agent.agentSession else { return nil }
        return entry.transcript?.step
    }

    /// A row's line under its title: for a working agent what it's running now, whatever the
    /// previews setting (status, not message text; round 15: Working rows showed narration from
    /// minutes before), else the newest message when `previews` allows it. A working agent with
    /// no open call has none (round 25: its last message stood where current work goes); one
    /// gone still says its step is the last reported (round 25: "Running uv run pipeline
    /// backfill" beside "no update 7m" read as fresh progress).
    func rowLine(_ agent: Agent, status: AgentStatus, previews: Bool, now: Date = .now) -> String? {
        guard status == .working else { return previews ? preview(agent) : nil }
        guard let step = step(agent) else { return nil }
        guard let since = stillSince(agent), AgentRow.quiet(since: since, at: now) != nil else { return step }
        return "Last reported: \(step)"
    }

    /// When `agent` last wrote anything, work inside a turn included; nil while unknown.
    func activityAt(_ agent: Agent) -> Date? {
        guard let entry = activity[agent.paneID], entry.ref == agent.agentSession else { return nil }
        return entry.transcript?.activityAt
    }

    /// What a working agent's "no update 6m" counts from: its newest transcript record, or when
    /// it was last seen going back to work, if later (round 24: an agent just approved read "no
    /// update 45m", counting from the record before it asked).
    func stillSince(_ agent: Agent) -> Date? {
        let resumed = resumedAt[agent.paneID]
        guard let active = activityAt(agent) else { return resumed }
        return resumed.map { max($0, active) } ?? active
    }

    /// When `agent` was last seen going back to work, here: after an answer, the start of what
    /// it's doing now.
    func resumed(_ agent: Agent) -> Date? { resumedAt[agent.paneID] }

    /// When a working agent's current run began: the message that started its turn, or its
    /// going back to work after an answer, if later. Nil for any other status.
    func workingSince(_ agent: Agent, status: AgentStatus) -> Date? {
        guard status == .working, let started = lastTurnAt(agent) else { return nil }
        return resumed(agent).map { max($0, started) } ?? started
    }

    /// "no update 6m" for a working agent whose transcript has gone still, else nil
    /// (`AgentRow.quiet`).
    func quiet(_ agent: Agent, now: Date = .now) -> String? {
        guard presentedStatus(agent) == .working, let since = stillSince(agent) else { return nil }
        return AgentRow.quiet(since: since, at: now)
    }

    /// What a row's age counts from: for an agent waiting on the user, its newest record (the
    /// question it asked; round 15: its turn's start read as how long it had waited), else its
    /// last turn. None while it works: that turn may be a prompt or an earlier turn's end, and a
    /// bare "1m" there read as how long it had run (round 18). Its step line says it's live; the
    /// thread's subtitle how long its turn has run, where that's known.
    func ageDate(_ agent: Agent, status: AgentStatus) -> Date? {
        if status == .working { return nil }
        return status == .blocked ? activityAt(agent) ?? lastTurnAt(agent) : lastTurnAt(agent)
    }

    /// `ageDate` as VoiceOver says it: "asked 4 minutes ago" or "last turn 5 minutes ago"
    /// (round 15: VoiceOver in the dock and Overview read the turn's start while the row said
    /// how long it had waited). A working agent gone quiet says so, as its rows show it
    /// (round 21: the dock showed "quiet 6m" and said nothing), and one at work says for how
    /// long, as the rows show "for 12m" (round 45: sb#5, the dock showed it and said nothing).
    func spokenAge(_ agent: Agent, status: AgentStatus, now: Date = .now) -> String? {
        if status == .working {
            if let since = stillSince(agent), AgentRow.quiet(since: since, at: now) != nil {
                return AgentRow.spokenQuiet(since: since)
            }
            return workingSince(agent, status: status).flatMap { since in
                AgentRow.working(since: since, at: now).map { _ in AgentRow.spokenWorking(since: since) }
            }
        }
        return ageDate(agent, status: status).map { status == .blocked ? AgentRow.spokenWaiting(since: $0) : AgentRow.spokenAge(of: $0) }
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
        let host = identity
        let inputs = conversations.warmInputs(host: host, agents: agents,
                                              lastTurn: current.compactMapValues { $0.transcript?.lastTurnAt })
        activityRead = Task { [weak self] in
            let (updated, warm, heard) = await Self.readActivity(current, agents: agents, client: client, session: session, warm: inputs.mapValues(\.state))
            guard let self else { return }
            self.activityRead = nil
            if generation == self.generation, session == self.activeSession, updated != self.activity {
                self.activity = updated
                UserDefaults.standard.set(try? JSONEncoder().encode(updated), forKey: self.activityKey)
            }
            if generation == self.generation, session == self.activeSession {
                if heard { self.heardAt = .now }
                self.conversations.publish(warm, revisions: inputs.mapValues(\.revision), host: host, agents: agents)
                self.updateWaits(agents)
                self.updateSettles(agents)
            }
            if self.activityPending {
                self.activityPending = false
                self.refreshActivity()
            }
        }
    }

    /// A failed read keeps what was known; the snapshot is authoritative for which panes remain.
    /// `heard`: the host answered at least one read.
    nonisolated private static func readActivity(_ current: [String: PaneActivity], agents: [Agent],
                                                 client: HerdrClient, session: String,
                                                 warm: [String: WarmConversation?]) async -> ([String: PaneActivity], [String: WarmConversation?], Bool) {
        var next: [String: PaneActivity] = [:]
        var warmed = warm
        var heard = false
        var missing: [(String, AgentSessionRef)] = []
        for agent in agents {
            guard let ref = agent.agentSession, TranscriptFormat(agent: ref.agent) != nil else { continue }
            let entry = current[agent.paneID].flatMap { $0.ref == ref ? $0 : nil } ?? PaneActivity(ref: ref)
            next[agent.paneID] = entry
            if case .some(.none) = warm[agent.paneID], let transcript = entry.transcript {
                next[agent.paneID]?.transcript = TranscriptActivity(path: transcript.path, format: transcript.format)
            }
            if entry.transcript == nil { missing.append((agent.paneID, ref)) }
        }
        if !missing.isEmpty, !Task.isCancelled,
           let located = try? await client.locateTranscripts(missing.map { (pane: $0.0, ref: $0.1) }, session: session) {
            heard = true
            for (pane, ref) in missing {
                if let location = located[pane], next[pane]?.ref == ref {
                    next[pane]?.transcript = TranscriptActivity(path: location.path, format: location.format)
                }
            }
        }
        var panes = Set(next.keys)
        for _ in 0..<12 {
            let reads = next.filter { panes.contains($0.key) }.compactMapValues { entry in entry.transcript.map { ($0.path, $0.nextRead) } }
            guard !Task.isCancelled, !reads.isEmpty, let chunks = try? await client.readChunks(reads) else { break }
            heard = true
            for (pane, chunk) in chunks {
                if let transcript = next[pane]?.transcript, !transcript.isLookingBack, warmed.keys.contains(pane) {
                    let initial = transcript.offset == nil
                    var data = warmed[pane] ?? nil
                    if initial { data = WarmConversation(location: TranscriptLocation(path: transcript.path, format: transcript.format)) }
                    if var data, data.absorb(chunk, initial: initial) { warmed[pane] = .some(data) }
                    else { warmed[pane] = .some(nil) }
                }
                next[pane]?.transcript?.absorb(size: chunk.size, from: chunk.from, bytes: chunk.bytes)
            }
            panes = panes.filter { next[$0]?.transcript?.needsMore == true }
            if panes.isEmpty { break }
        }
        return (next, warmed, heard)
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

    func handle(_ input: ConnectionSupervisor.Input, notifyAttention: Bool = true) {
        // A host turned off is never dialled, retried or woken by a network change; its link
        // only stands in for it on screen.
        guard profile.isEnabled else { return }
        let wasLive = isLive
        let effects = supervisor.handle(input)
        phase = supervisor.phase
        if isLive { lostAt = nil } else if wasLive { lostAt = heardAt ?? .now }
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
        if notifyAttention, wasLive != isLive { onAttentionChange?(self) }
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

    /// Starts herdr's server on the host (the configured session, else the default) over its
    /// own SSH connection, then reconnects. Only from the user's tap on a stopped-herdr failure.
    /// Returns why it didn't start.
    func startHerdr() async -> String? {
        do {
            let (ssh, _) = try await dial(profile)
            do {
                try await HerdrClient(runner: ssh, herdrPath: Self.cachedHerdrPath(profile)).startServer(session: profile.session)
                await ssh.close()
            } catch {
                await ssh.close()
                throw error
            }
        } catch {
            return failure(for: error).message
        }
        handle(.userRetry)
        return nil
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
        /// Claude stopped at its first-run check in a folder it hasn't opened: the person decides.
        case needsTrust(ScreenPrompt, PaneAddress, name: String)
    }

    /// `freshPane`: the caller just created `paneID`, so its shell can't hold user work but may
    /// still be running startup files.
    func startAgent(kind: String, arguments: [String] = [], paneID: String, inNewTab: Bool = false, freshPane: Bool = false) async throws -> StartOutcome {
        guard let client, let session = activeSession, isLive else { throw HerdrError.noResponse }
        lastAgentKind = kind
        var target = paneID
        var folder = snapshot?.panes.first(where: { $0.id == paneID })?.workingDirectory
        if inNewTab {
            guard let pane = snapshot?.panes.first(where: { $0.id == paneID }) else { throw HerdrError.noResponse }
            target = try await client.createTab(workspaceID: pane.workspaceID, label: nil, cwd: pane.workingDirectory, session: session).rootPane.id
            folder = pane.workingDirectory
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
            } catch HerdrError.api(code: "agent_not_ready", let message) {
                // herdr: "blocked during startup". Claude's folder check is the usual reason.
                if let prompt = try? await ScreenPrompt.parse(client.readPane(target, session: session).text),
                   prompt.title == "Trust this folder?" {
                    // Granted only for the folder the pane is in, checked against what the screen says.
                    await awaitPane(target)
                    let cwd = snapshot?.panes.first { $0.id == target }?.workingDirectory ?? folder
                    guard let resolved = prompt.trustResolved(cwd: cwd) else { throw TrustUnverified() }
                    return .needsTrust(resolved, PaneAddress(hostID: profile.id, session: session, paneID: target), name: name)
                }
                throw HerdrError.api(code: "agent_not_ready", message: message)
            }
        }
        return .started(try await awaitStarted(agent, kind: kind, paneID: target), PaneAddress(hostID: profile.id, session: session, paneID: target))
    }

    /// Answers Claude's folder check with `label` (the person's choice, verified on screen),
    /// then waits for the agent as a start does.
    func answerTrust(_ label: String, on prompt: ScreenPrompt, at address: PaneAddress, name: String, kind: String) async throws -> Agent? {
        guard let client, activeSession == address.session else { throw HerdrError.noResponse }
        let io = HerdrPromptIO(client: client, pane: address.paneID, session: address.session) { _, _ in false }
        try await PromptDriver.choose(label, on: prompt, io: io)
        guard label != "No, exit" else { return nil }
        var found: Agent?
        for _ in 0..<60 {
            // herdr keeps the start's name through the check (live trace); only that agent will do.
            if let live = snapshot?.agents.first(where: { $0.paneID == address.paneID && $0.name == name }) { found = live; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        // Not in the mirror yet: ask herdr itself; failing that, say so rather than look declined.
        if found == nil, let direct = try? await client.agent(paneID: address.paneID, session: address.session).agent, direct.name == name {
            found = direct
        }
        guard let found else { throw TrustPending() }
        return try await awaitStarted(found, kind: kind, paneID: address.paneID)
    }

    struct TrustUnverified: LocalizedError {
        var errorDescription: String? { "Claude is asking to trust a folder this app couldn't match to the pane's. Answer it in the terminal, where the whole path shows." }
    }

    struct TrustPending: LocalizedError {
        var errorDescription: String? { "The folder is trusted and Claude is still starting. Open it from the inbox when it appears; your first message is still in this sheet." }
    }

    private func awaitStarted(_ started: Agent, kind: String, paneID target: String) async throws -> Agent {
        var agent = started
        // agent.start answers before the agent runs; its integration reports the transcript a
        // moment later. Wait for that (bounded), so the start opens the conversation rather than
        // the terminal, and the mirror has the agent, so it doesn't open on "Agent exited".
        // Agents whose integration is known missing never report one: take them as soon as seen.
        let reportsTranscript = TranscriptFormat(agent: kind) != nil
            && !missingIntegrations.contains { $0.target == kind }
        for _ in 0..<20 {
            if let live = snapshot?.agents.first(where: { $0.paneID == target && $0.name == agent.name }) {
                if live.hasTranscript || !agent.hasTranscript { agent = live }
                if agent.hasTranscript || !reportsTranscript { break }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return agent
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

    /// The most an attempt may take to its first live snapshot. Each step has its own bound, but
    /// together they ran to minutes (a host command gets ten), all of it showing "Reconnecting…".
    private static let connectBudget: Duration = .seconds(45)
    /// The most one round trip on a link that claims to be live may take (a route check, a
    /// refresh) before the link is taken as dead.
    private static let checkBound: Duration = .seconds(10)

    private func connect() {
        resuming = snapshot != nil
        teardown()
        let generation = generation
        let profile = profile
        let demo = demo
        let trace = ConnectTrace(phase: phase, resuming: resuming)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.connectBudget)
            guard let self, !Task.isCancelled, generation == self.generation, case .connecting = self.phase else { return }
            trace.fail("no live snapshot in time", kind: "deadline")
            // Retried like any failed attempt; the teardown this brings cancels the attempt.
            self.handle(.connectFailed(self.failure(for: TimeoutError())))
        }
        attempt = Task { [weak self] in
            guard let self else { return }
            var wentLive = false
            do {
                let runner: any CommandRunner
                if let demo {
                    runner = demo
                } else {
                    let (ssh, viaTailnet) = try await self.dial(profile, trace: trace)
                    trace.mark("ssh")
                    guard generation == self.generation else {
                        await ssh.close()
                        return
                    }
                    self.ssh = ssh
                    // Checked or replaced on a route change by the route this link took.
                    self.supervisor.migratesAcrossRoutes = viaTailnet
                    runner = ssh
                }
                let client = HerdrClient(runner: runner, herdrPath: demo == nil ? Self.cachedHerdrPath(profile) : nil)
                let herdrPath = try await client.resolveHerdrPath()
                if demo == nil { Self.cache(herdrPath: herdrPath, for: profile) }
                trace.mark("herdr")
                guard generation == self.generation else { return }
                // Subscribe to the likely session while listing sessions; the list decides
                // whether that mirror is kept. Dropping an unused stream closes its bridge.
                let guess = profile.session ?? self.activeSession ?? Self.lastSession(profile)
                var speculative = guess.map { client.mirror(session: $0, panes: self.knownPanes(in: $0)) }
                let sessions = try await client.sessions()
                guard generation == self.generation else { return }
                self.sessions = sessions
                trace.mark("sessions")
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
                self.loadSeenWaits()
                self.loadActivity()
                self.onSessions?(self)

                let snapshots = (session == guess ? speculative : nil) ?? client.mirror(session: session, panes: self.knownPanes(in: session))
                speculative = nil
                var previewed = false
                for try await update in snapshots {
                    guard generation == self.generation else { return }
                    let firstLive: Bool
                    if case .live = update { firstLive = !wentLive } else {
                        firstLive = false
                        if !previewed { previewed = true; trace.mark("preview") }
                    }
                    if firstLive {
                        wentLive = true
                        self.deadline?.cancel()
                        trace.mark("live")
                        self.client = client
                        self.liveID += 1
                        self.handle(.connected, notifyAttention: false)
                    }
                    self.apply(update.snapshot, authoritative: { if case .live = update { true } else { false } }())
                    if firstLive {
                        self.onLive?(self)
                        self.startActivityTimer()
                        // `apply` has already started the activity read. Integrations and the
                        // clock are only warnings: they wait until the first screen has settled.
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            guard let self, generation == self.generation else { return }
                            if demo == nil { await self.sampleClock(runner) }
                            await self.checkIntegrations()
                        }
                    }
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                trace.fail("Connection closed", kind: wentLive ? "dropped: stream ended" : "stream ended")
                self.handle(wentLive ? .dropped(ConnectionFailure("Connection closed", retryable: true)) : .connectFailed(ConnectionFailure("Connection closed", retryable: true)))
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // 127: the shell found no binary at the cached path; the retry resolves it anew.
                if demo == nil, case CommandError.exited(127, _) = error { Self.forgetHerdrPath(profile) }
                let failure = self.failure(for: error)
                trace.fail(failure.message, kind: (wentLive ? "dropped: " : "") + ConnectTrace.kind(of: error))
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
                let snapshot = try await withTimeout(Self.checkBound) { try await client.snapshot(session: session) }
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.apply(snapshot, authoritative: true)
                self.handle(.connected)
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                ConnectTrace.note("route check failed (\(ConnectTrace.kind(of: error)))")
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
            SnapshotStore.save(.init(hostID: profile.id, session: session, sessions: sessions, snapshot: snapshot))
        }
        self.snapshot = snapshot
        heardAt = .now
        recordBaseline(snapshot)
        reconcileHidden(snapshot)
        // A close holds its pane out until a snapshot no longer has it.
        closing.formIntersection(snapshot.panes.map(\.id))
        onAttentionChange?(self)
        // A status change usually comes with a message; look now rather than at the next tick.
        refreshActivity()
    }

    private func teardown() {
        generation += 1
        attempt?.cancel()
        attempt = nil
        deadline?.cancel()
        deadline = nil
        verification?.cancel()
        verification = nil
        activityTimer?.cancel()
        activityTimer = nil
        activityRead?.cancel()
        waitProbe?.cancel()
        waitProbe = nil
        // A settle read cut off by the drop must not keep later finishes waiting on its slot.
        settleProbe?.cancel()
        settleProbe = nil
        settleRelease?.cancel()
        settleRelease = nil
        // The next live link's first check is a baseline again; see `silentWaits`.
        waitBaselinePending = true
        consoleBaselinePending = true
        baselineConsoles = [:]
        client = nil
        if let ssh {
            self.ssh = nil
            Task { await ssh.close() }
        }
    }

    /// Off Wi-Fi and wired networks a LAN address can't answer, so it isn't dialled. Set by
    /// `AppModel` from the network path.
    static var onLocalNetwork = true

    /// The SSH link, and whether it rides the in-app tailnet. With a LAN address and a pinned
    /// host key, the LAN address is dialled alongside the route and the first to finish SSH
    /// sign-in wins: away from that network the route connects as fast as it would alone.
    private func dial(_ profile: HostProfile, trace: ConnectTrace? = nil) async throws -> (ssh: SSHConnection, tailnet: Bool) {
        let authentication: SSHAuthentication = switch profile.auth {
        case .deviceKey: .ed25519(try DeviceKey.load(hostID: profile.id))
        case .password: .password(Keychain.string(for: profile.passwordAccount) ?? "")
        case .tailscaleSSH: .none
        }
        // Only against a key already pinned: a LAN address on someone else's network may
        // belong to another machine, which must neither be trusted nor fail the host.
        guard let lan = profile.lanRoute, Self.onLocalNetwork, let pinned = Keychain.string(for: profile.hostKeyAccount) else {
            return (try await dialRoute(profile, authentication: authentication, trace: trace), profile.isTailnet)
        }
        let username = profile.username
        let candidates: [@Sendable () async throws -> SSHConnection] = [
            { try await self.dialRoute(profile, authentication: authentication, trace: trace) },
            {
                try await SSHConnection.connect(
                    host: lan.host, port: lan.port, username: username, authentication: authentication,
                    hostKeyValidator: { Self.keyIdentity($0.publicKey) == Self.keyIdentity(pinned) },
                    timeout: .seconds(3)
                )
            },
        ]
        let won = try await firstSuccess(candidates) { await $0.close() }
        trace?.mark(won.index == 0 ? "route won" : "lan won")
        return (won.value, won.index == 0 && profile.isTailnet)
    }

    private func dialRoute(_ profile: HostProfile, authentication: SSHAuthentication, trace: ConnectTrace?) async throws -> SSHConnection {
        switch profile.route {
        case .direct(let host, let port):
            return try await SSHConnection.connect(
                host: host, port: port, username: profile.username,
                authentication: authentication, hostKeyValidator: validator(for: profile, tailnetKeys: [])
            )
        case .tailnet(let nodeID, _, let address):
            let (fd, peer) = try await tailnet.connect(to: nodeID, address: address, port: 22)
            trace?.mark("tailnet socket")
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
            return ConnectionFailure("The herdr session “\(name)” isn't running on \(profile.address).", retryable: false, herdrStopped: true)
        case SessionError.none:
            return ConnectionFailure("herdr isn't running on \(profile.address).", retryable: false, herdrStopped: true)
        case TailnetError.signedOut:
            return ConnectionFailure("This iPhone is signed out of Tailscale.", retryable: false)
        case SSHError.connectionRefused, TailnetError.refused:
            // Retrying can't help until something listens there, so say what to turn on.
            let hint = switch profile.auth {
            case .tailscaleSSH: "Turn on Tailscale SSH there (sudo tailscale set --ssh)"
            case .deviceKey, .password: "Turn on its SSH server (Linux: sudo systemctl enable --now sshd; macOS: Remote Login)"
            }
            return ConnectionFailure("\(profile.address) refused the connection: nothing is accepting SSH there. \(hint), then tap Retry.", retryable: false)
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

    /// The resolved herdr binary. "herdr-path" held whatever `command -v` said, often a
    /// version manager's shim; it's dropped so those hosts resolve the real binary once.
    private static func cachedHerdrPath(_ profile: HostProfile) -> String? {
        UserDefaults.standard.removeObject(forKey: "herdr-path.\(profile.id.uuidString)")
        return UserDefaults.standard.string(forKey: "herdr-exec.\(profile.id.uuidString)")
    }

    private static func cache(herdrPath: String, for profile: HostProfile) {
        UserDefaults.standard.set(herdrPath, forKey: "herdr-exec.\(profile.id.uuidString)")
    }

    /// A resolved binary disappears when its version manager upgrades or prunes it.
    private static func forgetHerdrPath(_ profile: HostProfile) {
        UserDefaults.standard.removeObject(forKey: "herdr-exec.\(profile.id.uuidString)")
    }

    /// The session last opened on this host; only a guess to subscribe early, never a choice.
    private static func lastSession(_ profile: HostProfile) -> String? {
        UserDefaults.standard.string(forKey: "last-session.\(profile.id.uuidString)")
    }

    private static func remember(session: String, for profile: HostProfile) {
        UserDefaults.standard.set(session, forKey: "last-session.\(profile.id.uuidString)")
    }
}

/// Stage times of one connect attempt, logged for Console.app (subsystem dev.btuckerc.herdwick,
/// category connect) so a device's slow connect can be read off by stage.
struct ConnectTrace: Sendable {
    private static let log = Logger(subsystem: "dev.btuckerc.herdwick", category: "connect")
    private let id = String(UInt16.random(in: 0...UInt16.max), radix: 16)
    private let start = ContinuousClock.now

    init(phase: ConnectionSupervisor.Phase, resuming: Bool) {
        let attempt = if case .connecting(let n) = phase { n } else { 0 }
        let tag = self.id
        Self.log.notice("\(tag, privacy: .public) start attempt=\(attempt) resuming=\(resuming)")
    }

    func mark(_ stage: String) {
        Self.log.notice("\(id, privacy: .public) \(stage, privacy: .public) +\(elapsed) ms")
    }

    /// An app-wide event on the same timeline (foreground, tailnet recovery).
    static func note(_ event: String) {
        log.notice("\(event, privacy: .public)")
    }

    /// The message may name the host, so it stays private; `kind` says what failed in the clear.
    func fail(_ message: String, kind: String) {
        Self.log.notice("\(id, privacy: .public) failed +\(elapsed) ms (\(kind, privacy: .public)): \(message, privacy: .private)")
    }

    /// What failed, without anything that names the host.
    static func kind(of error: any Error) -> String {
        switch error {
        case let error as TailnetError:
            switch error {
            case .notRunning: "tailnet not running"
            case .signedOut: "tailnet signed out"
            case .refused: "tailnet refused"
            case .dialFailed: "tailnet dial"
            }
        case is TimeoutError: "timeout"
        case SSHError.connectionRefused: "refused"
        case is SSHError: "ssh"
        case is CommandError: "command"
        case is HerdrError: "herdr"
        case is HostConnection.SessionError: "session"
        default: String(describing: type(of: error))
        }
    }

    private var elapsed: Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
