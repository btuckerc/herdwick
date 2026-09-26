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
    /// The conversation on screen, whose own alerts would be noise.
    private let onScreen: () -> PaneAddress?
    private let open: (PaneAddress) -> Void

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

    init(settings: Settings, links: @escaping () -> [HostConnection], onScreen: @escaping () -> PaneAddress?,
         open: @escaping (PaneAddress) -> Void) {
        self.settings = settings
        self.links = links
        self.onScreen = onScreen
        self.open = open
        stamps = UserDefaults.standard.data(forKey: "attention.stamps")
            .flatMap { try? JSONDecoder().decode([String: Stamp].self, from: $0) } ?? [:]
        published = AttentionSnapshot.load()
        super.init()
        center.delegate = self
    }

    /// Asks once; false when the user declined now or before.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Changes

    func changed(_ link: HostConnection) {
        guard let snapshot = link.snapshot else { return }
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
                guard seq > last else { continue }
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
        var stamps = stamps
        var present: Set<String> = []
        var items: [AttentionSnapshot.Item] = []
        for link in all {
            for agent in link.snapshot?.agents ?? [] where link.hidden[agent.paneID] == nil {
                let address = link.address(paneID: agent.paneID)
                let key = Self.key(address)
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
                let place = [link.profile.name, agent.cwd.map { ($0 as NSString).lastPathComponent }]
                    .compactMap { $0 }.joined(separator: " · ")
                items.append(AttentionSnapshot.Item(
                    id: key, title: agent.conversationTitle, place: place, state: state, since: stamps[key]?.date,
                    url: AttentionLink.url(host: address.hostID, session: address.session, pane: address.paneID)
                ))
            }
        }
        let complete = !all.isEmpty && all.allSatisfy(\.isLive)
        // Forget panes only when every host answered; an offline host's panes may come back.
        if complete { stamps = stamps.filter { present.contains($0.key) } }
        if stamps != self.stamps { self.stamps = stamps }

        var snapshot = AttentionSnapshot(items: items, complete: complete, updated: .now)
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
        completionHandler(address != nil && address == onScreen() ? [] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let address = Self.address(response.notification.request.content.userInfo) { open(address) }
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
