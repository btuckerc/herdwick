import CryptoKit
import Foundation
import HerdrAPI

/// Protected, device-local raw records. No decoded images or rendered models are persisted.
@MainActor
enum TranscriptCache {
    static let maximumBytes = 4 * 1024 * 1024
    private static var directory: URL { ProtectedFiles.directory.appendingPathComponent("Transcripts", isDirectory: true) }
    private static let writer = Writer()
    private(set) static var revision = 0
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "offlineTranscripts") }
    static func preferenceChanged() {
        revision += 1
        writer.discardPending()
    }

    struct Copy: Codable, Sendable {
        let hostID: UUID
        let session: String
        let path: String
        let title: String?
        let saved: Date
        let hasEarlier: Bool
        let bytes: Data
    }

    static func load(host: SessionAddress, path: String) -> Copy? {
        guard isEnabled,
              let data = try? Data(contentsOf: url(host: host, path: path)),
              let copy = try? PropertyListDecoder().decode(Copy.self, from: data),
              copy.hostID == host.hostID, copy.session == host.session, copy.path == path else { return nil }
        return copy
    }

    static func save(host: SessionAddress, path: String, title: String?, bytes: Data, hasEarlier: Bool) {
        guard isEnabled, bytes.count <= maximumBytes else { return }
        let copy = Copy(hostID: host.hostID, session: host.session, path: path, title: title,
                        saved: .now, hasEarlier: hasEarlier, bytes: bytes)
        writer.save(copy, to: url(host: host, path: path))
    }

    static func removeAll() throws {
        revision += 1
        try writer.remove(in: directory, hostID: nil)
    }

    static func remove(hostID: UUID) throws {
        revision += 1
        try writer.remove(in: directory, hostID: hostID)
    }

    private static func url(host: SessionAddress, path: String) -> URL {
        let identity = try! JSONEncoder().encode([host.session, path])
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(host.hostID.uuidString + "-" + hash + ".plist")
    }

    /// The lock protects only pending copies; all encoding and filesystem access is serial.
    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "herdwick.transcript-cache", qos: .utility)
        private let lock = NSLock()
        private var pending: [URL: Copy] = [:]
        private var running = false

        func discardPending() {
            lock.lock()
            pending.removeAll()
            lock.unlock()
        }

        func save(_ copy: Copy, to url: URL) {
            lock.lock()
            pending[url] = copy
            let start = !running
            running = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }

        private func drain() {
            while true {
                lock.lock()
                guard let (url, copy) = pending.first else {
                    running = false
                    lock.unlock()
                    return
                }
                pending.removeValue(forKey: url)
                lock.unlock()
                guard UserDefaults.standard.bool(forKey: "offlineTranscripts") else { continue }
                do {
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    try ProtectedFiles.write(encoder.encode(copy), to: url)
                    let directory = url.deletingLastPathComponent()
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    let ordered = files.map { file in
                        (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    }.sorted { $0.1 > $1.1 }
                    for (file, _) in ordered.dropFirst(20) { try FileManager.default.removeItem(at: file) }
                } catch { /* Cache failure never prevents reading the live transcript. */ }
            }
        }

        func remove(in directory: URL, hostID: UUID?) throws {
            try queue.sync {
                lock.lock()
                if let hostID {
                    pending = pending.filter { !$0.key.lastPathComponent.hasPrefix(hostID.uuidString + "-") }
                } else {
                    pending.removeAll()
                }
                lock.unlock()
                guard FileManager.default.fileExists(atPath: directory.path) else { return }
                if let hostID {
                    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where file.lastPathComponent.hasPrefix(hostID.uuidString + "-") {
                        try FileManager.default.removeItem(at: file)
                    }
                } else {
                    try FileManager.default.removeItem(at: directory)
                }
            }
        }
    }
}

/// Atomic writes keep the old draft intact if protection makes storage unavailable.
enum ProtectedFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Private", isDirectory: true)
    }

    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = parent
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
