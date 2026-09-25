import Foundation

// Wire models for the herdr JSON API (protocol 22, herdr 0.9.1).
// Only fields the app uses are modelled; unknown fields are ignored and
// unknown enum values decode to `.unknown`, so newer servers stay compatible.

public struct WorkspaceCreateResult: Decodable, Sendable {
    public var workspace: Workspace
    public var tab: Tab
    public var rootPane: Pane
    enum CodingKeys: String, CodingKey { case workspace, tab; case rootPane = "root_pane" }
}

public struct TabCreateResult: Decodable, Sendable {
    public var tab: Tab
    public var rootPane: Pane
    enum CodingKeys: String, CodingKey { case tab; case rootPane = "root_pane" }
}

public struct AgentResult: Decodable, Sendable {
    public var agent: Agent
    public var argv: [String]?
}

public struct CloseResult: Decodable, Sendable {
    public var paneID: String?
    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try c.decodeIfPresent(String.self, forKey: .paneID)
    }
}
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, blocked, done, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Sort rank: what needs the user first.
    public var attentionRank: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }
}

public struct Pong: Decodable, Sendable, Equatable {
    public var version: String
    public var protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
    }
}

public struct SessionInfo: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var isDefault: Bool
    public var running: Bool
    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, running
        case isDefault = "default"
    }
}

struct SessionList: Decodable {
    var sessions: [SessionInfo]
}

public struct Workspace: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case number, label, focused
        case id = "workspace_id"
        case agentStatus = "agent_status"
    }
}

public struct Tab: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var workspaceID: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case number, label, focused
        case id = "tab_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
    }
}

public struct Pane: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var workspaceID: String
    public var tabID: String
    public var focused: Bool
    public var agentStatus: AgentStatus
    public var agent: String?
    public var displayAgent: String?
    public var cwd: String?
    public var label: String?
    public var terminalTitle: String?
    public var revision: Int

    enum CodingKeys: String, CodingKey {
        case focused, agent, cwd, label, revision
        case id = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agentStatus = "agent_status"
        case displayAgent = "display_agent"
        case terminalTitle = "terminal_title_stripped"
    }
}

public struct Agent: Decodable, Sendable, Equatable, Identifiable {
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var agentStatus: AgentStatus
    public var agent: String?
    public var displayAgent: String?
    public var name: String?
    public var cwd: String?
    public var terminalTitle: String?
    public var focused: Bool
    public var stateChangeSeq: Int?
    /// Where the agent's own transcript lives, reported by herdr's agent integrations.
    public var agentSession: AgentSessionRef?
    /// True when a full-lifecycle integration reports status and herdr skips screen detection.
    public var screenDetectionSkipped: Bool?
    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case agent, name, cwd, focused
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agentStatus = "agent_status"
        case displayAgent = "display_agent"
        case terminalTitle = "terminal_title_stripped"
        case stateChangeSeq = "state_change_seq"
        case agentSession = "agent_session"
        case screenDetectionSkipped = "screen_detection_skipped"
    }

    /// Human title: explicit name, then the terminal title, then the agent kind.
    public var title: String {
        for candidate in [name, terminalTitle, displayAgent, agent] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return paneID
    }
}

/// `agent_session` on an agent: `{"source":"herdr:omp","agent":"omp","kind":"path","value":"/…/x.jsonl"}`.
/// `kind == "path"` means `value` is a transcript file on the host; other kinds carry only an id.
public struct AgentSessionRef: Decodable, Sendable, Equatable, Hashable {
    public var source: String
    public var agent: String
    public var kind: String
    public var value: String

    public init(source: String, agent: String, kind: String, value: String) {
        self.source = source
        self.agent = agent
        self.kind = kind
        self.value = value
    }

    /// The transcript path, when the integration reported one.
    public var transcriptPath: String? { kind == "path" && value.hasPrefix("/") ? value : nil }
}

public struct Snapshot: Decodable, Sendable, Equatable {
    public var version: String
    public var protocolVersion: Int
    public var workspaces: [Workspace]
    public var tabs: [Tab]
    public var panes: [Pane]
    public var agents: [Agent]
    public var focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case version, workspaces, tabs, panes, agents
        case protocolVersion = "protocol"
        case focusedPaneID = "focused_pane_id"
    }

    /// Agents ordered by what needs attention, then by workspace order.
    public var agentsByAttention: [Agent] {
        let order = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.number) })
        return agents.sorted {
            if $0.agentStatus.attentionRank != $1.agentStatus.attentionRank {
                return $0.agentStatus.attentionRank < $1.agentStatus.attentionRank
            }
            let l = order[$0.workspaceID] ?? .max, r = order[$1.workspaceID] ?? .max
            return l != r ? l < r : $0.paneID < $1.paneID
        }
    }
}

struct SnapshotResult: Decodable {
    var snapshot: Snapshot
}

// MARK: Events

/// A pushed `events.subscribe` line: `{"event": "...", "data": {...}}`.
public struct HerdrEvent: Sendable, Equatable {
    public var kind: String
    /// Set for `pane.agent_status_changed`.
    public var statusChange: StatusChange?

    public struct StatusChange: Decodable, Sendable, Equatable {
        public var paneID: String
        public var workspaceID: String
        public var agentStatus: AgentStatus

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case agentStatus = "agent_status"
        }
    }
}

/// Subscription filters accepted by `events.subscribe`.
public enum Subscription: Encodable, Sendable, Hashable {
    /// Any event kind that takes no parameters, e.g. `pane.created`.
    case kind(String)
    case agentStatusChanged(paneID: String)

    /// Everything that changes the structure the app renders.
    public static let structural: [Subscription] = [
        "workspace.created", "workspace.updated", "workspace.renamed", "workspace.moved",
        "workspace.reordered", "workspace.closed", "tab.created", "tab.closed", "tab.renamed",
        "tab.moved", "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited",
        "pane.agent_detected",
    ].map(Subscription.kind)

    enum CodingKeys: String, CodingKey { case type, paneID = "pane_id" }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .kind(let kind):
            try c.encode(kind, forKey: .type)
        case .agentStatusChanged(let paneID):
            try c.encode("pane.agent_status_changed", forKey: .type)
            try c.encode(paneID, forKey: .paneID)
        }
    }
}

// MARK: Direct terminal stream (`herdr terminal session control|observe`)

public enum TerminalMessage: Sendable, Equatable {
    case frame(TerminalFrame)
    case closed(reason: String?)
}

public struct TerminalFrame: Sendable, Equatable {
    public var seq: UInt64
    /// A full frame repaints the whole screen; otherwise bytes are incremental.
    public var full: Bool
    public var width: Int
    public var height: Int
    /// Raw ANSI bytes to feed the terminal emulator.
    public var bytes: [UInt8]
}

public enum TerminalCommand: Encodable, Sendable, Equatable {
    case text(String)
    case bytes([UInt8])
    case resize(cols: Int, rows: Int)
    case scroll(up: Bool, lines: Int)
    case release

    enum CodingKeys: String, CodingKey { case type, text, bytes, cols, rows, direction, lines }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("terminal.input", forKey: .type)
            try c.encode(text, forKey: .text)
        case .bytes(let bytes):
            try c.encode("terminal.input", forKey: .type)
            try c.encode(Data(bytes).base64EncodedString(), forKey: .bytes)
        case .resize(let cols, let rows):
            try c.encode("terminal.resize", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .scroll(let up, let lines):
            try c.encode("terminal.scroll", forKey: .type)
            try c.encode(up ? "up" : "down", forKey: .direction)
            try c.encode(lines, forKey: .lines)
        case .release:
            try c.encode("terminal.release", forKey: .type)
        }
    }
}
