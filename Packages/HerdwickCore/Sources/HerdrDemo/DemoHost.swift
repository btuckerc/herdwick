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

    /// `dropAfterReady` kills the link for good shortly after the first transcript is served,
    /// or after a fallback delay if the scene never opens a transcript.
    public init(scenario: DemoScenario, dropAfterReady: Bool = false, scriptedReplyDelay: Duration = .seconds(3.5)) {
        let (cues, continuation) = AsyncStream<DemoCue>.makeStream()
        self.cues = cues
        engine = DemoEngine(scenario: scenario, cues: continuation, dropAfterReady: dropAfterReady, scriptedReplyDelay: scriptedReplyDelay)
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
    private let scriptedReplyDelay: Duration

    private var nextDemoID = 1
    private var snapshot: [String: Any]
    private var screens: [String: String]
    private var transcripts: [String: Data]
    private var screenOverrides: [String: String] = [:]
    private var clockStarted = false
    private var dropped = false
    private var dropScheduled = false
    private var transcriptFollowOpened = false

    private enum Role {
        case bridge
        /// `BridgeLane`: every request answered, each followed by its status line.
        case lane
        case events
        case terminal(pane: String, cols: Int, rows: Int, seq: UInt64)
        case file(path: String, offset: Int)
    }

    private struct Open {
        var channel: DemoChannel
        var role: Role
        var pending: [UInt8] = []
    }

    private var channels: [ObjectIdentifier: Open] = [:]

    init(scenario: DemoScenario, cues: AsyncStream<DemoCue>.Continuation, dropAfterReady: Bool, scriptedReplyDelay: Duration) {
        self.scenario = scenario
        self.cues = cues
        self.dropAfterReady = dropAfterReady
        self.scriptedReplyDelay = scriptedReplyDelay
        let now = Date()
        var snapshot = (try? JSONSerialization.jsonObject(with: scenario.snapshotJSON) as? [String: Any]) ?? [:]
        var screens = scenario.screens
        var transcripts = Dictionary(uniqueKeysWithValues: scenario.transcripts.map {
            (DemoScenario.transcriptPath($0.key), Self.timestamped(scenario.transcriptFiles[$0.value] ?? Data(), pane: $0.key, now: now))
        })
        for (pane, children) in scenario.childTranscripts {
            for (id, file) in children {
                if let path = SubagentTranscript.path(parentPath: DemoScenario.transcriptPath(pane), format: .omp, subagentID: id) {
                    transcripts[path] = Self.timestamped(scenario.transcriptFiles[file] ?? Data(), pane: pane, now: now)
                }
            }
        }
        snapshot["agents"] = (snapshot["agents"] as? [[String: Any]] ?? []).map { agent in
            var agent = agent
            if let pane = agent["pane_id"] as? String, scenario.transcripts[pane] != nil {
                agent["agent_session"] = ["source": "herdr:omp", "agent": "omp", "kind": "path", "value": DemoScenario.transcriptPath(pane)]
            }
            return agent
        }
        for action in scenario.setup {
            switch action {
            case .status(let pane, let status): Self.apply(status, pane: pane, to: &snapshot)
            case .screen(let pane, let path): screens[pane] = path
            case .append(let pane, let path): transcripts[DemoScenario.transcriptPath(pane), default: Data()].append(Self.timestamped(scenario.transcriptFiles[path] ?? Data(), pane: pane, now: now))
            case .cue, .drop: break
            }
        }
        self.snapshot = snapshot
        self.screens = screens
        self.transcripts = transcripts
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
        } else if command.contains("HERDWICK_REQUEST") {
            channels[channel.id] = Open(channel: channel, role: .lane)
            Self.askForEmbeddedRequest(command, on: channel)
        } else if command.contains(" remote-api-bridge") {
            channels[channel.id] = Open(channel: channel, role: .bridge)
            Self.askForEmbeddedRequest(command, on: channel)
        } else if let terminal = Self.terminalRequest(command) {
            channels[channel.id] = Open(channel: channel, role: .terminal(pane: terminal.pane, cols: terminal.cols, rows: terminal.rows, seq: 0))
            paint(channel.id)
        } else if let request = Self.fileRequest(command) {
            switch request {
            case .read(let path, let offset, let limit):
                let data = transcripts[path] ?? Data()
                channel.send("\(data.count)\n")
                channel.send(Data(data.dropFirst(offset).prefix(limit)))
                channel.finish()
            case .follow(let path, let lastBytes, let headLimit, let resumeOffset):
                let data = transcripts[path] ?? Data()
                let start = resumeOffset >= 0 && resumeOffset <= data.count ? resumeOffset : max(0, data.count - lastBytes)
                channel.send("\(data.count) \(start)\n\(Data(data.prefix(headLimit)).base64EncodedString())\n")
                if data.count > start { channel.send(Data(data.dropFirst(start))) }
                channels[channel.id] = Open(channel: channel, role: .file(path: path, offset: data.count))
                if dropAfterReady, !transcriptFollowOpened {
                    transcriptFollowOpened = true
                    scheduleDrop(after: .milliseconds(300), fallback: false)
                }
            }
        } else if command.contains("for spec in"), command.contains("p.tombstone") {
            let script = command.replacingOccurrences(of: "'\\''", with: "'")
            let regex = try NSRegularExpression(pattern: #"'([^'|]+)\|([^']+)'"#)
            for match in regex.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
                guard let idRange = Range(match.range(at: 1), in: script),
                      let pathRange = Range(match.range(at: 2), in: script) else { continue }
                let path = String(script[pathRange])
                let state: String
                if let data = transcripts[path] {
                    state = String(decoding: data.suffix(4096), as: UTF8.self).contains("\"customType\":\"session_exit\"") ? "exited" : "active"
                } else { state = "missing" }
                channel.send("\(script[idRange]) \(state)\n")
            }
            channel.finish()
        } else if command.contains("for spec in"), command.contains("| base64") {
            // `HerdrClient.readChunks`: `index|from|limit|path` per file.
            let script = command.replacingOccurrences(of: "'\\''", with: "'")
            let regex = try NSRegularExpression(pattern: #"'(\d+)\|(-?\d+)\|(\d+)\|([^']+)'"#)
            for match in regex.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
                let parts = (1...4).compactMap { Range(match.range(at: $0), in: script).map { String(script[$0]) } }
                guard parts.count == 4, let from = Int(parts[1]), let limit = Int(parts[2]) else { continue }
                guard let data = transcripts[parts[3]] else {
                    channel.send("\(parts[0]) -\n")
                    continue
                }
                let start = from < 0 ? max(0, data.count - limit) : from
                let bytes = start < data.count ? Data(data.dropFirst(start).prefix(limit)) : Data()
                channel.send("\(parts[0]) \(data.count) \(start) \(bytes.base64EncodedString())\n")
            }
            channel.finish()
        } else {
            channel.finish(throwing: CommandError.exited(status: 127, stderr: "demo host: unsupported command"))
        }
        return channel
    }

    /// A `fallback` drop (no transcript yet) stands down if one opens before it fires; that
    /// transcript's own drop follows it, so a slow open is never cut off before it renders.
    private func scheduleDrop(after delay: Duration, fallback: Bool) {
        guard !fallback || !dropScheduled else { return }
        dropScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.drop(fallback: fallback)
        }
    }

    private func drop(fallback: Bool) {
        guard !dropped, !(fallback && transcriptFollowOpened) else { return }
        schedule([TimedStep(at: 0, action: .drop(nil))])
    }

    /// Like a host without perl: a request carried in the command line is asked for again on stdin.
    private static func askForEmbeddedRequest(_ command: String, on channel: DemoChannel) {
        guard let range = command.range(of: "herdwick_first="),
              command[range.upperBound...].first?.isHexDigit == true else { return }
        channel.send("\u{1E}r\n")
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

    private enum FileRequest {
        case read(path: String, offset: Int, limit: Int)
        case follow(path: String, lastBytes: Int, headLimit: Int, resumeOffset: Int)
    }

    /// Decode only the shell forms emitted by PaneRead, never execute scenario commands.
    private static func fileRequest(_ command: String) -> FileRequest? {
        let prefix = "/bin/sh -c '"
        guard command.hasPrefix(prefix), command.hasSuffix("'") else { return nil }
        let script = String(command.dropFirst(prefix.count).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        func capture(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: script).map { String(script[$0]) } }
        }
        if let parts = capture(#"tail -c \+\$\(\((\d+) \+ 1\)\) (\S+) \| head -c (\d+)$"#),
           let offset = Int(parts[0]), let limit = Int(parts[2]) {
            return .read(path: parts[1], offset: offset, limit: limit)
        }
        if let parts = capture(#"\{ f=(\S+); s=0; .*\(\(s > (\d+) \? [\s\S]*r=(-?\d+);[\s\S]* head -c (\d+) "\$f""#),
           let lastBytes = Int(parts[1]), let resumeOffset = Int(parts[2]), let headLimit = Int(parts[3]) {
            return .follow(path: parts[0], lastBytes: lastBytes, headLimit: headLimit, resumeOffset: resumeOffset)
        }
        return nil
    }

    /// Rebases timestamps into the pane's age while preserving record order and never placing
    /// an event after `now`; live appends land at the current time.
    private static func timestamped(_ data: Data, pane: String, now: Date, live: Bool = false) -> Data {
        let age: TimeInterval
        switch pane {
        case _ where live: age = 0
        case "p1": age = 4 * 60
        case "p2": age = 45 * 60
        // Its screen reads "Working (6m 40s …)" from the request, 20 s before the run.
        case "p3": age = 6 * 60 + 20
        case "p4": age = 90 * 60
        case "p5": age = 25
        case "p7": age = 3 * 60 * 60
        default: age = 90
        }
        let end = now.addingTimeInterval(-age)
        func date(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
                ?? (try? Date.ISO8601FormatStyle().parse(string))
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let records = lines.map { line in
            line.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let shift = records.compactMap { date($0?["timestamp"]) }.max().map { end.timeIntervalSince($0) } ?? 0
        var previous: Date?
        return Data(zip(lines, records).map { line, record -> String in
            guard var record else { return String(line) }
            if let stamp = date(record["timestamp"]) {
                let rebased = min(end, stamp.addingTimeInterval(shift))
                let ordered = max(previous ?? rebased, rebased)
                // Fractional seconds: whole ones could land a live append before a decision
                // made a second and a half earlier ("Took …" then had nothing to count).
                record["timestamp"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(ordered)
                previous = ordered
            } else if record["type"] as? String == "message" {
                let stamp = min(end, previous ?? end)
                record["timestamp"] = ISO8601DateFormatter().string(from: stamp)
                previous = stamp
            } else {
                return String(line)
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  let result = String(data: encoded, encoding: .utf8) else { return String(line) }
            return result
        }.joined(separator: "\n").utf8)
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
            case .bridge, .lane: request(object, on: id)
            case .events, .file: break
            case .terminal: terminalCommand(object, on: id)
            }
        }
    }

    func inputClosed(_ id: ObjectIdentifier) {
        // herdr ends subscriptions and terminal streams on stdin EOF, and a lane's loop ends;
        // one-shot bridges have already answered.
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
                scheduleDrop(after: .seconds(5), fallback: true)
            }
        case "events.subscribe":
            reply(["subscribed": true])
            channels[id]?.role = .events
            return
        case "pane.read":
            let pane = params["pane_id"] as? String ?? ""
            let markup = screenOverrides[pane] ?? screens[pane].flatMap { scenario.screenFiles[$0] } ?? ""
            let text = ScreenMarkup.text(markup, cols: 80, rows: 40).joined(separator: "\n")
            reply(["read": ["text": text, "revision": 1, "truncated": false] as [String: Any]])
        case "pane.send_input", "pane.send_keys":
            reply([String: Any]())
            let pane = params["pane_id"] as? String
            // An agent started from New Agent answers with a canned reply; the scenario's own
            // panes keep their scripted triggers.
            if let pane, pane.hasPrefix("demo-pane-"), method == "pane.send_input", let text = params["text"] as? String {
                scriptReply(to: text, pane: pane)
                answered(open, on: id)
                return
            }
            if let pane, method == "pane.send_keys", let keys = params["keys"] as? [String],
               let markup = screenOverrides[pane] ?? screens[pane].flatMap({ scenario.screenFiles[$0] }),
               ScreenPrompt.parse(ScreenMarkup.text(markup, cols: 80, rows: 40).joined(separator: "\n"))?.style == .ompAsk {
                movePrompt(keys, pane: pane)
                if !keys.contains("enter") {
                    answered(open, on: id)
                    return
                }
            }
            for trigger in scenario.triggers where trigger.method == method && (trigger.pane == nil || trigger.pane == pane) {
                schedule(trigger.then)
            }
        case "pane.close":
            let pane = params["pane_id"] as? String ?? ""
            for key in ["panes", "agents"] {
                snapshot[key] = (snapshot[key] as? [[String: Any]] ?? []).filter { $0["pane_id"] as? String != pane }
            }
            reply(["pane_id": pane])
            broadcast("pane_closed", ["pane_id": pane])
        case "pane.rename":
            let pane = params["pane_id"] as? String ?? ""
            var panes = snapshot["panes"] as? [[String: Any]] ?? []
            if let index = panes.firstIndex(where: { $0["pane_id"] as? String == pane }) {
                let label = (params["label"] as? String)?.trimmingCharacters(in: .whitespaces)
                panes[index]["label"] = label?.isEmpty == false ? label : nil
                snapshot["panes"] = panes
                reply(["type": "pane_info", "pane": panes[index]])
                broadcast("pane_updated", ["pane": panes[index]])
            } else {
                open.channel.send(["id": requestID, "error": ["code": "pane_not_found", "message": "pane \(pane) not found"]])
            }
        case "tab.create":
            let workspaceID = params["workspace_id"] as? String ?? ""
            guard let workspace = (snapshot["workspaces"] as? [[String: Any]] ?? []).first(where: { $0["workspace_id"] as? String == workspaceID }) else {
                open.channel.send(["id": requestID, "error": ["code": "workspace_not_found", "message": "workspace not found"]])
                break
            }
            let tabID = "demo-tab-\(nextDemoID)", paneID = "demo-pane-\(nextDemoID)"
            nextDemoID += 1
            let tabs = snapshot["tabs"] as? [[String: Any]] ?? []
            let number = tabs.filter { $0["workspace_id"] as? String == workspaceID }.count + 1
            let tab: [String: Any] = ["tab_id": tabID, "workspace_id": workspaceID, "number": number,
                                      "label": params["label"] as? String ?? "Tab \(number)", "focused": false, "agent_status": "idle"]
            let pane: [String: Any] = ["pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": false,
                                       "agent_status": "idle", "cwd": params["cwd"] as? String ?? workspace["cwd"] as? String ?? "",
                                       "revision": 1]
            snapshot["tabs"] = tabs + [tab]
            snapshot["panes"] = (snapshot["panes"] as? [[String: Any]] ?? []) + [pane]
            reply(["tab": tab, "root_pane": pane])
            broadcast("pane_created", ["pane": pane])
        case "workspace.create":
            let workspaceID = "demo-workspace-\(nextDemoID)", tabID = "demo-tab-\(nextDemoID)", paneID = "demo-pane-\(nextDemoID)"
            nextDemoID += 1
            let number = (snapshot["workspaces"] as? [[String: Any]] ?? []).count + 1
            let workspace: [String: Any] = ["workspace_id": workspaceID, "number": number,
                                             "label": params["label"] as? String ?? "Demo workspace \(number)", "focused": false, "agent_status": "idle"]
            let tab: [String: Any] = ["tab_id": tabID, "workspace_id": workspaceID, "number": 1, "label": "Tab 1", "focused": false, "agent_status": "idle"]
            let pane: [String: Any] = ["pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": false,
                                       "agent_status": "idle", "cwd": params["cwd"] as? String ?? "", "revision": 1]
            snapshot["workspaces"] = (snapshot["workspaces"] as? [[String: Any]] ?? []) + [workspace]
            snapshot["tabs"] = (snapshot["tabs"] as? [[String: Any]] ?? []) + [tab]
            snapshot["panes"] = (snapshot["panes"] as? [[String: Any]] ?? []) + [pane]
            reply(["workspace": workspace, "tab": tab, "root_pane": pane])
            broadcast("pane_created", ["pane": pane])
        case "agent.start":
            let paneID = params["pane_id"] as? String ?? "", kind = params["kind"] as? String ?? "omp"
            let name = params["name"] as? String ?? "demo-agent"
            guard var panes = snapshot["panes"] as? [[String: Any]],
                  let index = panes.firstIndex(where: { $0["pane_id"] as? String == paneID }) else {
                open.channel.send(["id": requestID, "error": ["code": "pane_not_found", "message": "pane not found"]])
                break
            }
            panes[index]["agent"] = kind
            panes[index]["display_agent"] = kind
            snapshot["panes"] = panes
            let pane = panes[index]
            let agent: [String: Any] = ["pane_id": paneID, "workspace_id": pane["workspace_id"] ?? "", "tab_id": pane["tab_id"] ?? "",
                                        "agent_status": "idle", "agent": kind, "display_agent": kind, "name": name, "focused": false,
                                        "state_change_seq": 0, "agent_session": ["source": "herdr:omp", "agent": "omp", "kind": "path",
                                                                                 "value": DemoScenario.transcriptPath(paneID)]]
            snapshot["agents"] = (snapshot["agents"] as? [[String: Any]] ?? []) + [agent]
            transcripts[DemoScenario.transcriptPath(paneID)] = Data()
            reply(["agent": agent, "argv": params["args"] as? [String] ?? []])
            broadcast("pane_updated", ["pane": pane])
        case "agent.get":
            if let agent = (snapshot["agents"] as? [[String: Any]] ?? []).first(where: { $0["pane_id"] as? String == params["target"] as? String }) {
                reply(["agent": agent])
            } else {
                open.channel.send(["id": requestID, "error": ["code": "agent_not_found", "message": "agent not found"]])
            }
        default:
            open.channel.send(["id": requestID, "error": ["code": "unsupported", "message": "demo host: \(method)"]])
        }
        answered(open, on: id)
    }

    /// A one-shot bridge ends after its answer; a lane reports the exit status and waits for more.
    private func answered(_ open: Open, on id: ObjectIdentifier) {
        if case .lane = open.role {
            open.channel.send("\u{1E}0\n")
        } else {
            channels[id] = nil
            open.channel.finish()
        }
    }

    private func scriptReply(to text: String, pane: String) {
        guard isAgent(pane) else { return }
        let stamp = { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date()) }
        appendTranscript(record: ["type": "message", "id": UUID().uuidString, "timestamp": stamp(),
                                  "message": ["role": "user", "content": text]], pane: pane)
        nameAfterFirstMessage(text, pane: pane)
        setStatus(.working, pane: pane)
        Task {
            // A turn as a harness writes it: a test run the thread shows as a live step, then a
            // reply that ends the turn, so it lands on the Done card with "Took" like any other
            // (round 22: the bare paragraph under Done had no card, no step and no time, and the
            // thread sat empty for the whole wait).
            let call = UUID().uuidString
            try? await Task.sleep(for: scriptedReplyDelay * 0.15)
            guard isAgent(pane) else { return }
            appendTranscript(record: ["type": "message", "id": UUID().uuidString, "timestamp": stamp(),
                                      "message": ["role": "assistant", "stopReason": "toolUse", "content": [
                                          ["type": "toolCall", "id": call, "name": "bash", "arguments": ["command": "bun test --changed"]]]]], pane: pane)
            try? await Task.sleep(for: scriptedReplyDelay * 0.7)
            guard isAgent(pane) else { return }
            appendTranscript(record: ["type": "message", "id": UUID().uuidString, "timestamp": stamp(),
                                      "message": ["role": "toolResult", "toolCallId": call, "content": "12 pass · 0 fail"]], pane: pane)
            try? await Task.sleep(for: scriptedReplyDelay * 0.15)
            guard isAgent(pane) else { return }
            // A finished turn that did the work, so Done is true (round 20: "I'd first check…"
            // under Done read as work never done; round 21: "Say go and I'll start" under Done),
            // naming what was asked (round 23: "Made the smallest change…" could have answered anything).
            let ask = Self.restated(text)
            let response = "Done: \(ask)\(ask.hasSuffix("…") ? "" : ".")\n\n- **Tests:** 12 pass, 0 fail.\n- **Diff:** in the working tree for you to review; nothing committed."
            appendTranscript(record: ["type": "message", "id": UUID().uuidString, "timestamp": stamp(),
                                      "message": ["role": "assistant", "content": response, "stopReason": "stop"]], pane: pane)
            setStatus(.done, pane: pane)
        }
    }

    /// The ask as the reply restates it: its first line, without closing punctuation, lowercased
    /// at the start unless that's an acronym ("PR"), cut at a word past 90 characters.
    static func restated(_ text: String) -> String {
        var ask = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        while let last = ask.last, ".!?".contains(last) { ask.removeLast() }
        if ask.count > 90 {
            let cut = ask.prefix(90)
            ask = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        if let first = ask.first, ask.dropFirst().first?.isUppercase != true {
            ask = first.lowercased() + ask.dropFirst()
        }
        return ask.isEmpty ? "made the change" : ask
    }

    private func isAgent(_ pane: String) -> Bool {
        (snapshot["agents"] as? [[String: Any]] ?? []).contains { $0["pane_id"] as? String == pane }
    }

    /// An agent started here has no terminal title until its first message, which its harness
    /// turns into one (omp's "π: <title>"): the message's opening words stand in for that.
    private func nameAfterFirstMessage(_ text: String, pane: String) {
        var agents = snapshot["agents"] as? [[String: Any]] ?? []
        guard let index = agents.firstIndex(where: { $0["pane_id"] as? String == pane }),
              (agents[index]["terminal_title_stripped"] as? String ?? "").isEmpty else { return }
        let title = TranscriptActivity.previewLine(text, limit: 40)
        agents[index]["terminal_title_stripped"] = title
        snapshot["agents"] = agents
        var panes = snapshot["panes"] as? [[String: Any]] ?? []
        guard let paneIndex = panes.firstIndex(where: { $0["pane_id"] as? String == pane }) else { return }
        panes[paneIndex]["terminal_title_stripped"] = title
        snapshot["panes"] = panes
        broadcast("pane_updated", ["pane": panes[paneIndex]])
    }

    private func appendTranscript(record: [String: Any], pane: String) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let path = DemoScenario.transcriptPath(pane)
        let addition = Data(bytes + [0x0A])
        transcripts[path, default: Data()].append(addition)
        guard let data = transcripts[path] else { return }
        for (id, open) in channels {
            if case .file(let filePath, let offset) = open.role, filePath == path {
                if data.count > offset { open.channel.send(Data(data.dropFirst(offset))) }
                channels[id]?.role = .file(path: path, offset: data.count)
            }
        }
    }

    private func movePrompt(_ keys: [String], pane: String) {
        let markup = screenOverrides[pane] ?? screens[pane].flatMap { scenario.screenFiles[$0] } ?? ""
        var lines = markup.components(separatedBy: "\n")
        let options = lines.indices.filter { lines[$0].contains("\u{F10C}") }
        guard let selected = options.firstIndex(where: { lines[$0].contains("\u{F054}") }) else { return }
        var cursor = selected
        for key in keys {
            if key == "down" { cursor = min(cursor + 1, options.count - 1) }
            if key == "up" { cursor = max(cursor - 1, 0) }
        }
        lines[options[selected]] = lines[options[selected]].replacingOccurrences(of: "\u{F054}", with: " ")
        lines[options[cursor]] = lines[options[cursor]].replacingOccurrences(of: "  \u{F10C}", with: "\u{F054} \u{F10C}")
        screenOverrides[pane] = lines.joined(separator: "\n")
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
            screenOverrides[pane] = nil
            for (id, open) in channels {
                if case .terminal(pane, _, _, _) = open.role { paint(id) }
            }
        case .append(let pane, let path):
            let hostPath = DemoScenario.transcriptPath(pane)
            transcripts[hostPath, default: Data()].append(Self.timestamped(scenario.transcriptFiles[path] ?? Data(), pane: pane, now: Date(), live: true))
            guard let data = transcripts[hostPath] else { return }
            for (id, open) in channels {
                if case .file(let path, let offset) = open.role, path == hostPath {
                    if data.count > offset { open.channel.send(Data(data.dropFirst(offset))) }
                    channels[id]?.role = .file(path: path, offset: max(offset, data.count))
                }
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

    /// A structural event to every subscriber; the app's mirror refetches the snapshot on it.
    private func broadcast(_ name: String, _ data: [String: Any]) {
        for open in channels.values {
            if case .events = open.role { open.channel.send(["event": name, "data": data]) }
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
