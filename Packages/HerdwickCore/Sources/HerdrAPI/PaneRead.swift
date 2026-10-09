import Foundation

public enum PaneReadSource: String, Sendable, Codable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection
}

public struct PaneText: Sendable, Equatable {
    public let text: String
    public let revision: Int?
    public let truncated: Bool
    public init(text: String, revision: Int?, truncated: Bool) {
        self.text = text; self.revision = revision; self.truncated = truncated
    }
}

public struct FileSlice: Sendable, Equatable {
    public let fileSize: Int
    public let offset: Int
    public let bytes: [UInt8]
    public init(fileSize: Int, offset: Int, bytes: [UInt8]) {
        self.fileSize = fileSize; self.offset = offset; self.bytes = bytes
    }
}

extension HerdrClient {
    public func readPane(_ pane: String, session: String, source: PaneReadSource = .visible, lines: Int? = nil,
                         ansi: Bool = false) async throws -> PaneText {
        struct Params: Encodable, Sendable {
            let pane_id: String; let source: PaneReadSource; let lines: Int?; let format: String
        }
        struct Read: Decodable { let text: String; let revision: Int?; let truncated: Bool }
        struct Result: Decodable { let read: Read }
        let params = Params(pane_id: pane, source: source, lines: lines, format: ansi ? "ansi" : "text")
        let result: Result = try await request("pane.read", params: params, session: session)
        return PaneText(text: result.read.text, revision: result.read.revision, truncated: result.read.truncated)
    }

    /// Output that has scrolled off the top of the pane, oldest first, up to `lines` lines.
    /// `recent` ends with the visible screen, which the live stream already shows, so the
    /// visible rows are dropped from its tail. Full-screen apps (alternate screen) have none.
    public func paneHistory(_ pane: String, session: String, lines: Int) async throws -> [[ANSIRun]] {
        async let recent = readPane(pane, session: session, source: .recent, lines: lines, ansi: true)
        async let visible = readPane(pane, session: session, source: .visible)
        let screenRows = try await ANSILines.parse(visible.text).count
        return Array(ANSILines.parse(try await recent.text).dropLast(screenRows))
    }

    /// The pane's size on the host in cells, from its tab layout.
    public func paneSize(_ pane: String, session: String) async throws -> (cols: Int, rows: Int) {
        struct Params: Encodable, Sendable { let pane_id: String }
        struct Rect: Decodable { let width: Int; let height: Int }
        struct Entry: Decodable { let pane_id: String; let rect: Rect }
        struct Layout: Decodable { let panes: [Entry] }
        struct Result: Decodable { let layout: Layout }
        let result: Result = try await request("pane.layout", params: Params(pane_id: pane), session: session)
        guard let rect = result.layout.panes.first(where: { $0.pane_id == pane })?.rect else {
            throw HerdrError.malformed("pane.layout has no \(pane)")
        }
        return (rect.width, rect.height)
    }

    /// A missing file reads as empty: agents such as omp create their transcript on the first message.
    public func readFileTail(path: String, from offset: Int, limit: Int) async throws -> FileSlice {
        let file = shellQuote(path)
        let script = "[ -e \(file) ] || { echo 0; exit 0; }; printf '%s\\n' \"$(wc -c < \(file))\"; tail -c +$((\(offset) + 1)) \(file) | head -c \(limit)"
        let channel = try await runner.exec(Self.posix(script))
        let data = try await Self.collect(channel)
        guard let newline = data.firstIndex(of: 0x0A),
              let size = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HerdrError.malformed("missing file size")
        }
        return FileSlice(fileSize: size, offset: offset, bytes: Array(data[data.index(after: newline)...]))
    }

    /// The file's last `lastBytes` bytes, then whatever is appended, on one channel for as
    /// long as the stream is consumed. The host measures the file and reads its first
    /// `headLimit` bytes (a title line) in the same command, so opening costs one exec.
    /// A valid `resumeOffset` replaces the tail window with just the delta; an offset beyond
    /// the current size falls back to that window. `.opened.start` confirms which was used.
    /// The first event is always `.opened`. The remote `tail` and stdin watcher are reaped
    /// when either exits, or when the channel closes. A missing file opens empty and is
    /// followed once it appears.
    nonisolated public func followFile(path: String, lastBytes: Int, headLimit: Int, resumeOffset: Int? = nil) -> AsyncThrowingStream<FileFollowEvent, any Error> {
        let command = Self.untilInputCloses("""
        { f=\(shellQuote(path)); s=0; [ -r "$f" ] && s=$(wc -c < "$f"); s=$((s)); b=$((s > \(lastBytes) ? s - \(lastBytes) : 0))
        r=\(resumeOffset ?? -1); if [ "$r" -ge 0 ] && [ "$r" -le "$s" ]; then b=$r; fi
        printf '%s %s\\n' "$s" "$b"; [ "$s" -gt 0 ] && head -c \(headLimit) "$f" | base64 | tr -d '\\n'; echo
        exec tail -c +$((b + 1)) -F "$f" 2>/dev/null; }
        """)
        let runner = runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = try await runner.exec(command)
                    await withTaskCancellationHandler {
                        do {
                            var preamble: [UInt8]? = []
                            for try await chunk in channel.output {
                                guard var pending = preamble else {
                                    continuation.yield(.bytes(chunk))
                                    continue
                                }
                                pending += chunk
                                guard let opened = try FileFollowEvent.opened(preamble: &pending) else {
                                    preamble = pending
                                    continue
                                }
                                preamble = nil
                                continuation.yield(opened)
                                if !pending.isEmpty { continuation.yield(.bytes(pending)) }
                            }
                            if preamble != nil { throw HerdrError.malformed("file follow ended before its size") }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } onCancel: {
                        Task { await channel.close() }
                    }
                    await channel.close()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum FileFollowEvent: Sendable, Equatable {
    /// The file's size when the follow began, the offset its `.bytes` start at, and its first bytes.
    case opened(fileSize: Int, start: Int, head: [UInt8])
    case bytes([UInt8])

    /// Parses `<size> <start>\n<base64 head>\n` off the front of `buffer`, leaving what follows;
    /// nil until both lines are in.
    static func opened(preamble buffer: inout [UInt8]) throws -> FileFollowEvent? {
        guard let first = buffer.firstIndex(of: 0x0A),
              let second = buffer[(first + 1)...].firstIndex(of: 0x0A) else { return nil }
        let fields = buffer[..<first].split(separator: 0x20).map { Int(String(decoding: $0, as: UTF8.self)) }
        guard fields.count == 2, let size = fields[0], let start = fields[1],
              let head = Data(base64Encoded: Data(buffer[(first + 1)..<second])) else {
            throw HerdrError.malformed("file follow preamble")
        }
        buffer.removeSubrange(...second)
        return .opened(fileSize: size, start: start, head: Array(head))
    }
}

/// Where an agent's transcript lives and how to read it.
public struct TranscriptLocation: Sendable, Equatable, Hashable {
    public let path: String
    public let format: TranscriptFormat
    public init(path: String, format: TranscriptFormat) { self.path = path; self.format = format }
}

extension HerdrClient {
    /// The transcript file behind `ref`. omp reports a path; Claude Code and Codex report
    /// only a session id, which names a file under their config directory: the agent's own
    /// `CLAUDE_CONFIG_DIR`/`CODEX_HOME` (read from its process on Linux), then the shell's, then the default.
    public func locateTranscript(_ ref: AgentSessionRef, pane: String, session: String) async throws -> TranscriptLocation? {
        try await locateTranscripts([(pane, ref)], session: session)[pane]
    }

    /// `locateTranscript` for several panes, keyed by pane: one host command for all of them.
    public func locateTranscripts(_ items: [(pane: String, ref: AgentSessionRef)], session: String) async throws -> [String: TranscriptLocation] {
        var found: [String: TranscriptLocation] = [:]
        var search: [(pane: String, format: TranscriptFormat, id: String)] = []
        for (pane, ref) in items {
            guard let format = TranscriptFormat(agent: ref.agent) else { continue }
            if let path = ref.transcriptPath {
                found[pane] = TranscriptLocation(path: path, format: format)
                continue
            }
            let id = ref.value
            guard format != .omp, ref.kind == "id", !id.isEmpty,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  !pane.isEmpty, !pane.contains(where: { $0.isWhitespace || $0 == "|" }) else { continue }
            search.append((pane, format, id))
        }
        guard !search.isEmpty else { return found }
        // Two at a time: each request lane carries at most one, so the user's own requests
        // never queue behind this background work for long.
        var pids: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            var remaining = search.makeIterator()
            func next() {
                guard let item = remaining.next() else { return }
                group.addTask { (item.pane, try? await self.foregroundProcessID(pane: item.pane, session: session)) }
            }
            next()
            next()
            for await (pane, pid) in group {
                pids[pane] = pid
                next()
            }
        }
        var script = "for spec in"
        for item in search {
            script += " " + shellQuote("\(item.pane)|\(item.format == .claude ? "claude" : "codex")|\(item.id)|\(pids[item.pane].map(String.init) ?? "")")
        }
        script += """
        ; do
          pane=${spec%%|*}; rest=${spec#*|}; fmt=${rest%%|*}; rest=${rest#*|}; id=${rest%%|*}; p=${rest#*|}
          if [ "$fmt" = claude ]; then var=CLAUDE_CONFIG_DIR own=${CLAUDE_CONFIG_DIR:-} base=$HOME/.claude
          else var=CODEX_HOME own=${CODEX_HOME:-} base=$HOME/.codex; fi
          agent_dir=""
          if [ -n "$p" ] && [ -r "/proc/$p/environ" ]; then
            agent_dir=$(tr '\\0' '\\n' < "/proc/$p/environ" | sed -n "s/^$var=//p" | head -n 1)
          fi
          found=""
          for d in "$agent_dir" "$own" "$base"; do
            [ -n "$d" ] || continue
            if [ "$fmt" = claude ]; then set -- "$d"/projects/*/"$id".jsonl
            else set -- "$d"/sessions/*/*/*/rollout-*-"$id".jsonl; fi
            for f; do [ -f "$f" ] && { found=$f; break; }; done
            [ -n "$found" ] && break
          done
          [ -z "$found" ] || printf '%s %s\\n' "$pane" "$found"
        done
        """
        let output = String(decoding: try await Self.collect(try await runner.exec(Self.posix(script))), as: UTF8.self)
        let formats = Dictionary(search.map { ($0.pane, $0.format) }, uniquingKeysWith: { first, _ in first })
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let pane = String(line[..<space]), path = String(line[line.index(after: space)...])
            if path.hasPrefix("/"), let format = formats[pane] { found[pane] = TranscriptLocation(path: path, format: format) }
        }
        return found
    }

    func foregroundProcessID(pane: String, session: String) async throws -> Int? {
        struct Params: Encodable, Sendable { let pane_id: String }
        struct Process: Decodable { let pid: Int }
        struct Info: Decodable { let foreground_processes: [Process]? }
        struct Result: Decodable { let process_info: Info }
        let result: Result = try await request("pane.process_info", params: Params(pane_id: pane), session: session)
        return result.process_info.foreground_processes?.first?.pid
    }

    /// herdr's own account of how it arrived at an agent's status (`agent.explain`), as
    /// label/value lines for display. Read-only: it never changes the status.
    public func explainAgent(pane: String, session: String) async throws -> [(label: String, value: String)] {
        struct Params: Encodable, Sendable { let target: String }
        struct Explain: Decodable {
            let agent: String?
            let state: String?
            let screen_detection_skipped: Bool?
            let screen_detection_skip_reason: String?
            let fallback_reason: String?
            let skipped_update_reason: String?
            let warning: String?
            let visible_blocker: Bool?
            let visible_working: Bool?
            let visible_idle: Bool?
        }
        struct Result: Decodable { let explain: Explain }
        let e = try await (request("agent.explain", params: Params(target: pane), session: session) as Result).explain
        let screen = [e.visible_blocker == true ? "prompt" : nil, e.visible_working == true ? "working" : nil,
                      e.visible_idle == true ? "idle" : nil].compactMap { $0 }
        let lines: [(String, String?)] = [
            ("Agent", e.agent),
            ("Status", e.state),
            ("Status source", e.screen_detection_skipped == true
                ? "the agent reports it" + (e.screen_detection_skip_reason.map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? "")
                : "herdr reads the screen"),
            ("Screen shows", e.screen_detection_skipped == true ? nil : (screen.isEmpty ? "nothing recognised" : screen.joined(separator: ", "))),
            ("Fallback", e.fallback_reason),
            ("Update skipped", e.skipped_update_reason),
            ("Warning", e.warning),
        ]
        return lines.compactMap { label, value in value.map { (label, $0) } }
    }
}
