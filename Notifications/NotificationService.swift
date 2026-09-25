import UserNotifications
import WidgetKit

/// Dresses a push from a host watcher (opaque ids only) with the names the app last saw,
/// records it so the app never repeats it, and moves that agent in the widgets' snapshot.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let info = content.userInfo
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)), let session = info["session"] as? String,
              let pane = info["pane"] as? String, let state = (info["state"] as? String).flatMap(AttentionSnapshot.Item.State.init),
              let seq = info["seq"] as? Int else {
            contentHandler(content)
            return
        }
        let key = AttentionSnapshot.key(host: host, session: session, pane: pane)

        let shared = AttentionSnapshot.shared
        var alerted = shared?.dictionary(forKey: AttentionSnapshot.alertedKey) as? [String: Int] ?? [:]
        alerted[key] = max(alerted[key] ?? 0, seq)
        shared?.set(alerted, forKey: AttentionSnapshot.alertedKey)

        if var snapshot = AttentionSnapshot.load(), let index = snapshot.items.firstIndex(where: { $0.id == key }) {
            let item = snapshot.items[index]
            content.title = item.title
            content.subtitle = item.place
            content.body = state == .blocked ? "Needs you" : "Finished"
            snapshot.items[index] = AttentionSnapshot.Item(id: item.id, title: item.title, place: item.place, state: state,
                                                           since: .now, url: item.url)
            snapshot.sort()
            snapshot.save()
            if state == .blocked { content.badge = snapshot.blocked as NSNumber }
            WidgetCenter.shared.reloadAllTimelines()
        }
        contentHandler(content)
    }
}
