import Foundation

/// A folded run of tool calls, thinking and sent messages, read once for its one-line label:
/// counts of what it did, errors first ("1 error · 6 edits · 3 reads · 2 commands"), and while
/// it runs, what it's doing now.
public struct StepRun: Sendable, Equatable {
    /// Leads the row in red so truncation can't hide it: "1 error", "3 errors".
    public let failure: String?
    /// What the finished part of the run did; empty when a failure says it all.
    public let label: String
    /// The newest running call's title, with the rest of the running calls counted.
    public private(set) var running: String?
    public let images: [TranscriptImage]
    /// Every line the run opens to (calls, thinking, sent messages), counted beside its chevron
    /// when the label's counts don't add up to it (thinking and waits aren't counted there).
    public let steps: Int
    public private(set) var showsSteps = false

    /// `waitingOn`: what a running `wait` is for (working subagents, background commands).
    public init(_ items: [ConversationItem], waitingOn: [String] = []) {
        var tools: [ToolActivity] = []
        var messages = 0
        for item in items {
            switch item {
            case .tool(let tool): tools.append(tool)
            case .peerMessage(_, _, _, true): messages += 1
            default: break
            }
        }
        images = tools.flatMap(\.images)
        steps = items.count

        // A wait fails when a message interrupts it; that's the loop working, not a failure.
        let failed = tools.filter { $0.state == .failed && $0.name != "wait" }
        failure = failed.isEmpty ? nil : Self.count(failed.count, "error")

        let active = tools.filter { $0.state == .running }
        if let latest = active.last {
            if latest.name == "wait" {
                running = waitingOn.first.map { "Waiting on \(Self.brief($0))" + (waitingOn.count > 1 ? " +\(waitingOn.count - 1)" : "") } ?? "Waiting"
            } else {
                let title = latest.kind == .command ? "Running \(Self.brief(latest.summary))" : latest.runningTitle
                running = title + (active.count > 1 ? " +\(active.count - 1)" : "")
            }
        } else {
            running = nil
        }

        let done = tools.filter { $0.state == .succeeded || ($0.state == .failed && $0.name == "wait") }
        var edits = 0, reads = 0, commands = 0, searches = 0
        for tool in done {
            switch tool.kind {
            case .edit: edits += 1
            case .read: if tool.images.isEmpty { reads += 1 }
            case .command: commands += 1
            case .search: searches += 1
            case .other: break
            }
        }
        let readImages = done.filter { $0.kind == .read && !$0.images.isEmpty }.count
        var parts: [String] = []
        if edits > 0 { parts.append(Self.count(edits, "edit")) }
        if reads > 0 { parts.append(Self.count(reads, "read")) }
        if commands > 0 { parts.append(Self.count(commands, "command")) }
        if searches > 0 { parts.append(Self.count(searches, "search", plural: "searches")) }
        if messages > 0 { parts.append(Self.count(messages, "message")) }
        var counted = failed.count + edits + reads + commands + searches + messages + readImages
        if parts.isEmpty, images.isEmpty {
            // Waits say nothing a finished run needs; what they waited for has its own row.
            let shown = done.filter { $0.name != "wait" }
            if shown.count > 1 { parts.append("\(steps) steps"); counted = steps }
            else if let only = shown.first ?? done.first { parts.append(only.title); counted = 1 }
            else if tools.isEmpty { parts.append("Thinking") }
        }
        if !images.isEmpty { parts.append(Self.count(images.count, "image")) }
        label = parts.joined(separator: " · ")
        showsSteps = steps > max(counted, 1)
    }

    /// The run without its running line, for when a pinned line already says what's running.
    public func settled() -> StepRun {
        var run = self
        run.running = nil
        return run
    }

    private static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    /// A command by its name: "npm run bench -- --rps 2000 > soak.log" is "npm run bench".
    static func brief(_ command: String) -> String {
        var words: [Substring] = []
        for word in command.split(separator: " ") {
            if words.count == 3 || word.hasPrefix("-") || word.hasPrefix(">") || word.hasPrefix("2>") || word == "|" || word == "&&" || word == ";" { break }
            words.append(word)
        }
        return words.isEmpty ? command : words.joined(separator: " ")
    }
}

extension ToolActivity {
    public enum Kind: Sendable { case edit, command, read, search, other }

    public var kind: Kind {
        // A summary that is only the tool's name means the call named no target.
        if summary == name { return name == "bash" || name == "eval" ? .command : .other }
        switch name {
        case "edit", "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "Write": return .edit
        // omp's other `://` targets are agents, processes and tool devices, not files.
        case "write": return summary.contains("://") && !summary.hasPrefix("local://") ? .other : .edit
        case "bash", "Bash", "exec_command", "shell", "local_shell", "eval": return .command
        case "read", "Read", "view_image", "fetch", "web_fetch", "WebFetch": return .read
        case "grep", "Grep", "glob", "Glob", "find", "web_search", "WebSearch", "ast_grep": return .search
        default: return .other
        }
    }

    /// The file a read or edit names, without its directories.
    var target: String {
        guard !summary.contains("://") || summary.hasPrefix("local://") else { return summary }
        return summary.split(separator: "/").last.map(String.init) ?? summary
    }

    /// Past tense once done: "Read Transcript.swift", "Edited a.swift", or the command itself.
    public var title: String {
        switch kind {
        case .edit: "Edited \(target)"
        case .read: "Read \(target)"
        case .search: "Searched \(summary)"
        case .command: summary
        case .other: name == "wait" ? waited : process.map { $0.stop ? "Stopped \($0.name)" : "Sent input to \($0.name)" } ?? summary
        }
    }

    /// What it's doing now: "Reading Transcript.swift", "Editing a.swift", or the command itself.
    public var runningTitle: String {
        switch kind {
        case .edit: "Editing \(target)"
        case .read: "Reading \(target)"
        case .search: "Searching \(summary)"
        case .command, .other: name == "wait" ? "Waiting" : process.map { $0.stop ? "Stopping \($0.name)" : "Sending input to \($0.name)" } ?? summary
        }
    }

    /// "Waited for BenchCouncil": omp's wait result heads each job with "### <name> [type] — status".
    private var waited: String {
        let names = (output ?? "").split(separator: "\n").lazy.filter { $0.hasPrefix("### ") }
            .map { $0.dropFirst(4).prefix { $0 != "[" && $0 != "—" }.trimmingCharacters(in: .whitespaces) }
        guard let first = names.first else { return "Waited" }
        let count = names.count
        return count == 1 ? "Waited for \(first)" : "Waited for \(first) +\(count - 1)"
    }

    /// omp's write to `proc://<name>` (input) or `proc://<name>/kill`.
    private var process: (name: String, stop: Bool)? {
        guard name == "write", summary.hasPrefix("proc://") else { return nil }
        let target = summary.dropFirst("proc://".count)
        return target.hasSuffix("/kill") ? (String(target.dropLast("/kill".count)), true) : (String(target), false)
    }
}
