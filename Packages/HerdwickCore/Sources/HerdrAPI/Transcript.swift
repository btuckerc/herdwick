import Foundation

// An agent's own session log, read as a conversation.
//
// omp writes one JSON record per line to `~/.omp/agent/sessions/<cwd>/<ts>_<id>.jsonl`
// (herdr reports the path as the agent's `agent_session`). The first line is a padded
// `title` record rewritten in place; everything after it is append-only. Records we
// don't understand are kept as raw rows so a newer omp never silently loses content.

public enum TranscriptFormat: String, Sendable {
    case omp, claude, codex
    public init?(agent: String) {
        switch agent.lowercased() {
        case "omp", "pi": self = .omp
        case "claude": self = .claude
        case "codex": self = .codex
        default: return nil
        }
    }
}

/// How much of a conversation a thread shows.
/// - full: every step expanded as it happens.
/// - folded: runs of steps fold into one "N steps" row (the default).
/// - digest: the user's messages, the assistant's turning-point thoughts, asks, peer messages
///   and the final reply; steps only as a live "working" or a failed last step.
public enum DetailLevel: String, Sendable, CaseIterable, Identifiable {
    case full, folded, digest
    public var id: Self { self }
}

/// One line of the transcript file.
public enum TranscriptEntry: Sendable, Equatable {
    case title(String)
    case message(TranscriptMessage)
    /// omp logs the start of a tool run separately from the call that requested it.
    case toolStarted(id: String, name: String)
    case compaction(summary: String)
    /// A message injected by the harness (background job results and the like).
    case notice(String)
    case subagentEvent(SubagentActivity)
    case peerMessage(id: String, peer: String, text: String, outbound: Bool)
    case metadata(type: String)
    case unknown(type: String, raw: String)
    case malformed(String)
}

public struct TranscriptMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, toolResult }

    public struct ToolCall: Sendable, Equatable {
        public let id: String
        public let name: String
        /// The call's arguments object, re-encoded as JSON.
        public let arguments: String?
        public init(id: String, name: String, arguments: String?) {
            self.id = id; self.name = name; self.arguments = arguments
        }
    }

    public let id: String
    public let role: Role
    public let text: String
    public let thinking: String
    public let imageCount: Int
    public let toolCalls: [ToolCall]
    public let toolCallId: String?
    public let isError: Bool
    public let errorMessage: String?
    /// A tool result's `details` object, re-encoded as JSON.
    public let details: String?
    /// When the record was written; omp and Claude stamp every line.
    public let timestamp: Date?

    public init(id: String, role: Role, text: String, thinking: String = "", imageCount: Int = 0,
                toolCalls: [ToolCall] = [], toolCallId: String? = nil, isError: Bool = false,
                errorMessage: String? = nil, details: String? = nil, timestamp: Date? = nil) {
        self.id = id; self.role = role; self.text = text; self.thinking = thinking
        self.imageCount = imageCount; self.toolCalls = toolCalls; self.toolCallId = toolCallId
        self.isError = isError; self.errorMessage = errorMessage; self.details = details
        self.timestamp = timestamp
    }

    /// Parses "2026-09-25T09:20:08.120Z", with or without fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}

/// Splits appended bytes into transcript entries, holding back a partial last line.
public struct TranscriptReader: Sendable {
    private var pending: [UInt8] = []
    private var skipsPartialLine: Bool
    private let format: TranscriptFormat
    /// Bytes fully turned into entries (or skipped), so the next read can start after them.
    public private(set) var consumedBytes = 0

    /// `startsMidFile`: the first bytes are the tail of a line whose start we never saw.
    public init(format: TranscriptFormat = .omp, startsMidFile: Bool = false) {
        self.format = format
        skipsPartialLine = startsMidFile
    }

    public mutating func append(_ bytes: [UInt8]) -> [TranscriptEntry] {
        pending.append(contentsOf: bytes)
        var entries: [TranscriptEntry] = []
        var start = 0
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let line = pending[start..<newline]
            start = newline + 1
            if skipsPartialLine { skipsPartialLine = false; continue }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
            entries.append(contentsOf: Self.entries(line, format: format))
        }
        pending.removeFirst(start)
        consumedBytes += start
        return entries
    }

    /// The title from the file's first line, which omp rewrites in place and a tail read never sees.
    public static func title(inHead bytes: [UInt8], format: TranscriptFormat = .omp) -> String? {
        guard format == .omp, let newline = bytes.firstIndex(of: 0x0A),
              case .title(let title) = entries(bytes[..<newline], format: format).first,
              !title.isEmpty else { return nil }
        return title
    }

    static func entries(_ line: ArraySlice<UInt8>, format: TranscriptFormat) -> [TranscriptEntry] {
        switch format {
        case .omp:
            if let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               record["type"] as? String == "custom_message",
               record["customType"] as? String == "async-result" {
                let activities = asyncActivities(record)
                if !activities.isEmpty { return activities.map(TranscriptEntry.subagentEvent) }
            }
            return [entry(line)]
        case .claude: return ClaudeTranscript.entries(line)
        case .codex: return CodexTranscript.entries(line)
        }
    }

    static func entry(_ line: ArraySlice<UInt8>) -> TranscriptEntry {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let type = record["type"] as? String else {
            return .malformed(String(decoding: line.prefix(2048), as: UTF8.self))
        }
        switch type {
        case "title", "title_change":
            return .title(record["title"] as? String ?? "")
        case "session":
            return (record["title"] as? String).map(TranscriptEntry.title) ?? .metadata(type: type)
        case "message":
            if let message = message(record) { return .message(message) }
            // Harness reminders to the model, not part of the conversation.
            let role = (record["message"] as? [String: Any])?["role"] as? String
            return role == "developer" || role == "system" ? .metadata(type: "message") : .unknown(type: type, raw: raw(line))
        case "custom" where record["customType"] as? String == "tool_execution_start":
            guard let data = record["data"] as? [String: Any], let id = data["toolCallId"] as? String else {
                return .unknown(type: type, raw: raw(line))
            }
            return .toolStarted(id: id, name: data["toolName"] as? String ?? "tool")
        case "compaction":
            return .compaction(summary: record["shortSummary"] as? String ?? record["summary"] as? String ?? "")
        case "custom_message":
            guard record["display"] as? Bool == true else { return .metadata(type: type) }
            if record["customType"] as? String == "irc:incoming" {
                let details = record["details"] as? [String: Any] ?? [:]
                let fallback = text(record["content"]).text
                return .peerMessage(id: details["id"] as? String ?? record["id"] as? String ?? "", peer: details["from"] as? String ?? "unknown",
                                    text: details["message"] as? String ?? fallback, outbound: false)
            }
            return .notice(text(record["content"]).text)
        case "model_change", "thinking_level_change", "service_tier_change", "credential_pin",
             "ttsr_injection", "model_usage", "session_init", "custom":
            return .metadata(type: type)
        default:
            return .unknown(type: type, raw: raw(line))
        }
    }

    private static func message(_ record: [String: Any]) -> TranscriptMessage? {
        guard let body = record["message"] as? [String: Any],
              let role = (body["role"] as? String).flatMap(TranscriptMessage.Role.init) else { return nil }
        let content = text(body["content"])
        let calls = (body["content"] as? [[String: Any]] ?? []).compactMap { block -> TranscriptMessage.ToolCall? in
            guard block["type"] as? String == "toolCall", let id = block["id"] as? String,
                  let name = block["name"] as? String else { return nil }
            return .init(id: id, name: name, arguments: json(block["arguments"]))
        }
        return TranscriptMessage(
            id: record["id"] as? String ?? "",
            role: role,
            text: content.text,
            thinking: content.thinking,
            imageCount: content.images,
            toolCalls: calls,
            toolCallId: body["toolCallId"] as? String,
            isError: body["isError"] as? Bool ?? false,
            errorMessage: body["errorMessage"] as? String,
            details: json(body["details"]),
            timestamp: TranscriptMessage.date(record["timestamp"])
        )
    }

    /// omp content is a plain string or a list of text/thinking/toolCall/image blocks.
    private static func text(_ content: Any?) -> (text: String, thinking: String, images: Int) {
        if let string = content as? String { return (string, "", 0) }
        var text: [String] = [], thinking: [String] = [], images = 0
        for block in content as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": if let value = block["text"] as? String { text.append(value) }
            case "thinking": if let value = block["thinking"] as? String { thinking.append(value) }
            case "image": images += 1
            default: break
            }
        }
        return (text.joined(separator: "\n\n"), thinking.joined(separator: "\n\n"), images)
    }

    private static func json(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private static func raw(_ line: ArraySlice<UInt8>) -> String { String(decoding: line.prefix(2048), as: UTF8.self) }

    private static func asyncActivities(_ record: [String: Any]) -> [SubagentActivity] {
        taskResults(in: text(record["content"]).text)
    }

    /// Terminal subagents from omp's `<task-result id status agent duration>` tags (any
    /// attribute order, several per message). The tag also rides inside `wait` job texts,
    /// sometimes cut off before its closing tag.
    static func taskResults(in content: String) -> [SubagentActivity] {
        guard let tags = try? NSRegularExpression(pattern: #"<task-result\b([^>]*)>([\s\S]*?)(?:</task-result>|$)"#),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*"([^"]*)""#) else { return [] }
        return tags.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match in
            guard let attrRange = Range(match.range(at: 1), in: content),
                  let bodyRange = Range(match.range(at: 2), in: content) else { return nil }
            let attrs = String(content[attrRange])
            var values: [String: String] = [:]
            for attr in attributes.matches(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) {
                guard let key = Range(attr.range(at: 1), in: attrs), let value = Range(attr.range(at: 2), in: attrs) else { continue }
                values[String(attrs[key])] = String(attrs[value])
            }
            guard let id = values["id"], !id.isEmpty, let status = values["status"], status != "running" else { return nil }
            let body = resultSummary(String(content[bodyRange]))
            let state: SubagentActivity.State = status == "cancelled" ? .cancelled : (status == "failed" ? .failed(body) : .completed)
            return .init(id: id, name: id, agentType: values["agent"], state: state, summary: body, duration: values["duration"])
        }
    }

    /// The readable part of a task-result body: the abort reason, else the output (its JSON
    /// `summary` when it has one), without omp's `<meta/>` and `<preview>` wrappers.
    static func resultSummary(_ body: String) -> String? {
        func inner(_ tag: String) -> String? {
            guard let open = body.range(of: "<\(tag)"), let start = body[open.upperBound...].firstIndex(of: ">") else { return nil }
            let rest = body[body.index(after: start)...]
            return String(rest[..<(rest.range(of: "</\(tag)>")?.lowerBound ?? rest.endIndex)])
        }
        var text = inner("abort-reason") ?? inner("output") ?? inner("preview") ?? body
        text = text.replacing(/<meta\b[^>]*\/>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let summary = object["summary"] as? String {
            text = summary
        }
        return text.isEmpty ? nil : text
    }
}

public struct AskOption: Sendable, Equatable {
    public let label: String
    public let description: String?
    public init(label: String, description: String? = nil) { self.label = label; self.description = description }
}

public struct AskAnswer: Sendable, Equatable {
    /// What the agent was told, e.g. "User selected: Blue".
    public let text: String
    public let selected: [String]
    public let custom: String?
    public let cancelled: Bool
    public let perQuestion: [String: [String]]
    public init(text: String, selected: [String] = [], custom: String? = nil, cancelled: Bool = false,
                perQuestion: [String: [String]] = [:]) {
        self.text = text; self.selected = selected; self.custom = custom; self.cancelled = cancelled
        self.perQuestion = perQuestion
    }
}

public struct AskQuestion: Sendable, Equatable {
    public let id: String
    public let header: String?
    public let question: String
    public let options: [AskOption]
    public let multi: Bool
    /// Index into `options`; omp starts its cursor here.
    public let recommended: Int?
    public init(id: String, header: String? = nil, question: String, options: [AskOption], multi: Bool = false, recommended: Int? = nil) {
        self.id = id; self.header = header; self.question = question; self.options = options
        self.multi = multi; self.recommended = recommended
    }
}


public struct AskActivity: Sendable, Equatable {
    public let toolCallId: String
    public let questions: [AskQuestion]
    public var answer: AskAnswer?
    public init(toolCallId: String, questions: [AskQuestion], answer: AskAnswer? = nil) {
        self.toolCallId = toolCallId; self.questions = questions; self.answer = answer
    }
}

public struct ToolActivity: Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, succeeded, failed }
    public let id: String
    /// The agent's own tool name: `bash` (omp), `Bash` (Claude), `exec_command` (Codex).
    public let name: String
    /// The one line a person would want: the command, the path, the pattern.
    public let summary: String
    /// The call's arguments object as JSON (Codex `apply_patch` input is wrapped as `{"input": …}`).
    public let arguments: String?
    public var state: State
    /// The first lines of the result.
    public var output: String?
    /// Structured result metadata as JSON: omp `details`, Claude `toolUseResult`.
    public var details: String?
    /// Claude's task list after this `TaskCreate`/`TaskUpdate`, folded from every earlier call.
    public var board: [TodoItem]?
    public init(id: String, name: String, summary: String, arguments: String? = nil, state: State = .running,
                output: String? = nil, details: String? = nil, board: [TodoItem]? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.arguments = arguments
        self.state = state; self.output = output; self.details = details; self.board = board
    }
}
public enum NoticeKind: Sendable, Equatable { case other, compaction, error }
public enum ConversationItem: Identifiable, Sendable, Equatable {
    case user(id: String, text: String, imageCount: Int)
    case assistant(id: String, text: String)
    case thinking(id: String, text: String)
    case tool(ToolActivity)
    case ask(AskActivity)
    case subagentResult(id: String, activity: SubagentActivity)
    /// Harness-level events: compaction, errors, injected notices.
    case notice(id: String, text: String, kind: NoticeKind = .other)
    case raw(id: String, type: String, text: String)
    case peerMessage(id: String, peer: String, text: String, outbound: Bool)
    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _), .thinking(let id, _), .notice(let id, _, _), .raw(let id, _, _), .peerMessage(let id, _, _, _): id
        case .tool(let tool): tool.id
        case .ask(let ask): ask.toolCallId
        case .subagentResult(let id, _): id
        }
    }
}

/// The transcript folded into what a chat view shows: tool calls merged with their
/// results, asks with their answers.
public struct Conversation: Sendable {
    public private(set) var items: [ConversationItem] = []
    public private(set) var title: String?
    public private(set) var subagentActivities: [SubagentActivity] = []
    public var subagents: [SubagentActivity] { subagentActivities }
    public var workingSubagents: [SubagentActivity] { subagentActivities.filter { if case .working = $0.state { return true }; return false } }
    private var toolIndex: [String: Int] = [:]
    private var subagentIndex: [String: Int] = [:]
    private var serial = 0
    /// Claude's task list, in creation order.
    private var tasks: [(id: String, subject: String, state: TodoItem.State)] = []

    public init() {}

    /// The newest unanswered ask, the one the agent is waiting on.
    public var pendingAsk: AskActivity? {
        for item in items.reversed() {
            if case .ask(let ask) = item { return ask.answer == nil ? ask : nil }
        }
        return nil
    }

    public func subagents(spawnedBy callId: String) -> [SubagentActivity] { subagentActivities.filter { $0.spawnCallId == callId } }

    public mutating func reconcile(childStates: [String: ChildTranscriptState]) {
        for i in subagentActivities.indices {
            guard case .working = subagentActivities[i].state, let state = childStates[subagentActivities[i].id] else { continue }
            if state == .exited { subagentActivities[i].state = .completed; emitResult(subagentActivities[i]) }
            else if state == .tombstoned { subagentActivities[i].state = .cancelled; emitResult(subagentActivities[i]) }
        }
    }

    private mutating func emitResult(_ activity: SubagentActivity) {
        let id = "subagent-\(activity.id)"
        if let index = subagentIndex[activity.id] { items[index] = .subagentResult(id: id, activity: activity) }
        else { subagentIndex[activity.id] = items.count; items.append(.subagentResult(id: id, activity: activity)) }
    }

    public mutating func apply(_ entries: [TranscriptEntry]) {
        for entry in entries { apply(entry) }
    }

    public mutating func apply(_ entry: TranscriptEntry) {
        switch entry {
        case .title(let text):
            if !text.isEmpty { title = text }
        case .metadata: break
        case .message(let message):
            apply(message)
        case .toolStarted(let id, let name):
            if toolIndex[id] == nil { append(.tool(ToolActivity(id: id, name: name, summary: name)), tool: id) }
        case .compaction(let summary):
            append(.notice(id: nextID("compaction"), text: summary.isEmpty ? "Context compacted" : summary, kind: .compaction))
        case .notice(let text):
            append(.notice(id: nextID("notice"), text: text))
        case .peerMessage(let id, let peer, let text, let outbound):
            append(.peerMessage(id: id.isEmpty ? nextID("peer") : id, peer: peer, text: text, outbound: outbound))
        case .subagentEvent(let activity):
            guard !activity.id.isEmpty else { break }
            if let i = subagentActivities.firstIndex(where: { $0.id == activity.id }) {
                let old = subagentActivities[i]
                if old.state == .cancelled || (activity.state == .working && old.state != .working) { break }
                subagentActivities[i] = SubagentActivity(id: old.id, name: old.name, agentType: old.agentType ?? activity.agentType, spawnCallId: old.spawnCallId, state: activity.state, summary: activity.summary ?? old.summary, duration: activity.duration ?? old.duration, spawnedAt: old.spawnedAt)
                if activity.state != .working { emitResult(subagentActivities[i]) }
            } else { subagentActivities.append(activity); if case .working = activity.state {} else { emitResult(activity) } }
            break
        case .unknown(let type, let raw):
            append(.raw(id: nextID("raw"), type: type, text: raw))
        case .malformed(let raw):
            append(.raw(id: nextID("raw"), type: "malformed", text: raw))
        }
    }

    public func item(id: String) -> ConversationItem? { toolIndex[id].map { items[$0] } }
    public func items(at level: DetailLevel) -> [ConversationItem] {
        guard level == .digest else { return items }
        var keep = Set<Int>()
        for (index, item) in items.enumerated() {
            switch item {
            case .user, .ask, .peerMessage, .subagentResult:
                keep.insert(index)
            case .notice(_, _, let kind) where kind == .compaction || kind == .error:
                keep.insert(index)
            case .tool(let tool) where tool.state == .running && index == items.count - 1:
                keep.insert(index)
            default: break
            }
        }
        if let lastToolIndex = items.lastIndex(where: { if case .tool = $0 { true } else { false } }),
           case .tool(let tool) = items[lastToolIndex], tool.state == .failed {
            keep.insert(lastToolIndex)
        }
        for index in items.indices {
            guard case .assistant(_, let text) = items[index] else { continue }
            let laterTurn = items.dropFirst(index + 1).contains { item in
                switch item {
                case .user, .ask, .peerMessage: true
                default: false
                }
            }
            let isFinalAssistant = !items.dropFirst(index + 1).contains { if case .assistant = $0 { true } else { false } }
            let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count
            let markdownStructure = text.split(separator: "\n").contains { $0.hasPrefix("#") || $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
            if isFinalAssistant || paragraphs >= 2 || markdownStructure { keep.insert(index) }
            if laterTurn, let next = items.indices.dropFirst(index + 1).first(where: { itemIndex in
                switch items[itemIndex] { case .user, .ask, .peerMessage: true; default: false }
            }) {
                let previousTurn = items[index + 1..<next].contains { if case .assistant = $0 { true } else { false } }
                if !previousTurn { keep.insert(index) }
            }
        }
        return items.enumerated().compactMap { keep.contains($0.offset) ? $0.element : nil }
    }

    private mutating func apply(_ message: TranscriptMessage) {
        let id = message.id.isEmpty ? nextID("message") : message.id
        switch message.role {
        case .user:
            append(.user(id: id, text: message.text, imageCount: message.imageCount))
        case .assistant:
            if !message.thinking.isEmpty { append(.thinking(id: id + "-thinking", text: message.thinking)) }
            if !message.text.isEmpty { append(.assistant(id: id, text: message.text)) }
            if let error = message.errorMessage {
                append(.notice(id: id + "-error", text: error, kind: .error))
            }
            for call in message.toolCalls {
                let object = Self.object(call.arguments)
                if call.name == "close_agent", let childID = object["id"] as? String {
                    apply(.subagentEvent(.init(id: childID, name: childID, state: .cancelled)))
                }
                if call.name == "write", let path = object["path"] as? String,
                   path.hasPrefix("agent://"), let content = object["content"] as? String {
                    append(.peerMessage(id: call.id, peer: String(path.dropFirst("agent://".count)), text: content, outbound: true))
                } else if ["ask", "AskUserQuestion", "request_user_input"].contains(call.name), let questions = Self.questions(object) {
                    place(.ask(AskActivity(toolCallId: call.id, questions: questions)), tool: call.id)
                } else if let spawned = Self.spawned(call.name, object, callId: call.id) {
                    place(.tool(ToolActivity(id: call.id, name: call.name, summary: Self.summary(call.name, object), arguments: call.arguments)), tool: call.id)
                    for var activity in spawned {
                        activity.spawnedAt = message.timestamp
                        apply(.subagentEvent(activity))
                    }
                } else {
                    place(.tool(ToolActivity(id: call.id, name: call.name, summary: Self.summary(call.name, object), arguments: call.arguments)), tool: call.id)
                }
            }
        case .toolResult:
            guard let callID = message.toolCallId, let index = toolIndex[callID] else { return }
            switch items[index] {
            case .tool(var tool):
                tool.state = message.isError ? .failed : .succeeded
                tool.output = message.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).joined(separator: "\n")
                tool.details = message.details
                if tool.name == "wait" { applyWait(message.details) }
                if ["Agent", "Task"].contains(tool.name) { applyClaudeResult(tool, message) }
                if tool.name == "spawn_agent", let childID = Self.object(message.text)["agent_id"] as? String,
                   let i = subagentActivities.firstIndex(where: { $0.spawnCallId == tool.id }) {
                    let old = subagentActivities[i]
                    subagentActivities[i] = .init(id: childID, name: old.name, agentType: old.agentType, spawnCallId: old.spawnCallId, state: old.state, spawnedAt: old.spawnedAt)
                }
                if !message.isError, ["TaskCreate", "TaskUpdate"].contains(tool.name) {
                    applyTask(tool)
                    tool.board = tasks.map { TodoItem(text: $0.subject, state: $0.state) }
                }
                items[index] = .tool(tool)
            case .ask(var ask):
                ask.answer = Self.answer(message, questions: ask.questions)
                items[index] = .ask(ask)
            default:
                break
            }
            }
        }
    private static func spawned(_ name: String, _ object: [String: Any], callId: String) -> [SubagentActivity]? {
        if name == "task", let tasks = object["tasks"] as? [[String: Any]] {
            return tasks.compactMap {
                guard let id = ($0["name"] as? String) ?? ($0["id"] as? String) else { return nil }
                return .init(id: id, name: id, agentType: $0["agent"] as? String, spawnCallId: callId)
            }
        }
        if name == "Agent" || name == "Task" || name == "spawn_agent" {
            let id = (object["agentId"] as? String) ?? (object["id"] as? String) ?? callId
            let label = (object["name"] as? String) ?? (object["description"] as? String) ?? id
            return [.init(id: id, name: label, agentType: (object["subagent_type"] as? String) ?? (object["agent_type"] as? String), spawnCallId: callId)]
        }
        return nil
    }
    private mutating func applyWait(_ details: String?) {
        let object = Self.object(details)
        for job in object["jobs"] as? [[String: Any]] ?? [] {
            guard let id = job["id"] as? String, let status = job["status"] as? String, status != "running",
                  let i = subagentActivities.firstIndex(where: { $0.id == id }) else { continue }
            if subagentActivities[i].state == .cancelled { continue }
            let text = (job["resultText"] as? String) ?? (job["errorText"] as? String)
            // The job text usually wraps the same <task-result>; its status ("cancelled") beats the job's ("failed").
            if let text, let tagged = TranscriptReader.taskResults(in: text).first(where: { $0.id == id }) {
                subagentActivities[i].state = tagged.state
                subagentActivities[i].summary = tagged.summary
                subagentActivities[i].duration = tagged.duration ?? subagentActivities[i].duration
            } else {
                let failed = status == "failed" || job["errorText"] != nil
                let summary = text.flatMap(TranscriptReader.resultSummary)
                subagentActivities[i].state = status == "cancelled" ? .cancelled : (failed ? .failed(summary) : .completed)
                subagentActivities[i].summary = summary
                let ms = (job["durationMs"] as? NSNumber)?.intValue ?? (job["durationMs"] as? String).flatMap { Int($0) }
                if let ms { subagentActivities[i].duration = "\(ms / 1000)s" }
            }
            emitResult(subagentActivities[i])
        }
    }
    private mutating func applyClaudeResult(_ tool: ToolActivity, _ message: TranscriptMessage) {
        let details = Self.object(message.details)
        let id = (details["agentId"] as? String) ?? (details["agent_id"] as? String)
        guard let i = subagentActivities.firstIndex(where: { $0.spawnCallId == tool.id || (id != nil && $0.id == id) }) else { return }
        let old = subagentActivities[i]
        guard old.state == .working else { return }
        let status = details["status"] as? String
        let content = (details["content"] as? String)
            ?? (details["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            ?? message.text
        subagentActivities[i] = .init(id: id ?? old.id, name: old.name, agentType: old.agentType, spawnCallId: old.spawnCallId,
                                     state: status == "completed" ? .completed : .working,
                                     summary: status == "completed" ? content : nil, spawnedAt: old.spawnedAt)
        if status == "completed" { emitResult(subagentActivities[i]) }
    }

    /// A tool call replaces the placeholder its `tool_execution_start` may have left.
    private mutating func place(_ item: ConversationItem, tool id: String) {
        if let index = toolIndex[id] { items[index] = item } else { append(item, tool: id) }
    }

    /// `TaskCreate` learns its id from the result (`toolUseResult.task.id`); `TaskUpdate` names it.
    private mutating func applyTask(_ tool: ToolActivity) {
        let args = Self.object(tool.arguments)
        if tool.name == "TaskCreate" {
            guard let id = (Self.object(tool.details)["task"] as? [String: Any])?["id"] as? String else { return }
            tasks.append((id, args["subject"] as? String ?? "", .pending))
            return
        }
        guard let id = args["taskId"] as? String, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let subject = args["subject"] as? String { tasks[index].subject = subject }
        switch args["status"] as? String {
        case "deleted": tasks.remove(at: index)
        case "completed": tasks[index].state = .done
        case "in_progress": tasks[index].state = .active
        case "pending": tasks[index].state = .pending
        default: break
        }
    }

    private mutating func append(_ item: ConversationItem, tool id: String? = nil) {
        if let id { toolIndex[id] = items.count }
        items.append(item)
    }

    private mutating func nextID(_ prefix: String) -> String {
        serial += 1
        return "\(prefix)-\(serial)"
    }

    private static func object(_ json: String?) -> [String: Any] {
        guard let json else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private static func summary(_ name: String, _ arguments: [String: Any]) -> String {
        for key in ["command", "cmd", "path", "file_path", "pattern", "query", "url", "description"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                return value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
            }
        }
        return name
    }

    private static func questions(_ arguments: [String: Any]) -> [AskQuestion]? {
        guard let list = arguments["questions"] as? [[String: Any]] else { return nil }
        let questions = list.enumerated().compactMap { index, question -> AskQuestion? in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { AskOption(label: $0, description: option["description"] as? String) }
            }
            return AskQuestion(id: question["id"] as? String ?? "q\(index)", header: question["header"] as? String,
                               question: text, options: options,
                               multi: question["multi"] as? Bool ?? question["multiSelect"] as? Bool ?? false,
                               recommended: question["recommended"] as? Int)
        }
        return questions.isEmpty ? nil : questions
    }

    /// omp: `details` carries `selectedOptions`/`customInput` for one question, `results[]` for
    /// several. Claude: `toolUseResult.answers` maps each question's text to "A, B" or free text.
    private static func answer(_ message: TranscriptMessage, questions: [AskQuestion] = []) -> AskAnswer {
        let details = object(message.details)
        var per: [String: [String]] = [:], selected: [String] = [], custom: String?
        if let answers = details["answers"] as? [String: Any] {
            for q in questions {
                guard let value = answers[q.question] as? String else { continue }
                var values = value.components(separatedBy: ", "), chosen: [String] = []
                for option in q.options where values.contains(option.label) {
                    chosen.append(option.label); values.removeAll { $0 == option.label }
                }
                // A typed answer may itself contain ", ": keep what isn't an option whole.
                let typed = values.isEmpty ? nil : values.joined(separator: ", ")
                per[q.question] = chosen + [typed].compactMap { $0 }
                selected += chosen
                if let typed, !typed.isEmpty { custom = typed }
            }
            return AskAnswer(text: message.text, selected: selected, custom: custom,
                             cancelled: message.isError || per.isEmpty, perQuestion: per)
        }
        let parts = (details["results"] as? [[String: Any]]) ?? [details]
        for part in parts {
            let chosen = part["selectedOptions"] as? [String] ?? []
            let typed = part["customInput"] as? String
            selected += chosen
            if custom == nil { custom = typed }
            if let question = part["question"] as? String { per[question] = chosen + [typed].compactMap { $0 } }
        }
        return AskAnswer(text: message.text, selected: selected, custom: custom,
                         cancelled: message.isError || (selected.isEmpty && custom == nil), perQuestion: per)
    }
}
