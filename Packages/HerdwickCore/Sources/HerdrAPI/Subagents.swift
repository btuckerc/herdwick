import Foundation

public struct SubagentActivity: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case working, completed, failed(String?), cancelled }
    public let id: String
    public let name: String
    public let agentType: String?
    public let spawnCallId: String
    public var state: State
    public var summary: String?
    public var duration: String?
    public var spawnedAt: Date?
    public init(id: String, name: String, agentType: String? = nil, spawnCallId: String = "", state: State = .working, summary: String? = nil, duration: String? = nil, spawnedAt: Date? = nil) {
        self.id = id; self.name = name; self.agentType = agentType; self.spawnCallId = spawnCallId
        self.state = state; self.summary = summary; self.duration = duration; self.spawnedAt = spawnedAt
    }
}

public enum ChildTranscriptState: Sendable, Equatable { case missing, active, exited, tombstoned }

public enum SubagentTranscript {
    public static func path(parentPath: String, format: TranscriptFormat, subagentID: String) -> String? {
        guard !subagentID.isEmpty else { return nil }
        switch format {
        case .omp:
            guard parentPath.hasSuffix(".jsonl") else { return nil }
            return String(parentPath.dropLast(6)) + "/" + subagentID + ".jsonl"
        case .claude:
            guard let slash = parentPath.lastIndex(of: "/") else { return nil }
            let directory = String(parentPath[..<slash])
            let filename = String(parentPath[parentPath.index(after: slash)...])
            guard filename.hasSuffix(".jsonl") else { return nil }
            let session = String(filename.dropLast(6))
            return directory + "/" + session + "/subagents/agent-" + subagentID + ".jsonl"
        case .codex: return nil
        }
    }
}
