import SwiftUI
import UIKit

/// Exact source keys prevent branch edits from reusing stale attribution. Main-actor only:
/// attributed SwiftUI values never cross an executor boundary.
@MainActor
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()
    private struct Entry {
        let segments: [MarkdownText.Segment]
        let cost: Int
        var used: UInt64
    }
    private let budget = 8 * 1_024 * 1_024
    private var entries: [String: Entry] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private var warning: NSObjectProtocol?

    private init() {
        warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                          object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.purge() }
        }
    }

    func segments(for text: String) -> [MarkdownText.Segment] {
        clock &+= 1
        if var entry = entries[text] {
            entry.used = clock
            entries[text] = entry
            RenderTrace.count("md.hit")
            return entry.segments
        }
        RenderTrace.count("md.miss")
        let segments = RenderTrace.measure("md.parse") { MarkdownText.segments(text) }
        // Conservative estimate includes source, attributed runs, table cells and containers.
        let estimated = text.utf8.count * 12 + segments.count * 256 + 256
        guard estimated <= budget else { return segments }
        while cost + estimated > budget, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            cost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        entries[text] = Entry(segments: segments, cost: estimated, used: clock)
        cost += estimated
        return segments
    }

    /// A streaming row replaced this version; don't retain every prefix until LRU eviction.
    func discard(_ text: String) {
        if let removed = entries.removeValue(forKey: text) { cost -= removed.cost }
    }

    private func purge() {
        entries.removeAll(keepingCapacity: false)
        cost = 0
    }
}
