import HerdrAPI
import UserNotifications
import WidgetKit

/// Turns agents that need you or have finished into alerts, the app badge and the widgets'
/// snapshot. Here it sees what the app sees while it is open or refreshing in the background;
/// away from the app, push alerts (`Push`) and the notification service take over.
@MainActor
final class Attention: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private let settings: Settings
    /// Every current link, across hosts and sessions.
    private let links: () -> [HostConnection]
    /// Every saved host, linked now or not.
    private let profiles: () -> [HostProfile]
    /// A watcher owns alerts while starting, running, or stopping.
    private let pushOwns: (SessionAddress) -> Bool
    /// The conversation on screen, whose own alerts would be noise.
    private let onScreen: () -> Set<PaneAddress>
    private let open: (PaneAddress, String?) -> Void
    private let decisionLog: DecisionLog
    /// Wakes the session's link for a notification action and holds it until `body` returns.
    private let connectionForAction: @MainActor (PaneAddress, (HostConnection?) async -> Void) async -> Void
    private let inlineAnswers = InlineAnswers()
    private let center = UNUserNotificationCenter.current()
    /// Pane key → the `state_change_seq` last alerted, so a reconnect, a background refresh or
    /// a push the notification service already showed never repeats an alert. A pane seen for
    /// the first time starts here, silently. Read fresh: the service writes it too.
    private var alerted: [String: Int] {
        get { AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.alertedKey) as? [String: Int] ?? [:] }
        set { AttentionSnapshot.shared?.set(newValue, forKey: AttentionSnapshot.alertedKey) }
    }
    /// Pane key → the wait (see `HostConnection.Wait`) last alerted. A wait leaves the
    /// sequence where it was, so it is tracked by its own id, once per wait.
    private var alertedWaits: [String: String] {
        get { AttentionSnapshot.shared?.dictionary(forKey: "alertedWaits") as? [String: String] ?? [:] }
        set { AttentionSnapshot.shared?.set(newValue, forKey: "alertedWaits") }
    }
    private var badge = -1
    private var published: AttentionSnapshot?
    private var publication: Task<Void, Never>?
    /// Pane key → the change it is at and when the app saw that change happen.
    private var stamps: [String: Stamp] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(stamps), forKey: "attention.stamps") }
    }

    private struct Stamp: Codable, Equatable {
        let seq: Int
        /// Nil when the pane was already at `seq` when first seen: its start is unknown.
        let date: Date?
    }

    init(settings: Settings, links: @escaping () -> [HostConnection], profiles: @escaping () -> [HostProfile],
         decisionLog: DecisionLog, connectionForAction: @escaping @MainActor (PaneAddress, (HostConnection?) async -> Void) async -> Void,
         pushOwns: @escaping (SessionAddress) -> Bool,
         onScreen: @escaping () -> Set<PaneAddress>, open: @escaping (PaneAddress, String?) -> Void) {
        self.settings = settings
        self.links = links
        self.profiles = profiles
        self.decisionLog = decisionLog
        self.connectionForAction = connectionForAction
        self.pushOwns = pushOwns
        self.onScreen = onScreen
        self.open = open
        stamps = UserDefaults.standard.data(forKey: "attention.stamps")
            .flatMap { try? JSONDecoder().decode([String: Stamp].self, from: $0) } ?? [:]
        published = AttentionSnapshot.load()
        super.init()
        center.delegate = self
        registerCategories()
    }

    func registerCategories() {
        let replyInApp = UNTextInputNotificationAction(identifier: "reply-in-app", title: "Reply in App",
                                                       options: [.foreground, .authenticationRequired],
                                                       textInputButtonTitle: "Review in App", textInputPlaceholder: "Draft reply")
        var categories = [UNNotificationCategory(identifier: "finished-reply", actions: [replyInApp],
                                                   intentIdentifiers: [], options: [])]
        if settings.answerFromNotifications {
            // "Approve Once": it only ever picks a plain one-time option (`oneTimeApproval`),
            // so it says so, as the inbox and thread do beside a lasting grant (round 57: opus#2).
            let approve = UNNotificationAction(identifier: "answer-approve", title: "Approve Once",
                                               options: [.authenticationRequired])
            let deny = UNNotificationAction(identifier: "answer-deny", title: "Deny",
                                            options: [.destructive, .authenticationRequired])
            let ask = UNTextInputNotificationAction(identifier: "answer-ask", title: "Reply",
                                                    options: [.authenticationRequired],
                                                    textInputButtonTitle: "Send", textInputPlaceholder: "Answer")
            let finished = UNTextInputNotificationAction(identifier: "answer-finished", title: "Reply",
                                                         options: [.authenticationRequired],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Message")
            categories += [
                UNNotificationCategory(identifier: "needs-you-approval", actions: [approve, deny], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "needs-you-ask", actions: [ask], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "finished-answer", actions: [finished], intentIdentifiers: [], options: [])
            ]
        }
        center.setNotificationCategories(Set(categories))
    }

    /// Asks once; false when the user declined now or before.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Changes

    func changed(_ link: HostConnection) {
        guard let snapshot = link.snapshot else { refresh(); return }
        // A reset counter is conservatively ignored until it passes the known watermark.
        if link.isLive {
            var sequences = AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.sequencesKey) as? [String: Int] ?? [:]
            var references = AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.referencesKey) as? [String: String] ?? [:]
            let oldSequences = sequences
            let oldReferences = references
            for agent in snapshot.agents {
                let key = Self.key(link.address(paneID: agent.paneID))
                sequences[key] = max(sequences[key] ?? -1, agent.stateChangeSeq ?? 0)
                references[key] = agent.agentSession?.value
            }
            if sequences != oldSequences { AttentionSnapshot.shared?.set(sequences, forKey: AttentionSnapshot.sequencesKey) }
            if references != oldReferences { AttentionSnapshot.shared?.set(references, forKey: AttentionSnapshot.referencesKey) }
        }
        var settled: [String] = []
        var alerted = alerted
        var alertedWaits = alertedWaits
        defer {
            if alerted != self.alerted { self.alerted = alerted }
            if alertedWaits != self.alertedWaits { self.alertedWaits = alertedWaits }
        }
        for agent in snapshot.agents {
            let address = link.address(paneID: agent.paneID)
            let key = Self.key(address)
            let seq = agent.stateChangeSeq ?? 0
            if let wait = link.wait(agent) {
                if link.isUnread(agent) {
                    // While the push watcher owns this host it stays pending, as other alerts do.
                    if alertedWaits[key] != wait.id, !pushOwns(link.identity) {
                        alertedWaits[key] = wait.id
                        // The finish a Plan Review stopped at is this alert, not a second one.
                        alerted[key] = max(alerted[key] ?? seq, seq)
                        if !link.silentWaits.contains(wait.id) { post(agent, address: address, link: link) }
                        else { offerAnswers(agent, wait: wait, address: address, link: link) }
                    }
                } else {
                    settled.append(key)
                }
                continue
            }
            guard let last = alerted[key] else {
                alerted[key] = seq
                continue
            }
            if link.isUnread(agent) {
                guard seq > last, !pushOwns(link.identity) else { continue }
                // An omp finish may be a Plan Review its conversation hasn't been checked for yet.
                if agent.agent == "omp", agent.agentStatus != .blocked, !link.waitChecked(agent) { continue }
                alerted[key] = seq
                post(agent, address: address, link: link)
            } else {
                // Read here, or answered at the desk: its alert has done its job.
                settled.append(key)
            }
        }
        if !settled.isEmpty { center.removeDeliveredNotifications(withIdentifiers: settled) }
        refresh()
    }

    /// Preference and connection-set changes update surfaces without issuing alerts.
    func refresh() {
        refreshBadge()
        guard publication == nil else { return }
        publication = Task { [weak self] in
            guard let self else { return }
            self.publication = nil
            self.publish()
        }
    }

    /// Herdr's blocked transition alerts before the screen probe finds its prompt, so that alert
    /// has no actions, and the wait it then finds stays silent. While that alert is still in
    /// Notification Centre and the agent is at the same change, it is replaced quietly by one
    /// that can answer the wait.
    private func offerAnswers(_ agent: Agent, wait: HostConnection.Wait, address: PaneAddress, link: HostConnection) {
        guard settings.answerFromNotifications, link.presentedStatus(agent) == .blocked else { return }
        let id = Self.key(address)
        let seq = agent.stateChangeSeq ?? 0
        let waitID = wait.id
        center.getDeliveredNotifications { notes in
            let actionless = notes.contains { note in
                note.request.identifier == id && note.request.trigger == nil
                    && note.request.content.categoryIdentifier.isEmpty
                    && note.request.content.userInfo["stateChangeSeq"] as? Int == seq
            }
            guard actionless else { return }
            Task { @MainActor [weak self] in
                guard let agent = link.snapshot?.agents.first(where: { $0.paneID == address.paneID }),
                      agent.stateChangeSeq ?? 0 == seq, link.wait(agent)?.id == waitID else { return }
                self?.post(agent, address: address, link: link, quiet: true)
            }
        }
    }

    private func post(_ agent: Agent, address: PaneAddress, link: HostConnection, quiet: Bool = false) {
        guard !Mutes.shared.isMuted(address, reference: agent.agentSession?.value) else { return }
        let blocked = link.presentedStatus(agent) == .blocked
        guard blocked ? settings.notifyNeedsYou : settings.notifyFinished else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.conversationTitle
        content.subtitle = [link.profile.name, agent.workingDirectory.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " · ")
        let wait = link.wait(agent)
        content.body = blocked ? wait?.summary ?? "Needs you" : "Done"
        content.sound = blocked && !quiet ? .default : nil
        content.threadIdentifier = "\(address.hostID.uuidString)/\(address.session)"
        content.userInfo = [
            "host": address.hostID.uuidString, "session": address.session, "pane": address.paneID,
            "stateChangeSeq": agent.stateChangeSeq ?? 0, "agentName": agent.name
        ]
        if let ref = agent.agentSession {
            content.userInfo["reference"] = ref.value
            content.userInfo["referenceSource"] = ref.source
            content.userInfo["referenceAgent"] = ref.agent
            content.userInfo["referenceKind"] = ref.kind
            if let id = DraftStore.id(host: link.identity, agent: agent) { content.userInfo["draftID"] = id }
        }
        if blocked, settings.answerFromNotifications, let wait {
            content.userInfo["waitID"] = wait.id
            let thread = Thread(address: address, connection: link, agent: agent, workspace: nil, tab: nil)
            if let prompt = wait.prompt, prompt.style == .choice, PromptOptionKind.oneTimeApproval(in: prompt.options) != nil {
                content.categoryIdentifier = "needs-you-approval"
            } else if let inline = inlineAnswers.choices(for: thread), case .ask = inline.choices {
                content.categoryIdentifier = "needs-you-ask"
            }
        }
        if !blocked, let id = DraftStore.id(host: link.identity, agent: agent), agent.agentSession != nil {
            content.categoryIdentifier = settings.answerFromNotifications ? "finished-answer" : "finished-reply"
            content.userInfo["draftID"] = id
        }
        center.add(UNNotificationRequest(identifier: Self.key(address), content: content, trigger: nil))
    }

    /// The badge counts agents waiting on you, read or not; finished work is not a debt.
    private func refreshBadge() {
        let count = settings.notifyNeedsYou ? links().reduce(0) { total, link in
            total + (link.snapshot?.agents.count { link.presentedStatus($0) == .blocked } ?? 0)
        } : 0
        guard count != badge else { return }
        badge = count
        center.setBadgeCount(count)
    }

    // MARK: Widgets

    private func publish() {
        let all = links()
        let hosts = profiles()
        var stamps = stamps
        var present: Set<String> = []
        var items: [AttentionSnapshot.Item] = []
        // A link that answered speaks for its session: its agents replace the names kept for it.
        // Other sessions keep theirs until their link answers or their host is removed.
        let answered = all.filter(\.isLive).map { "\($0.identity.hostID.uuidString)/\($0.identity.session)/" }
        let saved = Set(hosts.map(\.id.uuidString))
        var names = (published?.names ?? [:]).filter { key, _ in
            saved.contains(String(key.prefix { $0 != "/" })) && !answered.contains { key.hasPrefix($0) }
        }
        for link in all {
            for agent in link.snapshot?.agents ?? [] {
                let address = link.address(paneID: agent.paneID)
                let key = Self.key(address)
                let place = [link.profile.name, agent.workingDirectory.map { ($0 as NSString).lastPathComponent }]
                    .compactMap { $0 }.joined(separator: " · ")
                names[key] = AttentionSnapshot.Name(title: agent.conversationTitle, place: place)
                guard link.hidden[agent.paneID] == nil else { continue }
                let seq = agent.stateChangeSeq ?? 0
                present.insert(key)
                if let stamp = stamps[key] {
                    if stamp.seq != seq { stamps[key] = Stamp(seq: seq, date: .now) }
                } else {
                    stamps[key] = Stamp(seq: seq, date: nil)
                }
                let state: AttentionSnapshot.Item.State
                switch link.presentedStatus(agent) {
                case .blocked: state = .blocked
                case .done: state = .done
                case .working: state = .working
                case .idle: state = .idle
                case .unknown: continue
                }
                items.append(AttentionSnapshot.Item(
                    id: key, title: agent.conversationTitle, place: place, state: state, since: stamps[key]?.date,
                    url: AttentionLink.url(host: address.hostID, session: address.session, pane: address.paneID),
                    draftID: agent.agentSession == nil ? nil : DraftStore.id(host: link.identity, agent: agent)
                ))
            }
        }
        let complete = !all.isEmpty && all.allSatisfy(\.isLive)
        // Forget panes only when every host answered; an offline host's panes may come back.
        if complete { stamps = stamps.filter { present.contains($0.key) } }
        if stamps != self.stamps { self.stamps = stamps }

        var snapshot = AttentionSnapshot(items: items, complete: complete, updated: .now, names: names,
                                         hosts: Dictionary(hosts.map { ($0.id.uuidString, $0.name) }) { first, _ in first })
        snapshot.sort()
        let contentChanged = published?.items != snapshot.items || published?.complete != snapshot.complete
            || published?.names != snapshot.names || published?.hosts != snapshot.hosts
        let sinceLast = snapshot.updated.timeIntervalSince(published?.updated ?? .distantPast)
        // Keep freshness current without rewriting identical aggregates on every event.
        guard contentChanged || sinceLast >= 60 else { return }
        snapshot.save()
        // A widget that went stale gets no further reload of its own, so a return to fresh is one.
        if contentChanged || sinceLast >= 30 * 60 {
            WidgetCenter.shared.reloadAllTimelines()
        }
        published = snapshot
    }

    // MARK: UNUserNotificationCenterDelegate
    // Main-actor completion-handler forms: UIKit must get the handler back on the main thread.
    // The async forms finish on a background executor, which crashed a launch from a tapped alert.

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let address = Self.address(notification.request.content.userInfo)
        let muted = address.map { address in
            let link = links().first { $0.identity.hostID == address.hostID && $0.identity.session == address.session }
            let reference = link?.snapshot?.agents.first { $0.paneID == address.paneID }?.agentSession?.value
            return Mutes.shared.isMuted(address, reference: reference)
        } ?? false
        completionHandler(muted || address.map { onScreen().contains($0) } == true ? [] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let identifier = response.actionIdentifier
        if identifier == "reply-in-app" {
            if let reply = response as? UNTextInputNotificationResponse,
               let id = info["draftID"] as? String, response.notification.request.trigger == nil {
                let old = DraftStore.load(id) ?? ""
                DraftStore.save(old.isEmpty ? reply.userText : old + "\n" + reply.userText, for: id)
            }
            if let address = Self.address(info) {
                open(address, response.notification.request.trigger == nil ? info["draftID"] as? String : nil)
            }
            completionHandler()
            return
        }
        // Only the app's own alerts (no trigger) carry an identity the app issued; a push, even
        // one naming an actionable category, only ever opens.
        let actionIDs: Set<String> = ["answer-approve", "answer-deny", "answer-ask", "answer-finished"]
        guard actionIDs.contains(identifier), settings.answerFromNotifications,
              response.notification.request.trigger == nil,
              let address = Self.address(info) else {
            if let address = Self.address(info) { open(address, nil) }
            completionHandler()
            return
        }
        let title = response.notification.request.content.title
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        // iOS allows an action about 30 s; at 20 s it stops, writes nothing more and says so.
        let deadline = ContinuousClock.now + .seconds(20)
        let once = Once()
        let work = Task { @MainActor in
            var failure: ActionFailure?
            await connectionForAction(address) { link in
                failure = await self.performNotificationAction(identifier, link: link, address: address, info: info,
                                                               reply: reply, deadline: deadline)
            }
            guard once.claim() else { return }
            if let failure { failAction(failure.message, reply: failure.keepsReply ? reply : nil, address: address, info: info, title: title) }
            completionHandler()
        }
        Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard once.claim() else { return }
            work.cancel()
            failAction("No answer from the host in time. Open to review.", reply: reply, address: address, info: info, title: title)
            completionHandler()
        }
    }

    /// Completes a notification action exactly once, whichever of the work and its deadline ends first.
    private final class Once {
        private var done = false
        func claim() -> Bool {
            defer { done = true }
            return !done
        }
    }

    private struct ActionFailure {
        let message: String
        /// A typed reply is kept as a draft; Approve and Deny have none.
        let keepsReply: Bool
    }

    /// Sends only while the agent is still waiting on the request the alert was issued for;
    /// otherwise returns what to tell the user.
    private func performNotificationAction(_ identifier: String, link: HostConnection?, address: PaneAddress,
                                           info: [AnyHashable: Any], reply: String?,
                                           deadline: ContinuousClock.Instant) async -> ActionFailure? {
        let changed = ActionFailure(message: "Couldn't send: the prompt changed. Open to review.", keepsReply: true)
        guard ContinuousClock.now < deadline, let link,
              let agent = link.snapshot?.agents.first(where: { $0.paneID == address.paneID }) else {
            return ActionFailure(message: "Couldn't send: not connected. Saved as a draft.", keepsReply: true)
        }
        let thread = Thread(address: address, connection: link, agent: agent, workspace: nil, tab: nil)
        switch identifier {
        case "answer-approve", "answer-deny":
            let approving = identifier == "answer-approve"
            guard link.presentedStatus(agent) == .blocked, let wait = link.wait(agent), waitMatches(wait, info: info),
                  let prompt = wait.prompt, prompt.style == .choice,
                  let option = approving ? PromptOptionKind.oneTimeApproval(in: prompt.options)
                    : prompt.options.first(where: { PromptOptionKind(label: $0.label) == .deny }) else {
                return ActionFailure(message: "Couldn't \(approving ? "approve" : "deny"): the prompt changed. Open to review.",
                                     keepsReply: false)
            }
            do {
                try await inlineAnswers.answerFromNotification(option.label, prompt: prompt, ask: nil, in: thread,
                                                               decisionLog: decisionLog, deadline: deadline)
            } catch {
                return ActionFailure(message: "Couldn't \(approving ? "approve" : "deny"): the prompt changed. Open to review.",
                                     keepsReply: false)
            }
        case "answer-ask":
            guard let reply, !reply.isEmpty, link.presentedStatus(agent) == .blocked,
                  let wait = link.wait(agent), waitMatches(wait, info: info),
                  let choices = inlineAnswers.choices(for: thread),
                  case .ask(let question) = choices.choices,
                  let ask = choices.ask, !question.options.isEmpty else { return changed }
            do {
                try await inlineAnswers.answerFromNotification(reply, prompt: nil, ask: ask, in: thread,
                                                               decisionLog: decisionLog, deadline: deadline)
            } catch {
                return changed
            }
        case "answer-finished":
            guard let reply, !reply.isEmpty,
                  let expected = info["stateChangeSeq"] as? Int,
                  agent.agentSession?.value == (info["reference"] as? String),
                  [.idle, .done].contains(link.presentedStatus(agent)),
                  (agent.stateChangeSeq ?? -1) >= expected else {
                return ActionFailure(message: "Couldn't send: the agent changed. Saved as a draft.", keepsReply: true)
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return changed }
            do {
                try await link.sendText(reply, pane: address.paneID, submit: true)
            } catch {
                return ActionFailure(message: "Couldn't send: not connected. Saved as a draft.", keepsReply: true)
            }
        default:
            return nil
        }
        center.removeDeliveredNotifications(withIdentifiers: [Self.key(address)])
        return nil
    }

    /// The exact wait the alert was issued for; an alert without one never answers.
    private func waitMatches(_ wait: HostConnection.Wait, info: [AnyHashable: Any]) -> Bool {
        guard let waitID = info["waitID"] as? String, !waitID.isEmpty else { return false }
        return wait.id == waitID
    }

    private func failAction(_ message: String, reply: String?, address: PaneAddress,
                            info: [AnyHashable: Any], title: String) {
        if let reply {
            let reference: AgentSessionRef? = if let value = info["reference"] as? String {
                AgentSessionRef(source: info["referenceSource"] as? String ?? "herdr",
                                agent: info["referenceAgent"] as? String ?? "unknown",
                                kind: info["referenceKind"] as? String ?? "id", value: value)
            } else { nil }
            let draftID = (info["draftID"] as? String)
                ?? DraftStore.id(host: SessionAddress(hostID: address.hostID, session: address.session),
                                 ref: reference, pane: address.paneID, name: info["agentName"] as? String)
            let old = DraftStore.load(draftID) ?? ""
            DraftStore.save(old.isEmpty ? reply : old + "\n" + reply, for: draftID)
        }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Herdwick" : title
        content.body = message
        let request = UNNotificationRequest(identifier: "action-failure-\(Self.key(address))-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        center.add(request)
    }

    nonisolated private static func address(_ info: [AnyHashable: Any]) -> PaneAddress? {
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
              let session = info["session"] as? String, let pane = info["pane"] as? String else { return nil }
        return PaneAddress(hostID: host, session: session, paneID: pane)
    }

    nonisolated private static func key(_ address: PaneAddress) -> String {
        AttentionSnapshot.key(host: address.hostID, session: address.session, pane: address.paneID)
    }
}
