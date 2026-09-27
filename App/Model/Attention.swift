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

    private let center = UNUserNotificationCenter.current()
    /// Pane key → the `state_change_seq` last alerted, so a reconnect, a background refresh or
    /// a push the notification service already showed never repeats an alert. A pane seen for
    /// the first time starts here, silently. Read fresh: the service writes it too.
    private var alerted: [String: Int] {
        get { AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.alertedKey) as? [String: Int] ?? [:] }
        set { AttentionSnapshot.shared?.set(newValue, forKey: AttentionSnapshot.alertedKey) }
    }
    private var badge = -1
    private var published: AttentionSnapshot?
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
         pushOwns: @escaping (SessionAddress) -> Bool,
         onScreen: @escaping () -> Set<PaneAddress>, open: @escaping (PaneAddress, String?) -> Void) {
        self.settings = settings
        self.links = links
        self.profiles = profiles
        self.pushOwns = pushOwns
        self.onScreen = onScreen
        self.open = open
        stamps = UserDefaults.standard.data(forKey: "attention.stamps")
            .flatMap { try? JSONDecoder().decode([String: Stamp].self, from: $0) } ?? [:]
        published = AttentionSnapshot.load()
        super.init()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "reply-in-app", title: "Reply in App",
                                                  options: [.foreground, .authenticationRequired],
                                                  textInputButtonTitle: "Review in App", textInputPlaceholder: "Draft reply")
        center.setNotificationCategories([UNNotificationCategory(identifier: "finished-reply", actions: [reply],
                                                                 intentIdentifiers: [], options: [])])
    }

    /// Asks once; false when the user declined now or before.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Changes

    func changed(_ link: HostConnection) {
        guard let snapshot = link.snapshot else { return }
        // A reset counter is conservatively ignored until it passes the known watermark.
        if link.isLive {
            var sequences = AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.sequencesKey) as? [String: Int] ?? [:]
            var references = AttentionSnapshot.shared?.dictionary(forKey: AttentionSnapshot.referencesKey) as? [String: String] ?? [:]
            for agent in snapshot.agents {
                let key = Self.key(link.address(paneID: agent.paneID))
                sequences[key] = max(sequences[key] ?? -1, agent.stateChangeSeq ?? 0)
                references[key] = agent.agentSession?.value
            }
            AttentionSnapshot.shared?.set(sequences, forKey: AttentionSnapshot.sequencesKey)
            AttentionSnapshot.shared?.set(references, forKey: AttentionSnapshot.referencesKey)
        }
        var settled: [String] = []
        var alerted = alerted
        defer { if alerted != self.alerted { self.alerted = alerted } }
        for agent in snapshot.agents {
            let address = link.address(paneID: agent.paneID)
            let key = Self.key(address)
            let seq = agent.stateChangeSeq ?? 0
            guard let last = alerted[key] else {
                alerted[key] = seq
                continue
            }
            if link.isUnread(agent) {
                guard seq > last, !pushOwns(link.identity) else { continue }
                alerted[key] = seq
                post(agent, address: address, link: link)
            } else {
                // Read here, or answered at the desk: its alert has done its job.
                settled.append(key)
            }
        }
        if !settled.isEmpty { center.removeDeliveredNotifications(withIdentifiers: settled) }
        refreshBadge()
        publish()
    }

    private func post(_ agent: Agent, address: PaneAddress, link: HostConnection) {
        guard !Mutes.shared.isMuted(address, reference: agent.agentSession?.value) else { return }
        let blocked = agent.agentStatus == .blocked
        guard blocked ? settings.notifyNeedsYou : settings.notifyFinished else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.conversationTitle
        content.subtitle = [link.profile.name, agent.cwd.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " · ")
        content.body = blocked ? "Needs you" : "Finished"
        content.sound = blocked ? .default : nil
        content.threadIdentifier = "\(address.hostID.uuidString)/\(address.session)"
        content.userInfo = ["host": address.hostID.uuidString, "session": address.session, "pane": address.paneID]
        if !blocked, let id = DraftStore.id(host: link.identity, agent: agent), agent.agentSession != nil {
            content.categoryIdentifier = "finished-reply"
            content.userInfo["draftID"] = id
            content.userInfo["reference"] = agent.agentSession?.value
        }
        center.add(UNNotificationRequest(identifier: Self.key(address), content: content, trigger: nil))
    }

    /// The badge counts agents waiting on you, read or not; finished work is not a debt.
    private func refreshBadge() {
        let count = settings.notifyNeedsYou ? links().reduce(0) { total, link in
            total + (link.snapshot?.agents.count { $0.agentStatus == .blocked } ?? 0)
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
                let place = [link.profile.name, agent.cwd.map { ($0 as NSString).lastPathComponent }]
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
        snapshot.save()
        // Only a change in content costs a widget reload; the time alone is kept for staleness.
        if published?.items != snapshot.items || published?.complete != snapshot.complete {
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
        if let reply = response as? UNTextInputNotificationResponse, response.actionIdentifier == "reply-in-app",
           let id = info["draftID"] as? String, response.notification.request.trigger == nil {
            // Only app-issued local alerts carry a trusted draft identity. Never send here.
            let old = DraftStore.load(id) ?? ""
            DraftStore.save(old.isEmpty ? reply.userText : old + "\n" + reply.userText, for: id)
        }
        if let address = Self.address(info) {
            open(address, response.notification.request.trigger == nil ? info["draftID"] as? String : nil)
        }
        completionHandler()
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
