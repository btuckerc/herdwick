import ActivityKit
import Foundation

struct WatchedRunAttributes: ActivityAttributes {
    let title: String
    let host: String
    struct ContentState: Codable, Hashable {
        var status: String
    }
}
