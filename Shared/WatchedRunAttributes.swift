import ActivityKit
import Foundation

struct WatchedRunAttributes: ActivityAttributes {
    let title: String
    let host: String
    /// The agent's workspace ("web-dashboard"); optional so a card from an older build still decodes.
    var place: String? = nil
    /// The watched agent's `AttentionLink`, so a tap opens its conversation, not the inbox.
    let link: URL
    struct ContentState: Codable, Hashable {
        /// "working", "blocked", "done", or "closed" (the agent left herdr).
        var status: String
        var detail: String? = nil
        /// When the current run began, for the card's clock: the turn's message, or back at work
        /// after an answer (round 48: sb#2, the card kept the first turn's clock). Optional: the
        /// relay's status-only pushes leave it out, and the card then shows no clock.
        var since: Date? = nil
    }
}
