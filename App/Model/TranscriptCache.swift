import CryptoKit
import Foundation
import HerdrAPI

/// Protected, device-local raw records. No decoded images or rendered models are persisted.
@MainActor
enum TranscriptCache {
    static let maximumBytes = 4 * 1024 * 1024
    private static let maximumConversations = 20
    private static var directory: URL { ProtectedFiles.directory.appendingPathComponent("Transcripts", isDirectory: true) }

    struct Copy: Codable {
        let hostID: UUID
        let session: String
        let path: String
        let title: String?
        let saved: Date
        let hasEarlier: Bool
        let bytes: Data
    }

    static func load(host: SessionAddress, path: String) -> Copy? {
        guard UserDefaults.standard.bool(forKey: "offlineTranscripts"),
              let data = try? Data(contentsOf: url(host: host, path: path)),
              let copy = try? PropertyListDecoder().decode(Copy.self, from: data),
              copy.hostID == host.hostID, copy.session == host.session, copy.path == path else { return nil }
        return copy
    }

    static func save(host: SessionAddress, path: String, title: String?, bytes: Data, hasEarlier: Bool) {
        guard UserDefaults.standard.bool(forKey: "offlineTranscripts"), bytes.count <= maximumBytes else { return }
        let copy = Copy(hostID: host.hostID, session: host.session, path: path, title: title,
                        saved: .now, hasEarlier: hasEarlier, bytes: bytes)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try ProtectedFiles.write(encoder.encode(copy), to: url(host: host, path: path))
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let ordered = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for file in ordered.dropFirst(maximumConversations) { try FileManager.default.removeItem(at: file) }
        } catch { /* Cache failure never prevents reading the live transcript. */ }
    }

    static func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func remove(hostID: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix(hostID.uuidString + "-") {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func url(host: SessionAddress, path: String) -> URL {
        let identity = try! JSONEncoder().encode([host.session, path])
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(host.hostID.uuidString + "-" + hash + ".plist")
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
