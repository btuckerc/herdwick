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

    /// The file's bytes from `offset` on, then whatever is appended, on one channel for as
    /// long as the stream is consumed. The remote `tail` dies when the channel closes: it
    /// runs in the background while the shell waits for stdin to reach EOF.
    nonisolated public func followFile(path: String, from offset: Int) -> AsyncThrowingStream<[UInt8], any Error> {
        let script = "tail -c +\(offset + 1) -F \(shellQuote(path)) 2>/dev/null & t=$!; cat >/dev/null; kill $t 2>/dev/null"
        let runner = runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = try await runner.exec(Self.posix(script))
                    await withTaskCancellationHandler {
                        do {
                            for try await chunk in channel.output { continuation.yield(chunk) }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } onCancel: {
                        Task { await channel.close() }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
    /// `CLAUDE_CONFIG_DIR`/`CODEX_HOME` (read from its process on Linux), else the default.
    public func locateTranscript(_ ref: AgentSessionRef, pane: String, session: String) async throws -> TranscriptLocation? {
        guard let format = TranscriptFormat(agent: ref.agent) else { return nil }
        if let path = ref.transcriptPath { return TranscriptLocation(path: path, format: format) }
        let id = ref.value
        guard ref.kind == "id", !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let variable: String, fallback: String, pattern: String
        switch format {
        case .claude: (variable, fallback, pattern) = ("CLAUDE_CONFIG_DIR", "$HOME/.claude", "projects/*/\(id).jsonl")
        case .codex: (variable, fallback, pattern) = ("CODEX_HOME", "$HOME/.codex", "sessions/*/*/*/rollout-*-\(id).jsonl")
        case .omp: return nil
        }
        let pid = (try? await foregroundProcessID(pane: pane, session: session)).map(String.init) ?? ""
        let script = """
        dirs="\(fallback)"; p='\(pid)'
        if [ -n "$p" ] && [ -r "/proc/$p/environ" ]; then
          d=$(tr '\\0' '\\n' < "/proc/$p/environ" | sed -n 's/^\(variable)=//p' | head -n 1)
          [ -n "$d" ] && dirs="$d $dirs"
        fi
        [ -n "${\(variable):-}" ] && dirs="$\(variable) $dirs"
        for d in $dirs; do for f in "$d"/\(pattern); do [ -f "$f" ] && { printf '%s\\n' "$f"; exit 0; }; done; done
        """
        let data = try await Self.collect(try await runner.exec(Self.posix(script)))
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? TranscriptLocation(path: path, format: format) : nil
    }

    func foregroundProcessID(pane: String, session: String) async throws -> Int? {
        struct Params: Encodable, Sendable { let pane_id: String }
        struct Process: Decodable { let pid: Int }
        struct Info: Decodable { let foreground_processes: [Process]? }
        struct Result: Decodable { let process_info: Info }
        let result: Result = try await request("pane.process_info", params: Params(pane_id: pane), session: session)
        return result.process_info.foreground_processes?.first?.pid
    }
}
