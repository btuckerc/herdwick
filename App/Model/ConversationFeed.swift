import Foundation
import HerdrAPI

/// Decodes one follow's bytes off the main actor, in arrival order, and stages its first read
/// so the backlog is applied there too; only appends after the paint are applied on main.
private actor FollowTranscriptWorker {
    private let format: TranscriptFormat
    private var reader: TranscriptReader
    private var staging: Conversation?

    init(format: TranscriptFormat) {
        self.format = format
        reader = TranscriptReader(format: format)
        staging = Conversation()
    }

    func title(inHead bytes: [UInt8]) -> String? {
        TranscriptReader.title(inHead: bytes, format: format)
    }

    func begin(startsMidFile: Bool, continuing: Conversation?) {
        reader = TranscriptReader(format: format, startsMidFile: startsMidFile)
        staging = continuing ?? Conversation()
    }

    func decode(_ bytes: [UInt8]) -> (records: [TranscriptRecord], consumed: Int) {
        let records = RenderTrace.measure("feed.decode") { reader.appendRecords(bytes) }
        return (records, reader.consumedBytes)
    }

    func appendToStaging(_ bytes: [UInt8]) -> (records: [TranscriptRecord], consumed: Int) {
        let result = decode(bytes)
        RenderTrace.measure("feed.apply") { staging?.apply(records: result.records) }
        return result
    }

    func takeStaging() -> Conversation {
        defer { staging = nil }
        return staging ?? Conversation()
    }
}

private struct RestoredTranscript: Sendable {
    var conversation: Conversation
    var title: String?
}

/// One agent's transcript, followed live while its conversation is on screen.
///
/// One `tail -F` channel brings the file's first bytes for the title (omp rewrites it in
/// place), then its last `window` bytes, then every append, so opening costs one exec.
/// Leaving the screen cancels the task, which closes the channel and ends the remote `tail`.
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

    private(set) var conversation = Conversation() {
        didSet { contentRevision &+= 1 }
    }
    /// Bumps with every change to `conversation` (paint, append, reset, warm, restore,
    /// reconcile), so caches of what it renders can be keyed by it. `revision` is the follow's.
    private(set) var contentRevision = 0
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
    var isRenderable: Bool { !conversation.items.isEmpty }
    private(set) var isCaughtUp = false
    private(set) var isFollowing = false
    /// The view whose task follows this feed; another window showing it shares that follow.
    private(set) var follower: UUID?
    private(set) var revision = 0
    private var resumeOffset: Int?
    /// Where the parsed bytes begin; bounds how far an unopened conversation grows.
    private var loadedFrom = 0
    /// The offline copy as last saved and the file offset it ends at; a follow resumes onto it.
    private var savedCopy: (bytes: Data, end: Int)?

    func markStale() { isCaughtUp = false }

    func discardParsedData() {
        guard !isFollowing else { return }
        conversation = Conversation()
        title = nil
        offlineDate = nil
        paintedPath = nil
        paintedHost = nil
        resumeOffset = nil
        savedCopy = nil
        hasEarlier = false
        isCaughtUp = false
        state = .loading
        revision += 1
    }

    /// Nil once the conversation has grown past twice the window: a fresh tail replaces it.
    func warmSnapshot(location: TranscriptLocation?) -> WarmConversation? {
        guard let location, paintedPath == location.path, let resumeOffset, !isOfflineCopy,
              resumeOffset - loadedFrom <= 2 * window else { return nil }
        return WarmConversation(location: location, conversation: conversation, start: loadedFrom,
                                offset: resumeOffset, hasEarlier: hasEarlier, title: title)
    }

    func warm(_ data: WarmConversation, host: SessionAddress) {
        guard !isFollowing else { return }
        if data.location.path != paintedPath || host != paintedHost { savedCopy = nil }
        conversation = data.conversation
        title = data.title ?? title
        hasEarlier = data.hasEarlier
        resumeOffset = data.offset
        loadedFrom = data.start
        paintedPath = data.location.path
        paintedHost = host
        offlineDate = nil
        isCaughtUp = false
        state = .loading
        revision += 1
    }
    func discardOfflineCopy() {
        guard isOfflineCopy else { return }
        conversation = Conversation()
        title = nil
        offlineDate = nil
        paintedPath = nil
        paintedHost = nil
        state = .loading
        resumeOffset = nil
        isCaughtUp = false
    }
    private var paintedHost: SessionAddress?
    private var restoreTicket = 0
    private var generation = 0

    /// May be called before a connection exists, including for an ended conversation.
    func restore(_ location: TranscriptLocation, host: SessionAddress) async {
        guard paintedPath != location.path || paintedHost != host else { return }
        restoreTicket &+= 1
        let ticket = restoreTicket
        conversation = Conversation()
        title = nil
        offlineDate = nil
        state = .loading
        paintedPath = location.path
        paintedHost = host
        resumeOffset = nil
        savedCopy = nil
        hasEarlier = false
        isCaughtUp = false
        guard let copy = TranscriptCache.load(host: host, path: location.path) else { return }
        let format = location.format
        let restored = await Task.detached(priority: .userInitiated) {
            var reader = TranscriptReader(format: format)
            let records = RenderTrace.measure("feed.decode") { reader.appendRecords(Array(copy.bytes)) }
            var initial = Conversation()
            RenderTrace.measure("feed.apply") { initial.apply(records: records) }
            return RestoredTranscript(conversation: initial, title: copy.title)
        }.value
        // Published even if the caller was cancelled: the feed outlives its view, and leaving the
        // path marked painted without the copy would strand a reopened conversation on loading.
        guard ticket == restoreTicket, paintedPath == location.path, paintedHost == host else { return }
        conversation = restored.conversation
        title = restored.title
        hasEarlier = copy.hasEarlier
        offlineDate = copy.saved
    }

    func showEarlier() {
        window *= 4
        resumeOffset = nil
        isCaughtUp = false
        revision += 1
    }

    /// Loads and follows the transcript until cancelled or the channel ends. The view keys
    /// this on the link, the location and `window`, and calls it again after a dropped
    /// channel. A conversation already on screen stays there: a lost transport (the app went
    /// to the background) is not a transcript problem, so only a first read that never
    /// painted reports `unavailable`.
    func follow(_ location: TranscriptLocation, client: HerdrClient, host: SessionAddress? = nil, follower: UUID? = nil) async {
        generation += 1
        restoreTicket &+= 1
        let generation = generation
        revision += 1
        isFollowing = true
        self.follower = follower
        isCaughtUp = false
        defer { if generation == self.generation { isFollowing = false; self.follower = nil; isCaughtUp = false } }
        let path = location.path
        if let host {
            if paintedPath != path || paintedHost != host {
                await restore(location, host: host)
                guard !Task.isCancelled, generation == self.generation else { return }
            }
        } else if host == nil, paintedPath != path {
            conversation = Conversation()
            title = nil
            offlineDate = nil
            paintedPath = nil
            state = .loading
        }
        var receivedLiveCopy = false
        let liveness = Task { @MainActor [weak self] in
            guard let self, location.format == .omp else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, generation == self.generation else { return }
                guard receivedLiveCopy, !self.isOfflineCopy, !self.conversation.workingSubagents.isEmpty else { continue }
                var paths: [String: String] = [:]
                for activity in self.conversation.workingSubagents {
                    if let child = SubagentTranscript.path(parentPath: path, format: location.format, subagentID: activity.id) {
                        paths[activity.id] = child
                    }
                }
                if let states = try? await client.childTranscriptStates(paths),
                   !Task.isCancelled, generation == self.generation {
                    self.conversation.reconcile(childStates: states)
                }
            }
        }
        defer { liveness.cancel() }
        if state != .live || paintedPath != path { state = .loading }
        var caching = TranscriptCache.isEnabled && host != nil
        // A saved copy needs the bytes before the offset; without them the window is read again
        // behind what's painted.
        let resume = paintedPath == path && !isOfflineCopy && (!caching || savedCopy?.end == resumeOffset) ? resumeOffset : nil
        var raw = resume != nil ? savedCopy?.bytes ?? Data() : Data()
        var cacheRevision = TranscriptCache.revision
        var dropsFirstLine = false
        var cacheHasEarlier = false
        var lastSave = Date.distantPast
        func saveCopy() {
            guard generation == self.generation, cacheRevision == TranscriptCache.revision,
                  TranscriptCache.isEnabled, caching, receivedLiveCopy, !dropsFirstLine, let host else { return }
            let complete = raw.lastIndex(of: 10).map { Data(raw[...$0]) } ?? Data()
            TranscriptCache.save(host: host, path: path, title: title,
                                 bytes: complete, hasEarlier: cacheHasEarlier)
            if let resumeOffset { savedCopy = (complete, resumeOffset) }
            lastSave = .now
        }
        defer { saveCopy() }
        do {
            let worker = FollowTranscriptWorker(format: location.format)
            var painted = false
            var backlog = 0
            var received = 0
            var streamStart = 0
            var hasCompleteBoundary = false
            for try await event in client.followFile(path: path, lastBytes: window, headLimit: 4096, resumeOffset: resume) {
                guard !Task.isCancelled, generation == self.generation else { return }
                let chunk: [UInt8]
                switch event {
                case .opened(let fileSize, let start, let head):
                    let headTitle = await worker.title(inHead: head)
                    guard !Task.isCancelled, generation == self.generation else { return }
                    title = headTitle
                    streamStart = start
                    let continuing = resume != nil && start == resume
                    hasCompleteBoundary = continuing || start == 0
                    let initial = continuing ? conversation : nil
                    await worker.begin(startsMidFile: !continuing && start > 0, continuing: initial)
                    guard !Task.isCancelled, generation == self.generation else { return }
                    if !continuing { resumeOffset = nil; loadedFrom = start; raw = Data() }
                    hasEarlier = continuing ? hasEarlier : start > 0
                    dropsFirstLine = !continuing && start > 0
                    cacheHasEarlier = hasEarlier
                    backlog = fileSize - start
                    if backlog == 0 {
                        let initialConversation = await worker.takeStaging()
                        guard !Task.isCancelled, generation == self.generation else { return }
                        conversation = initialConversation
                        painted = true
                        paintedPath = path
                        offlineDate = nil
                        state = .live
                        receivedLiveCopy = true
                        resumeOffset = start
                        isCaughtUp = true
                    }
                    continue
                case .bytes(let bytes):
                    chunk = bytes
                }
                let enabled = TranscriptCache.isEnabled && host != nil
                if caching != enabled || cacheRevision != TranscriptCache.revision {
                    raw = Data()
                    caching = enabled
                    cacheRevision = TranscriptCache.revision
                    // Enabling mid-stream starts at an unknown JSONL boundary.
                    dropsFirstLine = true
                    cacheHasEarlier = true
                }
                if caching {
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
                }
                received += chunk.count
                if chunk.contains(10) { hasCompleteBoundary = true }
                // A chunk already in `raw` is applied even if the task was cancelled meanwhile, so
                // the saved copy never runs ahead of `resumeOffset`; only a newer follow drops it.
                let records: [TranscriptRecord]
                let consumed: Int
                if painted {
                    let decoded = await worker.decode(chunk)
                    guard generation == self.generation else { return }
                    records = decoded.records
                    consumed = decoded.consumed
                    RenderTrace.measure("feed.apply") { conversation.apply(records: records) }
                } else {
                    let decoded = await worker.appendToStaging(chunk)
                    guard generation == self.generation else { return }
                    records = decoded.records
                    consumed = decoded.consumed
                }
                // Where the painted conversation ends: it moves only with what is painted. A follow
                // cut off mid-backlog (cancelled, dropped) leaves its staged records unpainted, and
                // the next follow must read them again rather than resume past them.
                let offset = hasCompleteBoundary ? streamStart + consumed : nil
                if !painted && received >= backlog {
                    let initialConversation = await worker.takeStaging()
                    guard generation == self.generation else { return }
                    conversation = initialConversation
                    painted = true
                    resumeOffset = offset
                    paintedPath = path
                    offlineDate = nil
                    state = .live
                    receivedLiveCopy = true
                    isCaughtUp = true
                } else if painted {
                    resumeOffset = offset
                    isCaughtUp = true
                }
                if painted, !dropsFirstLine, Date.now.timeIntervalSince(lastSave) >= 2 { saveCopy() }
            }
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            if !isRenderable { state = .unavailable("Couldn't read this agent's transcript.") }
        }
    }

    /// Whether the agent logged a result for `toolCallId` within `timeout`: the only proof
    /// that an answer typed into its prompt was taken.
    func waitForResult(of toolCallId: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        guard !isOfflineCopy else { return false }
        while !Task.isCancelled {
            if case .ask(let ask) = conversation.item(id: toolCallId), ask.answer != nil { return true }
            if case .tool(let tool) = conversation.item(id: toolCallId), tool.state != .running { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}
