import Foundation

/// Read-only views over a conversation's items that the chat builds its rows and sheets from.
extension Array where Element == ConversationItem {
    /// Briefs this agent sent that the other agent's next word answers, by the answer's id.
    /// Only a lone brief pairs: two briefs before one answer, or an answer with no brief since
    /// that agent last spoke, stay apart rather than guess which answers which.
    public func answeredBriefs() -> [String: ConversationItem] {
        var pending: [String: [ConversationItem]] = [:]
        var answered: [String: ConversationItem] = [:]
        func answer(_ id: String, from peers: [String]) {
            for peer in peers {
                guard let briefs = pending.removeValue(forKey: peer) else { continue }
                if briefs.count == 1 { answered[id] = briefs[0] }
            }
        }
        for item in self {
            switch item {
            case .peerMessage(_, let peer, _, true): pending[peer, default: []].append(item)
            case .peerMessage(let id, let peer, _, false): answer(id, from: [peer])
            case .subagentResult(let id, let activity): answer(id, from: [activity.id, activity.name])
            default: break
            }
        }
        return answered
    }
}

/// Files the conversation's tools changed, each with the calls that changed it.
public struct RecordedEdit: Sendable, Identifiable {
    public let path: String
    /// Newest first.
    public let tools: [ToolActivity]
    public var id: String { path }
}

/// What arrived after a point the reader last saw.
public struct CatchUp: Sendable, Equatable {
    /// The last item the reader saw; new ones follow it.
    public let after: String
    public let items: Int
    public let edits: Int
    public let replies: Int
    public let failures: Int
    public let images: Int
}

extension Conversation {
    /// Successful edits and file writes by path, the most recently changed file first. Only what
    /// the tools recorded in the loaded history: a shell's own edits aren't here.
    public var recordedEdits: [RecordedEdit] {
        var order: [String] = []
        var byPath: [String: [ToolActivity]] = [:]
        for item in items.reversed() {
            guard case .tool(let tool) = item, tool.state == .succeeded, tool.kind == .edit else { continue }
            let paths: [String] = switch tool.detail {
            case .edit(let files): files.map(\.path)
            case .write(let path, _): [path]
            default: [tool.summary]
            }
            for path in paths {
                if byPath[path] == nil { order.append(path) }
                byPath[path, default: []].append(tool)
            }
        }
        return order.map { RecordedEdit(path: $0, tools: byPath[$0] ?? []) }
    }

    /// The newest item whose id comes from the transcript itself, so the same item has it after
    /// a reload; generated ids ("message-12") depend on how much was loaded.
    public var lastStableID: String? {
        items.last { !Self.isGenerated($0.id) }?.id
    }

    /// What came after `id`; nil when it isn't loaded or nothing followed it.
    public func catchUp(after id: String) -> CatchUp? {
        guard !Self.isGenerated(id), let index = items.lastIndex(where: { $0.id == id }), index + 1 < items.count else { return nil }
        var edits = 0, replies = 0, failures = 0, images = 0
        for item in items[(index + 1)...] {
            switch item {
            case .tool(let tool):
                images += tool.images.count
                if tool.state == .succeeded, tool.kind == .edit { edits += 1 }
                if tool.state == .failed, tool.name != "wait" { failures += 1 }
            case .peerMessage(_, _, _, false), .subagentResult: replies += 1
            case .notice(_, _, .error): failures += 1
            default: break
            }
        }
        return CatchUp(after: id, items: items.count - index - 1, edits: edits, replies: replies, failures: failures, images: images)
    }

    /// The file a reply names (`shot.png`, `Views/a.swift`, or a full path), found among the
    /// paths the tools read, wrote, edited or mentioned in a command or its output, newest
    /// first, with the images a read of it returned. A full path matches only itself; a URL in
    /// a command never stands for a file. Nil when no tool named it.
    public func touchedFile(_ name: String) -> (path: String, images: [TranscriptImage])? {
        guard !name.isEmpty else { return nil }
        let absolute = name.hasPrefix("/") || name.hasPrefix("~")
        let suffix = "/" + name
        func matches(_ path: some StringProtocol) -> Bool { path == name || (!absolute && path.hasSuffix(suffix)) }
        for item in items.reversed() {
            guard case .tool(let tool) = item else { continue }
            switch tool.detail {
            case .read(let path, _): if matches(path) { return (path, tool.images) }
            case .write(let path, _): if matches(path) { return (path, []) }
            case .edit(let files): if let file = files.first(where: { matches($0.path) }) { return (file.path, []) }
            case .shell(let command, let output, _):
                for text in [output ?? "", command] {
                    let words = text.split(whereSeparator: \.isWhitespace).filter { !$0.contains("://") }
                        .flatMap { $0.split { "'\"`()<>,;=:".contains($0) } }
                    if let word = words.last(where: matches) { return (String(word), []) }
                }
            default: continue
            }
        }
        return nil
    }

    private static func isGenerated(_ id: String) -> Bool {
        guard let dash = id.lastIndex(of: "-") else { return false }
        let prefix = id[..<dash], serial = id[id.index(after: dash)...]
        return !serial.isEmpty && serial.allSatisfy(\.isASCII) && serial.allSatisfy(\.isNumber)
            && ["message", "notice", "compaction", "peer", "raw", "job"].contains(prefix)
    }
}
