import Foundation
import HerdrAPI

/// The last authoritative snapshot of each host and session, so a launch shows the inbox at
/// once, dimmed until the link is live, and the first connect can subscribe to its panes while
/// it takes the preview. Protected like drafts; a copy never counts as live.
@MainActor
enum SnapshotStore {
    struct Copy: Codable, Sendable {
        let hostID: UUID
        let session: String
        let sessions: [SessionInfo]
        let snapshot: Snapshot
    }

    private static var directory: URL { ProtectedFiles.directory.appendingPathComponent("Snapshots", isDirectory: true) }
    private static let writer = Writer()

    static func load(hostID: UUID, session: String) -> Copy? {
        guard let data = try? Data(contentsOf: url(hostID: hostID, session: session)),
              let copy = try? PropertyListDecoder().decode(Copy.self, from: data),
              copy.hostID == hostID, copy.session == session else { return nil }
        return copy
    }

    static func save(_ copy: Copy) {
        writer.save(copy, to: url(hostID: copy.hostID, session: copy.session))
    }

    /// A removed or re-pointed host: its copies must not paint another machine's agents.
    static func remove(hostID: UUID) {
        writer.remove(in: directory, prefix: hostID.uuidString + "-")
    }

    private static func url(hostID: UUID, session: String) -> URL {
        // herdr session names are `[a-z0-9_-]`; anything else is hex-encoded to stay a file name.
        let safe = session.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            ? session : Data(session.utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hostID.uuidString)-\(safe).plist")
    }

    /// Writes the newest pending copy per file, at most once a second per burst, off the main
    /// thread: busy agents change the snapshot many times a second.
    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "herdwick.snapshot-store", qos: .utility)
        private let lock = NSLock()
        private var pending: [URL: Copy] = [:]
        private var scheduled = false

        func save(_ copy: Copy, to url: URL) {
            lock.lock()
            pending[url] = copy
            let start = !scheduled
            scheduled = true
            lock.unlock()
            if start { queue.asyncAfter(deadline: .now() + 1) { self.drain() } }
        }

        private func drain() {
            lock.lock()
            let batch = pending
            pending = [:]
            scheduled = false
            lock.unlock()
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            for (url, copy) in batch {
                // A failed write only costs the next launch its instant inbox.
                try? ProtectedFiles.write(encoder.encode(copy), to: url)
            }
        }

        func remove(in directory: URL, prefix: String) {
            // Synchronous: a link created right after (an edited host) must not load the old copy.
            queue.sync {
                self.lock.lock()
                self.pending = self.pending.filter { !$0.key.lastPathComponent.hasPrefix(prefix) }
                self.lock.unlock()
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
