import Foundation
import HerdrAPI
import UIKit

/// Unsent composer text per conversation, kept across leaving the view and relaunches.
/// Text only, in an atomic complete-protection file, dropped after two weeks.
/// A locked/unreadable file is never replaced with an empty store.
@MainActor
enum DraftStore {
    private static let key = "composerDrafts"
    private static let lifetime: TimeInterval = 14 * 24 * 3600
    private static var file: URL { ProtectedFiles.directory.appendingPathComponent("Drafts.json") }
    private static var cached: [String: Entry]?
    private static let queue = DispatchQueue(label: "dev.btuckerc.herdwick.drafts", qos: .utility)
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static var revision: UInt64 = 0

    private struct Entry: Codable, Sendable {
        var text: String
        var saved: Date
    }

    /// Prefers the agent's transcript session, which survives herdr reusing a pane id;
    /// otherwise the pane and agent name. Nil while the agent isn't known.
    static func id(host: SessionAddress, agent: Agent?) -> String? {
        guard let agent else { return nil }
        let conversation = agent.agentSession.map { "session:\($0.agent):\($0.value)" }
            ?? "pane:\(agent.paneID):\(agent.name ?? "")"
        return [host.hostID.uuidString, host.session, conversation].joined(separator: "\u{1F}")
    }

    static func load(_ id: String) -> String? {
        guard let entry = entries()?[id] else { return nil }
        guard entry.saved.timeIntervalSinceNow > -lifetime else {
            save("", for: id)
            return nil
        }
        return entry.text
    }

    /// The composer's text once the conversation's id becomes `id`. An agent gaining its
    /// transcript session (pane key to session key, same host and session) is the same
    /// conversation, so its draft moves over; any other change is a different conversation,
    /// whose own draft replaces the text.
    static func adopt(_ id: String, replacing previous: String?, current: String) -> String {
        guard let previous else { return current.isEmpty ? load(id) ?? "" : current }
        let old = previous.split(separator: "\u{1F}"), new = id.split(separator: "\u{1F}")
        let gainedSession = old.count == 3 && new.count == 3 && old[..<2] == new[..<2]
            && old[2].hasPrefix("pane:") && new[2].hasPrefix("session:")
        guard gainedSession else { return load(id) ?? "" }
        guard var all = entries() else { return current }
        let text = current.isEmpty ? all[id]?.text ?? "" : current
        all.removeValue(forKey: previous)
        if !text.isEmpty { all[id] = Entry(text: text, saved: .now) }
        persist(all)
        return text
    }

    /// Saving empty text forgets the draft. Every edit is enqueued in order, without debounce.
    @discardableResult
    static func save(_ text: String, for id: String) -> Bool {
        save(text, for: id, completion: nil)
    }

    private static func save(_ text: String, for id: String,
                             completion: (@Sendable (Bool) -> Void)?) -> Bool {
        guard var all = entries() else { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if all.removeValue(forKey: id) == nil, completion == nil { return true }
        } else {
            all[id] = Entry(text: text, saved: .now)
        }
        persist(all, completion: completion)
        return true
    }

    /// Used before consuming an imported draft: success means this edit reached protected storage.
    static func saveChecked(_ text: String, for id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            if !save(text, for: id, completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: false)
            }
        }
    }

    private static func persist(_ all: [String: Entry], completion: (@Sendable (Bool) -> Void)? = nil) {
        cached = all
        revision &+= 1
        let revision = revision
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save draft") {
                MainActor.assumeIsolated { finishBackgroundWrite() }
            }
        }
        let url = file
        queue.async {
            do {
                try ProtectedFiles.write(JSONEncoder().encode(all), to: url)
                completion?(true)
            } catch { completion?(false) }
            Task { @MainActor in
                if self.revision == revision { finishBackgroundWrite() }
            }
        }
    }

    private static func finishBackgroundWrite() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Live drafts; expired ones are dropped from storage as they're found.
    private static func entries() -> [String: Entry]? {
        if let cached { return cached }
        do {
            var all: [String: Entry] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                all = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
            }
            if let legacy = UserDefaults.standard.data(forKey: key) {
                let old = try JSONDecoder().decode([String: Entry].self, from: legacy)
                all.merge(old) { current, old in current.saved >= old.saved ? current : old }
                try store(all)
                UserDefaults.standard.removeObject(forKey: key)
            }
            let live = all.filter { $0.value.saved.timeIntervalSinceNow > -lifetime }
            if live.count < all.count { try store(live) }
            cached = live
            return live
        } catch { return nil }
    }

    private static func store(_ all: [String: Entry]) throws {
        try ProtectedFiles.write(JSONEncoder().encode(all), to: file)
    }
}
