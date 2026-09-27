import AppIntents
import Foundation

struct OpenNeedsYouIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Needs You"
    static let description = IntentDescription("Open Herdwick's Needs You inbox. No remote commands are run.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "herdwick://needs-you")!))
    }
}

struct OpenHerdwickInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Herdwick Inbox"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "herdwick://inbox")!))
    }
}

struct HerdwickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenNeedsYouIntent(), phrases: ["Open Needs You in \(.applicationName)"], shortTitle: "Needs You", systemImageName: "exclamationmark.bubble")
        AppShortcut(intent: OpenHerdwickInboxIntent(), phrases: ["Open \(.applicationName) inbox"], shortTitle: "Inbox", systemImageName: "tray")
    }
}
