import Foundation
import HerdrAPI

/// One agent's transcript, followed live while its conversation is on screen.
///
/// It reads the file's first line for the title (omp rewrites it in place), then the
/// last `window` bytes, then keeps one `tail -F` channel open for appends. Leaving the
/// screen cancels the task, which closes the channel and ends the remote `tail`.
@MainActor @Observable
final class ConversationFeed {
    enum State: Equatable {
        case loading
        case live
        case unavailable(String)

        var unavailableReason: String? {
            if case .unavailable(let reason) = self { reason } else { nil }
        }
    }

    private(set) var conversation = Conversation()
    private(set) var state: State = .loading
    /// The session title from the file's head; the tail rarely contains it.
    private(set) var title: String?
    /// True when older records exist before the loaded window.
    private(set) var hasEarlier = false
    /// Bytes of history to load; grows when the user asks for earlier messages.
    private(set) var window = 256 * 1024
    /// The transcript the painted conversation came from; another one starts over as loading.
    private var paintedPath: String?
    private(set) var offlineDate: Date?
    var isOfflineCopy: Bool { offlineDate != nil }
    func discardOfflineCopy() {
        guard isOfflineCopy else { return }
        conversation = Conversation()
        title = nil
        offlineDate = nil
        paintedPath = nil
        paintedHost = nil
        state = .loading
    }
    private var paintedHost: SessionAddress?

    /// May be called before a connection exists, including for an ended conversation.
    func restore(_ location: TranscriptLocation, host: SessionAddress) {
        guard paintedPath != location.path || paintedHost != host else { return }
        conversation = Conversation()
        title = nil
        offlineDate = nil
        state = .loading
        paintedPath = location.path
        paintedHost = host
        guard let copy = TranscriptCache.load(host: host, path: location.path) else { return }
        var reader = TranscriptReader(format: location.format)
        conversation.apply(records: reader.appendRecords(Array(copy.bytes)))
        title = copy.title
        hasEarlier = copy.hasEarlier
        offlineDate = copy.saved
    }

    func showEarlier() {
        window *= 4
    }

    /// Loads and follows the transcript until cancelled or the channel ends. The view keys
    /// this on the link, the location and `window`, and calls it again after a dropped
    /// channel. A conversation already on screen stays there: a lost transport (the app went
    /// to the background) is not a transcript problem, so only a first read that never
    /// painted reports `unavailable`.
    func follow(_ location: TranscriptLocation, client: HerdrClient, host: SessionAddress? = nil) async {
        let path = location.path
        if let host {
            restore(location, host: host)
        } else if paintedPath != path {
            conversation = Conversation()
            title = nil
            offlineDate = nil
            paintedPath = nil
            state = .loading
        }
        let liveness = Task { @MainActor [weak self] in
            guard let self, location.format == .omp else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.isOfflineCopy, !self.conversation.workingSubagents.isEmpty else { continue }
                var paths: [String: String] = [:]
                for activity in self.conversation.workingSubagents {
                    if let child = SubagentTranscript.path(parentPath: path, format: location.format, subagentID: activity.id) {
                        paths[activity.id] = child
                    }
                }
                if let states = try? await client.childTranscriptStates(paths) {
                    self.conversation.reconcile(childStates: states)
                }
            }
        }
        defer { liveness.cancel() }
        if state != .live || paintedPath != path { state = .loading }
        var raw = Data()
        var dropsFirstLine = false
        var cacheHasEarlier = false
        var lastSave = Date.distantPast
        var receivedLiveCopy = false
        func saveCopy() {
            guard receivedLiveCopy, !dropsFirstLine, let host else { return }
            let complete = raw.lastIndex(of: 10).map { Data(raw[...$0]) } ?? Data()
            TranscriptCache.save(host: host, path: path, title: title,
                                 bytes: complete, hasEarlier: cacheHasEarlier)
            lastSave = .now
        }
        defer { saveCopy() }
        do {
            let head = try await client.readFileTail(path: path, from: 0, limit: 4096)
            title = TranscriptReader.title(inHead: head.bytes, format: location.format)
            let start = max(0, head.fileSize - window)
            hasEarlier = start > 0
            dropsFirstLine = start > 0
            cacheHasEarlier = hasEarlier
            var reader = TranscriptReader(format: location.format, startsMidFile: start > 0)
            var fresh = Conversation()
            var painted = head.fileSize == 0
            if painted {
                conversation = fresh
                paintedPath = path
                offlineDate = nil
                state = .live
                receivedLiveCopy = true
            }
            for try await chunk in client.followFile(path: path, from: start) {
                raw.append(contentsOf: chunk)
                if dropsFirstLine, let newline = raw.firstIndex(of: 10) {
                    raw = Data(raw.suffix(from: raw.index(after: newline)))
                    dropsFirstLine = false
                }
                let limit = min(window, TranscriptCache.maximumBytes)
                if raw.count > limit {
                    raw = Data(raw.suffix(limit))
                    dropsFirstLine = true
                    cacheHasEarlier = true
                    if let newline = raw.firstIndex(of: 10) {
                        raw = Data(raw.suffix(from: raw.index(after: newline)))
                        dropsFirstLine = false
                    }
                }
                fresh.apply(records: reader.appendRecords(chunk))
                // The first read arrives in pieces; paint once the backlog is in.
                if painted || reader.consumedBytes >= head.fileSize - start {
                    conversation = fresh
                    painted = true
                    paintedPath = path
                    offlineDate = nil
                    state = .live
                    receivedLiveCopy = true
                    if !dropsFirstLine, Date.now.timeIntervalSince(lastSave) >= 2 { saveCopy() }
                }
            }
        } catch {
            guard !Task.isCancelled, state != .live else { return }
            state = .unavailable("Couldn't read this agent's transcript.")
        }
    }

    /// Whether the agent logged a result for `toolCallId` within `timeout`: the only proof
    /// that an answer typed into its prompt was taken.
    func waitForResult(of toolCallId: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        guard !isOfflineCopy else { return false }
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if case .ask(let ask) = conversation.item(id: toolCallId), ask.answer != nil { return true }
            if case .tool(let tool) = conversation.item(id: toolCallId), tool.state != .running { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}
