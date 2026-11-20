import Foundation

/// A folded run of tool calls, thinking and sent messages, read once for its one-line label:
/// what it did, errors first, one of a kind named and more counted ("1 error · Edited a.swift ·
/// 3 reads · Ran swift test"), and while it runs, what it's doing now.
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
    /// The newest settled test run's totals, as its own output reports them; nil when no
    /// command in the run was a test run or its output gave no totals.
    public let tests: TestTally?
    /// What every call in the run was, for its symbol: one kind, else nil (mixed, or nothing
    /// but thinking and messages). A run of only waits is `.wait`.
    public let sole: Sole?
    public enum Sole: Sendable, Equatable { case kind(ToolActivity.Kind), wait }

    /// `awaitingApproval` replaces the running verb while a user-facing choice is pending.
    public init(_ items: [ConversationItem], waitingOn: [String] = [], awaitingApproval: Bool = false) {
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
        let kinds = Set(tools.filter { $0.name != "wait" }.map(\.kind))
        sole = tools.isEmpty ? nil
            : kinds.isEmpty ? .wait
            : kinds.count == 1 && messages == 0 ? kinds.first.map(Sole.kind) : nil
        steps = items.count

        // A wait fails when a message interrupts it; that's the loop working, not a failure.
        let failed = tools.filter { $0.state == .failed && $0.name != "wait" }
        failure = failed.isEmpty ? nil : Self.count(failed.count, "error")

        let active = tools.filter { $0.state == .running }
        if let latest = active.last {
            if latest.name == "wait" {
                running = waitingOn.first.map { "Waiting on \(Self.brief($0))" + (waitingOn.count > 1 ? " +\(waitingOn.count - 1)" : "") } ?? "Waiting"
            } else {
                let detail = latest.kind == .command ? Self.brief(latest.summary) : latest.runningTitle
                let title = awaitingApproval ? "Waiting for approval · \(detail)"
                    : latest.kind == .command ? "Running \(detail)" : latest.runningTitle
                running = title + (active.count > 1 ? " +\(active.count - 1)" : "")
            }
        } else {
            running = nil
        }

        // The newest settled test command's own totals, or none when it printed none: an
        // older run's tally would speak for a newer one (round 9).
        tests = tools.last { $0.kind == .command && $0.state != .running && TestTally.namesTests($0.summary) }
            .flatMap { TestTally(command: $0.summary, output: $0.output) }
        let done = tools.filter { $0.state == .succeeded || ($0.state == .failed && $0.name == "wait") }
        let edits = done.filter { $0.kind == .edit }
        let reads = done.filter { $0.kind == .read && $0.images.isEmpty }
        let commands = done.filter { $0.kind == .command }
        let searches = done.filter { $0.kind == .search }
        let readImages = done.filter { $0.kind == .read && !$0.images.isEmpty }.count
        var parts: [String] = []
        if tests != nil {
            // With an outcome, filenames and commands obscure the result (round 20: the
            // outcome joined an unrelated "Read …" into one sentence and truncated).
            let otherCommands = commands.filter { !TestTally.namesTests($0.summary) }
            if !edits.isEmpty { parts.append(Self.count(edits.count, "edit")) }
            if !otherCommands.isEmpty { parts.append(Self.count(otherCommands.count, "command")) }
            if !reads.isEmpty { parts.append(Self.count(reads.count, "read")) }
            if !searches.isEmpty { parts.append(Self.count(searches.count, "search", plural: "searches")) }
        } else {
            // One of a kind is named ("Ran swift build", "Edited a.swift": edits of one file count as
            // one); more are counted, so a long run's line still adds up at a glance.
            let editedFiles = Set(edits.map(\.target))
            if editedFiles.count == 1, let only = edits.first { parts.append(only.title) }
            else if !edits.isEmpty { parts.append(Self.count(edits.count, "edit")) }
            if reads.count == 1 { parts.append(reads[0].title) } else if !reads.isEmpty { parts.append(Self.count(reads.count, "read")) }
            // omp's eval summary is its title ("Compare runs"), not a command line. A command sent
            // to the background whose output hasn't come back was started, not run.
            if commands.count == 1 {
                let only = commands[0]
                parts.append(only.name == "eval" ? only.summary
                    : waitingOn.contains(only.summary) ? "Started \(Self.brief(only.summary)) · Background"
                    : "Ran \(Self.brief(only.summary))")
            }
            else if !commands.isEmpty { parts.append(Self.count(commands.count, "command")) }
            if searches.count == 1 { parts.append(searches[0].title) }
            else if !searches.isEmpty { parts.append(Self.count(searches.count, "search", plural: "searches")) }
        }
        if messages > 0 { parts.append(Self.count(messages, "message")) }
        var counted = failed.count + edits.count + reads.count + commands.count + searches.count + messages + readImages
        // A lone test run's outcome is its whole line (the view puts the totals first).
        if parts.isEmpty, images.isEmpty, tests == nil {
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

    /// A command by its name: "npm run bench -- --rps 2000 > soak.log" is "npm run bench", and a
    /// path names its file: "bun test src/charts/move.test.ts" is "bun test move.test.ts" (round
    /// 11: on one line the directories crowded out the file; opening the run shows it whole). A
    /// launcher that only runs another program ("uv run", "npx") doesn't count toward the three
    /// words: "uv run pipeline backfill --month 2026-03" is "uv run pipeline backfill" (round
    /// 16: "uv run pipeline" left out what it was doing).
    static func brief(_ command: String) -> String {
        let all = command.split(separator: " ")
        let launcher = all.first.map { ["uvx", "npx", "bunx"].contains($0) } == true ? 1
            : all.count > 1 && [["uv", "run"], ["poetry", "run"], ["pipx", "run"], ["pnpm", "exec"]].contains(Array(all.prefix(2))) ? 2 : 0
        var words: [Substring] = []
        for word in all {
            if words.count == 3 + launcher || word.hasPrefix("-") || word.hasPrefix(">") || word.hasPrefix("2>") || word == "|" || word == "&&" || word == ";" { break }
            words.append(word.contains("://") ? word : word.split(separator: "/").last ?? word)
        }
        return words.isEmpty ? command : words.joined(separator: " ")
    }
}

/// A test run's totals, read off the end of its output: "12 passed", "1 failed" (bun, jest,
/// vitest, mocha, pytest, XCTest's "0 failures"). Only for a command that names tests, and
/// only what the output says: a run that prints no totals has none, and neither does one cut
/// at the transcript's 200 lines, whose end (where totals print) isn't there.
public struct TestTally: Sendable, Equatable {
    public let passed: Int?
    public let failed: Int?

    /// Whether a command names tests ("bun test", "npx jest", "swift test").
    public static func namesTests(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return ["test", "spec", "jest", "mocha"].contains(where: lowered.contains)
    }

    public init?(command: String, output: String?) {
        guard let output, Self.namesTests(command),
              output.count(where: { $0 == "\n" }) < 199 else { return nil }
        let tail = String(output.suffix(4000)).lowercased()
        passed = tail.matches(of: /(\d+)\s+(?:tests?\s+)?(?:passed|passing|pass)\b/).last.flatMap { Int($0.1) }
        failed = tail.matches(of: /(\d+)\s+(?:tests?\s+)?(?:failed|failing|fail|failures?)\b/).last.flatMap { Int($0.1) }
        guard passed != nil || failed != nil else { return nil }
    }

    /// "3 tests failed" when any did, else "12 tests passed", else "No failures".
    public var summary: String {
        if let failed, failed > 0 { return "\(failed) tests failed" }
        if let passed { return "\(passed) tests passed" }
        return "No failures"
    }

    public var anyFailed: Bool { (failed ?? 0) > 0 }
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
        let names = waitedFor
        guard let first = names.first else { return "Waited" }
        return names.count == 1 ? "Waited for \(first)" : "Waited for \(first) +\(names.count - 1)"
    }

    /// The agents a settled wait waited for, in its output's order; empty for any other call.
    public var waitedFor: [String] {
        guard name == "wait" else { return [] }
        return (output ?? "").split(separator: "\n").filter { $0.hasPrefix("### ") }
            .map { $0.dropFirst(4).prefix { $0 != "[" && $0 != "—" }.trimmingCharacters(in: .whitespaces) }
    }

    /// omp's write to `proc://<name>` (input) or `proc://<name>/kill`.
    private var process: (name: String, stop: Bool)? {
        guard name == "write", summary.hasPrefix("proc://") else { return nil }
        let target = summary.dropFirst("proc://".count)
        return target.hasSuffix("/kill") ? (String(target.dropLast("/kill".count)), true) : (String(target), false)
    }
}
