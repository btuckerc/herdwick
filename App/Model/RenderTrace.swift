import Foundation
import os

/// Stage timings for comparing builds in the simulator. Off unless the app is launched with
/// `-HerdwickTrace YES`; then each stage's samples go to `Documents/render-trace.json` every
/// two seconds. Names only, never transcript content.
enum RenderTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "HerdwickTrace")

    private struct Stage: Codable {
        var count = 0
        var samples: [Double] = []
    }

    private static let stages = OSAllocatedUnfairLock<[String: Stage]>(initialState: [:])
    private static let writer = OSAllocatedUnfairLock(initialState: false)

    /// Runs `body`, recording how long it took under `stage` when tracing is on.
    @inline(__always)
    static func measure<T>(_ stage: StaticString, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = ContinuousClock.now
        defer { record(stage, ContinuousClock.now - start) }
        return try body()
    }

    /// Counts an event (a cache hit or miss) under `stage`.
    static func count(_ stage: StaticString) {
        guard enabled else { return }
        stages.withLock { $0["\(stage)", default: Stage()].count += 1 }
        startWriting()
    }

    private static func record(_ stage: StaticString, _ duration: Duration) {
        let ms = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
        stages.withLock { all in
            var entry = all["\(stage)", default: Stage()]
            entry.count += 1
            if entry.samples.count < 20_000 { entry.samples.append(ms) }
            all["\(stage)"] = entry
        }
        startWriting()
    }

    private static func startWriting() {
        let start = writer.withLock { started in
            defer { started = true }
            return !started
        }
        guard start else { return }
        Task.detached(priority: .background) {
            let url = URL.documentsDirectory.appending(path: "render-trace.json")
            while true {
                try? await Task.sleep(for: .seconds(2))
                let snapshot = stages.withLock { $0 }
                let summary = snapshot.mapValues { stage -> [String: Double] in
                    let sorted = stage.samples.sorted()
                    func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                    return ["count": Double(stage.count), "total": sorted.reduce(0, +), "p50": pct(0.5),
                            "p95": pct(0.95), "max": sorted.last ?? 0]
                }
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
