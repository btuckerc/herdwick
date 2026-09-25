import Foundation

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed, gap }
    public let kind: Kind
    public let text: String
    public let line: Int?
    public init(kind: Kind, text: String, line: Int? = nil) { self.kind = kind; self.text = text; self.line = line }
}

public struct FileDiff: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case modified, added, deleted }
    public let path: String
    public let change: Change
    public let lines: [DiffLine]
    public var added: Int
    public var removed: Int
    public init(path: String, change: Change, lines: [DiffLine], added: Int? = nil, removed: Int? = nil) {
        self.path = path; self.change = change; self.lines = lines
        self.added = added ?? lines.filter { $0.kind == .added }.count
        self.removed = removed ?? lines.filter { $0.kind == .removed }.count
    }
}

public struct TodoItem: Sendable, Equatable {
    public enum State: Sendable, Equatable { case pending, active, done }
    public let text: String
    public let state: State
    public init(text: String, state: State) { self.text = text; self.state = state }
}

public enum ToolDetail: Sendable, Equatable {
    case shell(command: String, output: String?, exitCode: Int?)
    case read(path: String, range: String?)
    case edit([FileDiff])
    case write(path: String, content: String)
    case search(pattern: String, scope: String?, output: String?)
    case web(target: String, output: String?)
    case todo([TodoItem])
    case task(title: String, output: String?)
    case plan(String)
    case generic(output: String?)
}

extension ToolDetail {
    public init(name: String, arguments: String?, output: String?, details: String?) {
        let args = Self.object(arguments)
        let meta = Self.object(details)
        let exit = meta?["exit_code"] as? Int
        if arguments != nil && args == nil && name != "apply_patch" {
            self = .generic(output: output)
            return
        }
        switch name {
        case "bash", "Bash": self = .shell(command: Self.string(args?["command"]) ?? "", output: output, exitCode: exit)
        case "exec_command": self = .shell(command: Self.command(args?["cmd"]), output: output, exitCode: exit)
        case "shell", "local_shell": self = .shell(command: Self.command(args?["command"] ?? args?["cmd"]), output: output, exitCode: exit)
        case "read", "Read":
            let path = Self.string(args?[name == "Read" ? "file_path" : "path"]) ?? ""
            let off = Self.int(args?["offset"]), lim = Self.int(args?["limit"])
            self = .read(path: path, range: off.map { "\($0)–\($0 + (lim ?? 0))" })
        case "view_image": self = .read(path: Self.string(args?["path"]) ?? "", range: nil)
        case "edit":
            if let diff = Self.string(meta?["diff"]), let path = Self.string(meta?["path"] ?? args?["path"]) { self = .edit([Self.ompDiff(path: path, text: diff)]) }
            else if let path = Self.string(args?["path"]) { self = .edit([FileDiff(path: path, change: .modified, lines: [])]) }
            else { self = .generic(output: output) }
        case "Edit", "MultiEdit":
            guard let path = Self.string(args?["file_path"]) else { self = .generic(output: output); break }
            if let hunks = meta?["structuredPatch"] as? [[String: Any]], !hunks.isEmpty { self = .edit([Self.hunkDiff(path: path, hunks)]) }
            else if name == "MultiEdit" { self = .edit(Self.multiEdit(args, output: output)) }
            else if let old = Self.string(args?["old_string"]), let new = Self.string(args?["new_string"]) { self = .edit([Self.textDiff(path: path, old: old, new: new)]) }
            else { self = .generic(output: output) }
        case "NotebookEdit": self = .generic(output: output)
        case "apply_patch":
            if let patch = Self.string(args?["input"] ?? args?["patch"]) ?? arguments { self = .edit(Self.patchDiff(patch)) }
            else { self = .generic(output: output) }
        case "write", "Write":
            let p = Self.string(args?[name == "Write" ? "file_path" : "path"]) ?? ""
            self = .write(path: p, content: Self.string(args?["content"]) ?? "")
        case "grep", "Glob", "Grep", "find":
            self = .search(pattern: Self.string(args?[name == "Grep" || name == "grep" ? "pattern" : (name == "find" ? "query" : "pattern")]) ?? "", scope: Self.string(args?["path"]), output: output)
        case "web_search", "WebSearch": self = .web(target: Self.string(args?["query"]) ?? "", output: output)
        case "fetch", "web_fetch", "WebFetch": self = .web(target: Self.string(args?["url"]) ?? "", output: output)
        case "TodoWrite": self = .todo(Self.todos(args?["todos"]))
        case "update_plan": self = .todo(Self.todos(args?["plan"]))
        case "todo_write", "todo": self = .todo(Self.todos(args?["todos"] ?? args?["items"]))
        case "task":
            let first = (args?["tasks"] as? [[String: Any]])?.first
            self = .task(title: Self.string(first?["name"] ?? first?["task"]) ?? Self.string(args?["context"])?.split(separator: "\n").first.map(String.init) ?? "", output: output)
        case "Task", "Agent": self = .task(title: Self.string(args?["description"] ?? args?["prompt"] ?? args?["task"] ?? args?["message"]) ?? "", output: output)
        case "spawn_agent": self = .task(title: Self.string(args?["message"] ?? args?["prompt"] ?? args?["task"]) ?? "", output: output)
        case "ExitPlanMode": self = .plan(Self.string(args?["plan"]) ?? "")
        default: self = .generic(output: output)
        }
    }

    private static func object(_ string: String?) -> [String: Any]? { guard let string, let d = string.data(using: .utf8) else { return nil }; return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func int(_ value: Any?) -> Int? { if let i = value as? Int { return i }; if let n = value as? NSNumber { return n.intValue }; return nil }
    private static func command(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let a = value as? [Any] else { return "" }
        let parts = a.compactMap { $0 as? String }
        if parts.count >= 3 && (parts[0] == "bash" || parts[0].hasSuffix("/bash")) && parts[1] == "-lc" { return parts[2] }
        return parts.joined(separator: " ")
    }
    private static func todos(_ value: Any?) -> [TodoItem] {
        (value as? [[String: Any]] ?? []).compactMap { x in
            let text = Self.string(x["content"] ?? x["step"] ?? x["text"]) ?? ""
            let s = Self.string(x["status"]) ?? "pending"
            let state: TodoItem.State = s == "completed" || s == "done" ? .done : (s == "in_progress" || s == "active" ? .active : .pending)
            return text.isEmpty ? nil : TodoItem(text: text, state: state)
        }
    }
    private static func textDiff(path: String, old: String, new: String) -> FileDiff {
        var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map { DiffLine(kind: .removed, text: String($0)) }
        lines += new.split(separator: "\n", omittingEmptySubsequences: false).map { DiffLine(kind: .added, text: String($0)) }
        return FileDiff(path: path, change: .modified, lines: lines)
    }
    private static func multiEdit(_ a: [String: Any]?, output: String?) -> [FileDiff] {
        guard let p = Self.string(a?["file_path"]), let edits = a?["edits"] as? [[String: Any]] else { return [] }
        var all: [DiffLine] = []
        for (i,e) in edits.enumerated() { if i > 0 { all.append(DiffLine(kind: .gap, text: "")) }; all += textDiff(path: p, old: Self.string(e["old_string"]) ?? "", new: Self.string(e["new_string"]) ?? "").lines }
        return [FileDiff(path: p, change: .modified, lines: all)]
    }
    /// Claude's `toolUseResult.structuredPatch`: unified hunks, each line prefixed " ", "-" or "+".
    private static func hunkDiff(path: String, _ hunks: [[String: Any]]) -> FileDiff {
        var out: [DiffLine] = []
        for (i, hunk) in hunks.enumerated() {
            if i > 0 { out.append(DiffLine(kind: .gap, text: "")) }
            var old = int(hunk["oldStart"]) ?? 1, new = int(hunk["newStart"]) ?? 1
            for row in hunk["lines"] as? [String] ?? [] {
                let text = String(row.dropFirst())
                switch row.first {
                case "+": out.append(DiffLine(kind: .added, text: text, line: new)); new += 1
                case "-": out.append(DiffLine(kind: .removed, text: text, line: old)); old += 1
                case "\\": continue
                default: out.append(DiffLine(kind: .context, text: text, line: new)); old += 1; new += 1
                }
            }
        }
        return FileDiff(path: path, change: .modified, lines: out)
    }
    private static func ompDiff(path: String, text: String) -> FileDiff {
        var out:[DiffLine] = []
        for row in text.components(separatedBy: .newlines) {
            if row.isEmpty { if out.last?.kind != .gap { out.append(DiffLine(kind: .gap, text: "")) }; continue }
            let kind: DiffLine.Kind = row.first == "+" ? .added : row.first == "-" ? .removed : .context
            let body = String(row.dropFirst()).split(separator: "|", maxSplits: 1).map(String.init)
            let n = Int(body.first ?? "")
            out.append(DiffLine(kind: kind, text: body.count > 1 ? body[1] : row, line: n))
        }
        return FileDiff(path: path, change: .modified, lines: out)
    }
    private static func patchDiff(_ patch: String) -> [FileDiff] {
        var result:[FileDiff] = []; var path = ""; var lines:[DiffLine] = []; var change: FileDiff.Change = .modified
        func finish() { if !path.isEmpty { result.append(FileDiff(path: path, change: change, lines: lines)); lines = [] } }
        for row in patch.components(separatedBy: .newlines) {
            if row.hasPrefix("*** Update File: ") { finish(); path = String(row.dropFirst(17)); change = .modified }
            else if row.hasPrefix("*** Add File: ") { finish(); path = String(row.dropFirst(14)); change = .added }
            else if row.hasPrefix("*** Delete File: ") { finish(); path = String(row.dropFirst(17)); change = .deleted }
            else if row.hasPrefix("*** Move to: ") { path = String(row.dropFirst(13)); change = .modified }
            else if row.hasPrefix("+") && !row.hasPrefix("+++") { lines.append(DiffLine(kind: .added, text: String(row.dropFirst()))) }
            else if row.hasPrefix("-") && !row.hasPrefix("---") { lines.append(DiffLine(kind: .removed, text: String(row.dropFirst()))) }
            else if row.hasPrefix(" ") { lines.append(DiffLine(kind: .context, text: String(row.dropFirst()))) }
        }
        finish(); return result
    }
}

extension ToolActivity {
    public var detail: ToolDetail { board.map(ToolDetail.todo) ?? ToolDetail(name: name, arguments: arguments, output: output, details: details) }
}
