import Foundation

public enum HerdrError: Error, Equatable, Sendable {
    /// No `herdr` executable was found on the host.
    case herdrNotFound
    /// The server answered with an API error.
    case confirmationRequired(String)
    case workspaceGroupCloseRequired(String)
    case api(code: String, message: String)
    case noResponse
    
    /// A line could not be decoded.
    case malformed(String)
}

/// POSIX single-quote escaping for one shell word.
public func shellQuote(_ word: String) -> String {
    if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) {
        return word
    }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// herdr API client over any `CommandRunner` (SSH on device, a local process in tests).
///
/// Every request spawns one `herdr remote-api-bridge`, because the herdr API
/// socket answers exactly one request per connection. Subscriptions and the
/// terminal stream stay open for as long as the caller consumes them.
public actor HerdrClient {
    public let runner: any CommandRunner
    private var herdrPath: String?

    public init(runner: any CommandRunner, herdrPath: String? = nil) {
        self.runner = runner
        self.herdrPath = herdrPath
    }

    // MARK: Discovery

    /// Absolute path of `herdr` on the host. The login shell's PATH comes first;
    /// then the install locations herdr itself probes.
    public func resolveHerdrPath() async throws -> String {
        if let herdrPath { return herdrPath }
        let probe = #"""
            p=$("${SHELL:-/bin/sh}" -lc 'command -v herdr' 2>/dev/null | tail -n 1)
            if [ -z "$p" ]; then
              for c in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr /usr/bin/herdr; do
                [ -x "$c" ] && p=$c && break
              done
            fi
            printf '%s' "$p"
            """#
        let channel = try await runner.exec(Self.posix(probe))
        let path = String(decoding: try await Self.collect(channel), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw HerdrError.herdrNotFound }
        herdrPath = path
        return path
    }

    private func command(_ session: String?, _ args: [String]) async throws -> String {
        var words = [try await resolveHerdrPath()]
        if let session { words += ["--session", session] }
        return (words + args).map(shellQuote).joined(separator: " ")
    }

    // MARK: Requests

    public func sessions() async throws -> [SessionInfo] {
        let channel = try await runner.exec(try await command(nil, ["session", "list", "--json"]))
        let data = try await Self.collect(channel)
        do {
            return try JSONDecoder().decode(SessionList.self, from: Data(data)).sessions
        } catch {
            throw HerdrError.malformed(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    public func ping(session: String) async throws -> Pong {
        try await request("ping", params: EmptyParams(), session: session)
    }

    public func snapshot(session: String) async throws -> Snapshot {
        let result: SnapshotResult = try await request("session.snapshot", params: EmptyParams(), session: session)
        return result.snapshot
    }

    /// Types text into a pane; `submit` presses Enter afterwards.
    public func sendText(_ text: String, pane: String, submit: Bool, session: String) async throws {
        struct Params: Encodable { var pane_id: String; var text: String?; var keys: [String]? }
        let params = Params(pane_id: pane, text: text, keys: submit ? ["enter"] : nil)
        let _: Ignored = try await request("pane.send_input", params: params, session: session)
    }

    public func createWorkspace(label: String?, cwd: String?, session: String) async throws -> WorkspaceCreateResult {
        struct Params: Encodable, Sendable { var label: String?; var cwd: String?; var focus = false }
        return try await request("workspace.create", params: Params(label: label, cwd: cwd), session: session)
    }

    public func createTab(workspaceID: String, label: String?, cwd: String?, session: String) async throws -> TabCreateResult {
        struct Params: Encodable, Sendable { var workspace_id: String; var label: String?; var cwd: String?; var focus = false }
        return try await request("tab.create", params: Params(workspace_id: workspaceID, label: label, cwd: cwd), session: session)
    }

    public func startAgent(name: String, kind: String, paneID: String, args: [String]? = nil, session: String) async throws -> AgentResult {
        struct Params: Encodable, Sendable { var name: String; var kind: String; var pane_id: String; var args: [String]? }
        return try await request("agent.start", params: Params(name: name, kind: kind, pane_id: paneID, args: args), session: session)
    }

    public func agent(named name: String, session: String) async throws -> AgentResult {
        struct Params: Encodable, Sendable { var target: String }
        return try await request("agent.get", params: Params(target: name), session: session)
    }

    public func agent(paneID: String, session: String) async throws -> AgentResult {
        struct Params: Encodable, Sendable { var target: String }
        return try await request("agent.get", params: Params(target: paneID), session: session)
    }

    public func promptAgent(_ target: String, text: String, session: String) async throws -> AgentResult {
        struct Params: Encodable, Sendable { var target: String; var text: String }
        return try await request("agent.prompt", params: Params(target: target, text: text), session: session)
    }

    public func closePane(_ paneID: String, session: String) async throws {
        struct Params: Encodable, Sendable { var pane_id: String }
        let _: CloseResult = try await request("pane.close", params: Params(pane_id: paneID), session: session)
    }

    public func closeTab(_ tabID: String, session: String) async throws {
        struct Params: Encodable, Sendable { var tab_id: String }
        let _: CloseResult = try await request("tab.close", params: Params(tab_id: tabID), session: session)
    }

    public func closeWorkspace(_ workspaceID: String, closeGroup: Bool = false, session: String) async throws {
        struct Params: Encodable, Sendable { var workspace_id: String; var close_group: Bool }
        let _: CloseResult = try await request("workspace.close", params: Params(workspace_id: workspaceID, close_group: closeGroup), session: session)
    }

    /// Sends named keys (`esc`, `ctrl+c`, `up`, `shift+tab`, ...) to a pane.
    public func sendKeys(_ keys: [String], pane: String, session: String) async throws {
        struct Params: Encodable { var pane_id: String; var keys: [String] }
        let _: Ignored = try await request("pane.send_keys", params: Params(pane_id: pane, keys: keys), session: session)
    }

    /// One request/response over a fresh bridge.
    public func request<P: Encodable & Sendable, R: Decodable>(
        _ method: String, params: P, session: String
    ) async throws -> R {
        let channel = try await runner.exec(try await command(session, ["remote-api-bridge"]))
        defer { Task { await channel.close() } }
        try await channel.write(try Self.requestLine(id: "1", method: method, params: params))
        var lines = LineSplitter()
        for try await chunk in channel.output {
            for line in lines.append(chunk) {
                return try Self.decodeResponse(line)
            }
        }
        throw HerdrError.noResponse
    }

    // MARK: Streams

    /// Long-lived event stream. Returns once herdr acknowledges the subscription, so a
    /// snapshot taken afterwards cannot miss a change. Keeps stdin open: herdr ends the
    /// subscription on EOF. Finishes when the bridge dies; the caller reconnects.
    public func events(session: String, subscriptions: [Subscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        struct Params: Encodable, Sendable { var subscriptions: [Subscription] }
        let channel = try await runner.exec(try await command(session, ["remote-api-bridge"]))
        do {
            try await channel.write(try Self.requestLine(id: "events", method: "events.subscribe", params: Params(subscriptions: subscriptions)))
        } catch {
            await channel.close()
            throw error
        }
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        let (ack, ackContinuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        let task = Task {
            var lines = LineSplitter()
            var acknowledged = false
            do {
                for try await chunk in channel.output {
                    for line in lines.append(chunk) {
                        if acknowledged {
                            continuation.yield(try Self.decodeEvent(line))
                        } else {
                            let _: Ignored = try Self.decodeResponse(line)
                            acknowledged = true
                            ackContinuation.yield()
                        }
                    }
                }
                ackContinuation.finish(throwing: HerdrError.noResponse)
                continuation.finish()
            } catch {
                ackContinuation.finish(throwing: error)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await channel.close() }
        }
        do {
            for try await _ in ack { return stream }
            throw HerdrError.noResponse
        } catch {
            continuation.finish()
            throw error
        }
    }

    /// Opens the direct terminal stream of one pane.
    /// `control` takes input ownership (with takeover); otherwise read-only observe.
    /// Either way, EOF on stdin ends the stream on the host.
    public func terminal(pane: String, session: String, cols: Int, rows: Int, control: Bool) async throws -> TerminalSession {
        var args = ["terminal", "session", control ? "control" : "observe", pane]
        if control { args.append("--takeover") }
        args += ["--cols", String(cols), "--rows", String(rows)]
        var line = try await command(session, args)
        if !control {
            // herdr 0.9 `observe` ignores stdin and only exits when a later frame hits a closed
            // pipe, so an idle pane would leak the process. A watcher kills it on EOF instead.
            line = Self.posix("exec 3<&0; \(line) <&- & p=$!; (cat <&3 >/dev/null; kill $p) >/dev/null 2>&1 & exec 3<&-; wait $p")
        }
        return TerminalSession(channel: try await runner.exec(line))
    }

    /// Probes child transcript files with one remote shell command.
    public func childTranscriptStates(_ paths: [String: String]) async throws -> [String: ChildTranscriptState] {
        guard !paths.isEmpty else { return [:] }
        var script = "for spec in"
        for (id, path) in paths { script += " \(shellQuote(id + "|" + path))" }
        script += #"; do id=${spec%%|*}; p=${spec#*|}; if [ -e "$p.tombstone" ]; then printf '%s tombstoned\n' "$id"; elif [ ! -e "$p" ]; then printf '%s missing\n' "$id"; elif tail -c 4096 "$p" | grep -q '"customType":"session_exit"'; then printf '%s exited\n' "$id"; else printf '%s active\n' "$id"; fi; done"#
        let channel = try await runner.exec(Self.posix(script))
        let output = String(decoding: try await Self.collect(channel), as: UTF8.self)
        var result: [String: ChildTranscriptState] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[1] { case "missing": result[String(parts[0])] = .missing; case "active": result[String(parts[0])] = .active; case "exited": result[String(parts[0])] = .exited; case "tombstoned": result[String(parts[0])] = .tombstoned; default: break }
        }
        return result
    }

    /// Runs `script` under `/bin/sh` whatever the user's login shell is (fish, nushell, ...).
    static func posix(_ script: String) -> String {
        "/bin/sh -c " + shellQuote(script)
    }

    // MARK: Wire helpers

    struct EmptyParams: Encodable, Sendable {}
    struct Ignored: Decodable {}

    static func requestLine<P: Encodable>(id: String, method: String, params: P) throws -> [UInt8] {
        Array(try JSONEncoder().encode(WireRequest(id: id, method: method, params: params))) + [0x0A]
    }

    /// herdr pushes `{"event": "tab_renamed", "data": {...}}`, but status changes arrive
    /// already dotted (`pane.agent_status_changed`). `kind` uses the dotted subscription
    /// name so events and subscriptions share one vocabulary.
    static func decodeEvent(_ line: [UInt8]) throws -> HerdrEvent {
        struct Envelope: Decodable { var event: String }
        struct StatusEnvelope: Decodable { var data: HerdrEvent.StatusChange }
        let data = Data(line)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw HerdrError.malformed(String(decoding: line.prefix(200), as: UTF8.self))
        }
        // Every event family (workspace, worktree, tab, pane, layout) is one word.
        var kind = envelope.event
        if !kind.contains("."), let underscore = kind.firstIndex(of: "_") { kind.replaceSubrange(underscore...underscore, with: ".") }
        var event = HerdrEvent(kind: kind)
        if kind == "pane.agent_status_changed" {
            event.statusChange = try? JSONDecoder().decode(StatusEnvelope.self, from: data).data
        }
        return event
    }

    static func decodeResponse<R: Decodable>(_ line: [UInt8]) throws -> R {
        let envelope: WireResponse<R>
        do {
            envelope = try JSONDecoder().decode(WireResponse<R>.self, from: Data(line))
        } catch {
            throw HerdrError.malformed(String(decoding: line.prefix(200), as: UTF8.self))
        }
        if let error = envelope.error {
            switch error.code {
            case "confirmation_required": throw HerdrError.confirmationRequired(error.message)
            case "workspace_group_close_required": throw HerdrError.workspaceGroupCloseRequired(error.message)
            default: throw HerdrError.api(code: error.code, message: error.message)
            }
        }
        guard let result = envelope.result else { throw HerdrError.malformed("response without result") }
        return result
    }

    static func collect(_ channel: any ExecChannel) async throws -> [UInt8] {
        try await channel.closeInput()
        var data: [UInt8] = []
        for try await chunk in channel.output { data += chunk }
        return data
    }
}

private struct WireRequest<P: Encodable>: Encodable {
    var id: String
    var method: String
    var params: P
}

private struct WireResponse<R: Decodable>: Decodable {
    struct APIError: Decodable { var code: String; var message: String }
    var result: R?
    var error: APIError?
}

/// A live `terminal session control|observe` stream.
public struct TerminalSession: Sendable {
    let channel: any ExecChannel

    public var messages: AsyncThrowingStream<TerminalMessage, any Error> {
        let channel = channel
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lines = LineSplitter()
                do {
                    for try await chunk in channel.output {
                        for line in lines.append(chunk) {
                            continuation.yield(try Self.decode(line))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ command: TerminalCommand) async throws {
        try await channel.write(Array(try JSONEncoder().encode(command)) + [0x0A])
    }

    /// Releases input ownership and ends the stream.
    public func close() async {
        try? await send(.release)
        try? await channel.closeInput()
        await channel.close()
    }

    static func decode(_ line: [UInt8]) throws -> TerminalMessage {
        struct Wire: Decodable {
            var type: String
            var seq: UInt64?
            var full: Bool?
            var width: Int?
            var height: Int?
            var bytes: String?
            var reason: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(line)) else {
            throw HerdrError.malformed(String(decoding: line.prefix(200), as: UTF8.self))
        }
        switch wire.type {
        case "terminal.frame":
            guard let seq = wire.seq, let width = wire.width, let height = wire.height,
                  let encoded = wire.bytes, let bytes = Data(base64Encoded: encoded)
            else { throw HerdrError.malformed("terminal.frame missing fields") }
            return .frame(TerminalFrame(seq: seq, full: wire.full ?? false, width: width, height: height, bytes: Array(bytes)))
        case "terminal.closed":
            return .closed(reason: wire.reason)
        default:
            throw HerdrError.malformed("unknown terminal message \(wire.type)")
        }
    }
}

/// Splits a byte stream into newline-terminated lines (newline excluded).
struct LineSplitter {
    private var buffer: [UInt8] = []

    mutating func append(_ chunk: [UInt8]) -> [[UInt8]] {
        buffer += chunk
        var lines: [[UInt8]] = []
        var start = 0
        while let end = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<end]
            if !line.isEmpty { lines.append(Array(line)) }
            start = end + 1
        }
        buffer.removeFirst(start)
        return lines
    }
}
