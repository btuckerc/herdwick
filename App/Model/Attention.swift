import HerdrAPI
import UserNotifications
import WidgetKit

/// Turns agents that need you or have finished into alerts, the app badge and the widgets'
/// snapshot. Everything here is local: it sees what the app sees while it is open or
/// refreshing in the background.
@MainActor
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    private let settings: Settings
    /// Every current link, across hosts and sessions.
    private let links: () -> [HostConnection]
    /// The conversation on screen, whose own alerts would be noise.
    private let onScreen: () -> PaneAddress?
    private let open: (PaneAddress) -> Void

    private let center = UNUserNotificationCenter.current()
    /// Pane key → the `state_change_seq` last alerted, so a reconnect or a background
    /// refresh never repeats an alert. A pane seen for the first time starts here, silently.
    private var alerted: [String: Int] {
        didSet { UserDefaults.standard.set(alerted, forKey: "attention.alerted") }
    }
    private var badge = -1
    private var published: AttentionSnapshot?

    init(settings: Settings, links: @escaping () -> [HostConnection], onScreen: @escaping () -> PaneAddress?,
         open: @escaping (PaneAddress) -> Void) {
        self.settings = settings
        self.links = links
        self.onScreen = onScreen
        self.open = open
        alerted = UserDefaults.standard.dictionary(forKey: "attention.alerted") as? [String: Int] ?? [:]
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
        var items: [(AttentionSnapshot.Item, Int)] = []
        for link in links() {
            for agent in link.snapshot?.agents ?? [] {
                let state: AttentionSnapshot.Item.State
                switch link.presentedStatus(agent) {
                case .blocked: state = .blocked
                case .done: state = .done
                default: continue
                }
                let address = link.address(paneID: agent.paneID)
                let place = [link.profile.name, agent.cwd.map { ($0 as NSString).lastPathComponent }]
                    .compactMap { $0 }.joined(separator: " · ")
                items.append((AttentionSnapshot.Item(
                    id: Self.key(address), title: agent.conversationTitle, place: place, state: state,
                    url: AttentionLink.url(host: address.hostID, session: address.session, pane: address.paneID)
                ), agent.stateChangeSeq ?? 0))
            }
        }
        items.sort { ($0.0.state == .blocked ? 0 : 1, -$0.1) < ($1.0.state == .blocked ? 0 : 1, -$1.1) }
        let all = links()
        let snapshot = AttentionSnapshot(items: items.map(\.0), complete: !all.isEmpty && all.allSatisfy(\.isLive),
                                         updated: .now)
        snapshot.save()
        // Only a change in content costs a widget reload; the time alone is kept for staleness.
        if published?.items != snapshot.items || published?.complete != snapshot.complete {
            WidgetCenter.shared.reloadAllTimelines()
        }
        published = snapshot
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let address = Self.address(notification.request.content.userInfo)
        return await MainActor.run {
            address != nil && address == onScreen() ? [] : [.banner, .list, .sound]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let address = Self.address(response.notification.request.content.userInfo) else { return }
        await MainActor.run { open(address) }
    }

    nonisolated private static func address(_ info: [AnyHashable: Any]) -> PaneAddress? {
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
              let session = info["session"] as? String, let pane = info["pane"] as? String else { return nil }
        return PaneAddress(hostID: host, session: session, paneID: pane)
    }

    nonisolated private static func key(_ address: PaneAddress) -> String {
        "\(address.hostID.uuidString)/\(address.session)/\(address.paneID)"
    }
}
