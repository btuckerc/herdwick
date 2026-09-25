import Foundation
import HerdrAPI

/// A `CommandRunner` that plays a `DemoScenario` instead of dialling a machine.
///
/// It answers the exact commands `HerdrClient` runs — the path probe, `session list --json`,
/// one-shot `remote-api-bridge` requests, the `events.subscribe` stream and the
/// `terminal session` frame stream — so the app above it runs unmodified.
public final class DemoHost: CommandRunner {
    /// UI steps from the timeline, for the app to perform.
    public let cues: AsyncStream<DemoCue>
    private let engine: DemoEngine

    /// `dropAfterReady` kills the link for good once the app has its first live snapshot,
    /// which holds the UI on its reconnecting state.
    public init(scenario: DemoScenario, dropAfterReady: Bool = false) {
        let (cues, continuation) = AsyncStream<DemoCue>.makeStream()
        self.cues = cues
        engine = DemoEngine(scenario: scenario, cues: continuation, dropAfterReady: dropAfterReady)
    }

    /// Starts the timeline; `t` in the scenario counts from here. Idempotent.
    public func startClock() {
        Task { [engine] in await engine.startClock() }
    }

    public func exec(_ command: String) async throws -> any ExecChannel {
        try await engine.open(command)
    }
}

private actor DemoEngine {
    private let scenario: DemoScenario
    private let cues: AsyncStream<DemoCue>.Continuation
    private let dropAfterReady: Bool

    private var snapshot: [String: Any]
    private var screens: [String: String]
    private var clockStarted = false
    private var dropped = false
    private var dropScheduled = false

    private enum Role {
        case bridge
        case events
        case terminal(pane: String, cols: Int, rows: Int, seq: UInt64)
    }

    private struct Open {
        var channel: DemoChannel
        var role: Role
        var pending: [UInt8] = []
    }

    private var channels: [ObjectIdentifier: Open] = [:]

    init(scenario: DemoScenario, cues: AsyncStream<DemoCue>.Continuation, dropAfterReady: Bool) {
        self.scenario = scenario
        self.cues = cues
        self.dropAfterReady = dropAfterReady
        var snapshot = (try? JSONSerialization.jsonObject(with: scenario.snapshotJSON) as? [String: Any]) ?? [:]
        var screens = scenario.screens
        for action in scenario.setup {
            switch action {
            case .status(let pane, let status): Self.apply(status, pane: pane, to: &snapshot)
            case .screen(let pane, let path): screens[pane] = path
            case .cue, .drop: break
            }
        }
        self.snapshot = snapshot
        self.screens = screens
    }

    // MARK: Commands

    func open(_ command: String) throws -> any ExecChannel {
        if dropped { throw CommandError.channelClosed }
        let channel = DemoChannel(engine: self)
        if command.contains("command -v herdr") {
            channel.send("/usr/local/bin/herdr")
            channel.finish()
        } else if command.contains(" session list --json") {
            channel.send(scenario.sessionsJSON)
            channel.finish()
        } else if command.contains(" remote-api-bridge") {
            channels[channel.id] = Open(channel: channel, role: .bridge)
        } else if let terminal = Self.terminalRequest(command) {
            channels[channel.id] = Open(channel: channel, role: .terminal(pane: terminal.pane, cols: terminal.cols, rows: terminal.rows, seq: 0))
            paint(channel.id)
        } else {
            channel.finish(throwing: CommandError.exited(status: 127, stderr: "demo host: unsupported command"))
        }
        return channel
    }

    /// `terminal session control|observe <pane> ... --cols N --rows M`, possibly shell-wrapped.
    private static func terminalRequest(_ command: String) -> (pane: String, cols: Int, rows: Int)? {
        func word(after marker: String) -> Substring? {
            guard let range = command.range(of: marker) else { return nil }
            return command[range.upperBound...].split(separator: " ").first
        }
        guard let pane = word(after: " terminal session control ") ?? word(after: " terminal session observe "),
              let cols = word(after: " --cols ").flatMap({ Int($0) }),
              let rows = word(after: " --rows ").flatMap({ Int($0.prefix { $0.isNumber }) })
        else { return nil }
        return (String(pane), cols, rows)
    }

    func received(_ bytes: [UInt8], on id: ObjectIdentifier) {
        guard var open = channels[id] else { return }
        open.pending += bytes
        var lines: [[UInt8]] = []
        while let newline = open.pending.firstIndex(of: 0x0A) {
            lines.append(Array(open.pending[..<newline]))
            open.pending.removeSubrange(...newline)
        }
        channels[id] = open
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch open.role {
            case .bridge: request(object, on: id)
            case .events: break
            case .terminal: terminalCommand(object, on: id)
            }
        }
    }

    func inputClosed(_ id: ObjectIdentifier) {
        // herdr ends subscriptions and terminal streams on stdin EOF; one-shot bridges
        // have already answered.
        guard let open = channels.removeValue(forKey: id) else { return }
        open.channel.finish()
    }

    // MARK: API requests

    private func request(_ object: [String: Any], on id: ObjectIdentifier) {
        guard let open = channels[id] else { return }
        let requestID = object["id"] as? String ?? "1"
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        func reply(_ result: Any) {
            open.channel.send(["id": requestID, "result": result])
        }
        switch method {
        case "ping":
            reply(["version": scenario.version, "protocol": scenario.protocolVersion])
        case "session.snapshot":
            reply(["snapshot": snapshot])
            if dropAfterReady, !dropScheduled, channels.values.contains(where: { if case .events = $0.role { true } else { false } }) {
                dropScheduled = true
                schedule([TimedStep(at: 0.3, action: .drop(nil))])
            }
        case "events.subscribe":
            reply(["subscribed": true])
            channels[id]?.role = .events
            return
        case "pane.read":
            let pane = params["pane_id"] as? String ?? ""
            let markup = screens[pane].flatMap { scenario.screenFiles[$0] } ?? ""
            let text = ScreenMarkup.text(markup, cols: 80, rows: 40).joined(separator: "\n")
            reply(["read": ["text": text, "revision": 1, "truncated": false] as [String: Any]])
        case "pane.send_input", "pane.send_keys":
            reply([String: Any]())
            let pane = params["pane_id"] as? String
            for trigger in scenario.triggers where trigger.method == method && (trigger.pane == nil || trigger.pane == pane) {
                schedule(trigger.then)
            }
        default:
            open.channel.send(["id": requestID, "error": ["code": "unsupported", "message": "demo host: \(method)"]])
        }
        channels[id] = nil
        open.channel.finish()
    }

    // MARK: Terminal

    private func terminalCommand(_ object: [String: Any], on id: ObjectIdentifier) {
        guard case .terminal(let pane, _, _, let seq) = channels[id]?.role else { return }
        switch object["type"] as? String {
        case "terminal.resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { return }
            channels[id]?.role = .terminal(pane: pane, cols: cols, rows: rows, seq: seq)
            paint(id)
        case "terminal.release":
            inputClosed(id)
        default:
            // Keystrokes into the scripted screen go nowhere, as with a paused process.
            break
        }
    }

    private func paint(_ id: ObjectIdentifier) {
        guard let open = channels[id], case .terminal(let pane, let cols, let rows, let seq) = open.role else { return }
        let markup = screens[pane].flatMap { scenario.screenFiles[$0] } ?? ""
        let bytes = ScreenMarkup.render(markup, cols: cols, rows: rows)
        channels[id]?.role = .terminal(pane: pane, cols: cols, rows: rows, seq: seq + 1)
        open.channel.send([
            "type": "terminal.frame", "seq": seq + 1, "full": true, "width": cols, "height": rows,
            "bytes": Data(bytes).base64EncodedString(),
        ])
    }

    // MARK: Timeline

    func startClock() {
        guard !clockStarted else { return }
        clockStarted = true
        schedule(scenario.timeline)
    }

    private func schedule(_ steps: [TimedStep]) {
        let start = ContinuousClock.now
        Task {
            for step in steps.sorted(by: { $0.at < $1.at }) {
                try? await Task.sleep(until: start + .milliseconds(Int(step.at * 1000)), clock: .continuous)
                run(step.action)
            }
        }
    }

    private func run(_ action: Action) {
        switch action {
        case .status(let pane, let status):
            setStatus(status, pane: pane)
        case .screen(let pane, let path):
            screens[pane] = path
            for (id, open) in channels {
                if case .terminal(pane, _, _, _) = open.role { paint(id) }
            }
        case .cue(let cue):
            cues.yield(cue)
        case .drop(let seconds):
            dropped = true
            for open in channels.values { open.channel.finish() }
            channels = [:]
            if let seconds {
                Task {
                    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                    self.reconnect()
                }
            }
        }
    }

    private func reconnect() { dropped = false }

    private func setStatus(_ status: AgentStatus, pane: String) {
        guard let workspace = Self.apply(status, pane: pane, to: &snapshot) else { return }
        let event: [String: Any] = [
            "event": "pane_agent_status_changed",
            "data": ["pane_id": pane, "workspace_id": workspace, "agent_status": status.rawValue],
        ]
        for open in channels.values {
            if case .events = open.role { open.channel.send(event) }
        }
    }

    /// Updates the pane and its agent and re-derives the tab and workspace roll-ups the way
    /// herdr does (the status that needs the user most wins). Returns the pane's workspace.
    @discardableResult
    private static func apply(_ status: AgentStatus, pane: String, to snapshot: inout [String: Any]) -> String? {
        var panes = snapshot["panes"] as? [[String: Any]] ?? []
        guard let index = panes.firstIndex(where: { $0["pane_id"] as? String == pane }) else { return nil }
        panes[index]["agent_status"] = status.rawValue
        panes[index]["revision"] = (panes[index]["revision"] as? Int ?? 0) + 1
        snapshot["panes"] = panes

        snapshot["agents"] = (snapshot["agents"] as? [[String: Any]] ?? []).map { agent in
            guard agent["pane_id"] as? String == pane else { return agent }
            var agent = agent
            agent["agent_status"] = status.rawValue
            agent["state_change_seq"] = (agent["state_change_seq"] as? Int ?? 0) + 1
            return agent
        }
        for (key, idKey) in [("tabs", "tab_id"), ("workspaces", "workspace_id")] {
            snapshot[key] = (snapshot[key] as? [[String: Any]] ?? []).map { item in
                var item = item
                let members = panes.filter { $0[idKey] as? String == item[idKey] as? String }
                let statuses = members.compactMap { ($0["agent_status"] as? String).flatMap(AgentStatus.init(rawValue:)) }
                if let top = statuses.min(by: { $0.attentionRank < $1.attentionRank }) { item["agent_status"] = top.rawValue }
                return item
            }
        }
        return panes[index]["workspace_id"] as? String
    }
}

/// One scripted command: stdout is fed by the engine, stdin goes back to it.
private final class DemoChannel: ExecChannel {
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let engine: DemoEngine
    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(engine: DemoEngine) {
        self.engine = engine
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ text: String) {
        continuation.yield(Array(text.utf8))
    }

    func send(_ data: Data) {
        continuation.yield(Array(data))
    }

    /// One NDJSON line.
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        continuation.yield(Array(data) + [0x0A])
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }

    func write(_ bytes: [UInt8]) async throws {
        await engine.received(bytes, on: id)
    }

    func closeInput() async throws {
        await engine.inputClosed(id)
    }

    func close() async {
        await engine.inputClosed(id)
        continuation.finish()
    }
}
