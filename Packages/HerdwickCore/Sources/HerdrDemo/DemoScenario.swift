import Foundation
import HerdrAPI

/// A scripted herdr host: one session's snapshot, a terminal screen per pane, and a
/// timeline of changes. Loaded from `Scenarios/<name>/scenario.json`; see `Scenarios/README.md`.
public struct DemoScenario: Sendable {
    public struct Host: Sendable, Decodable, Equatable {
        public var name: String
        public var address: String
        public var user: String
    }

    public struct Tailnet: Sendable, Decodable, Equatable {
        public var name: String
        public var peers: [Peer]
    }

    public struct Peer: Sendable, Decodable, Equatable {
        public var id: String
        public var name: String
        public var dnsName: String
        public var address: String
        public var online: Bool
        public var ssh: Bool
    }

    public let name: String
    public let host: Host
    /// Machines the demo shows as a signed-in tailnet.
    public let tailnet: Tailnet?
    /// Seconds from `DemoHost.startClock()` until the last timed step has run.
    public let duration: Double

    let version: String
    let protocolVersion: Int
    let sessionsJSON: Data
    /// The `snapshot` object, served as-is and patched by status steps.
    let snapshotJSON: Data
    /// Screen markup by resolved file path.
    let screenFiles: [String: String]
    /// Initial screen (resolved file path) by pane id.
    let screens: [String: String]
    /// Status and screen changes applied before the app connects.
    let setup: [Action]
    let timeline: [TimedStep]
    let triggers: [Trigger]

    /// A scenario shipped in this module, e.g. `studio` or `preview`.
    public static func bundled(_ name: String) throws -> DemoScenario {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Scenarios") else {
            throw DemoError.invalidScenario("no bundled scenario \(name)")
        }
        return try DemoScenario(directory: url)
    }

    /// Loads `directory/scenario.json`. With `"extends": "<sibling>"` it starts from that
    /// scenario and replaces only the keys it sets; `setup` and `timeline` are its own.
    public init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("scenario.json"))
        let raw: Raw
        let object: [String: Any]
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw DemoError.invalidScenario("\(directory.lastPathComponent)/scenario.json: \(error)")
        }
        let base = try raw.extends.map { try DemoScenario(directory: directory.deletingLastPathComponent().appendingPathComponent($0)) }
        func resolve(_ path: String) -> String { directory.appendingPathComponent(path).standardizedFileURL.path }

        let name = directory.lastPathComponent
        self.name = name
        guard let host = raw.host ?? base?.host, let herdr = raw.herdr ?? base.map({ Raw.Herdr(version: $0.version, protocol: $0.protocolVersion) }) else {
            throw DemoError.invalidScenario("\(name): needs host and herdr")
        }
        self.host = host
        tailnet = raw.tailnet ?? base?.tailnet
        version = herdr.version
        protocolVersion = herdr.protocol
        if let sessions = object["sessions"] {
            sessionsJSON = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        } else if let base {
            sessionsJSON = base.sessionsJSON
        } else {
            throw DemoError.invalidScenario("\(name): needs sessions")
        }
        if let snapshot = object["snapshot"] as? [String: Any] {
            snapshotJSON = try JSONSerialization.data(withJSONObject: snapshot)
        } else if let base {
            snapshotJSON = base.snapshotJSON
        } else {
            throw DemoError.invalidScenario("\(name): needs snapshot")
        }
        screens = raw.screens.map { $0.mapValues(resolve) } ?? base?.screens ?? [:]

        // Fail at load, not mid-capture: the snapshot must decode as herdr's and every
        // pane and screen a step names must exist.
        let decoded: Snapshot
        do {
            decoded = try JSONDecoder().decode(Snapshot.self, from: snapshotJSON)
        } catch {
            throw DemoError.invalidScenario("\(name) snapshot: \(error)")
        }
        let panes = Set(decoded.panes.map(\.id))
        func action(_ step: Step) throws -> Action { try Action(step, panes: panes, resolve: resolve) }

        setup = try (raw.setup ?? []).map(action)
        let steps = raw.timeline ?? []
        timeline = try steps.compactMap { step in
            guard step.on == nil else { return nil }
            guard let t = step.t else { throw DemoError.invalidScenario("\(name): timeline step without t or on") }
            return TimedStep(at: t, action: try action(step))
        }
        triggers = try steps.compactMap { step in
            guard let on = step.on else { return nil }
            let then = try (step.then ?? []).map { TimedStep(at: $0.after ?? 0, action: try action($0)) }
            return Trigger(method: "pane." + on, pane: step.pane, then: then)
        }
        duration = timeline.map { step in
            if case .drop(let seconds?) = step.action { return step.at + seconds }
            return step.at
        }.max() ?? 0

        for pane in screens.keys where !panes.contains(pane) {
            throw DemoError.invalidScenario("\(name): screen for unknown pane \(pane)")
        }
        var files = base?.screenFiles ?? [:]
        let named = setup + (timeline + triggers.flatMap(\.then)).map(\.action)
        let referenced = Array(screens.values) + named.compactMap { action in
            if case .screen(_, let path) = action { return path }
            return nil
        }
        for path in referenced where files[path] == nil {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw DemoError.invalidScenario("\(name): missing screen \(path)")
            }
            files[path] = text
        }
        screenFiles = files
    }

    private struct Raw: Decodable {
        struct Herdr: Decodable { var version: String; var `protocol`: Int }
        var extends: String?
        var host: Host?
        var herdr: Herdr?
        var screens: [String: String]?
        var tailnet: Tailnet?
        var setup: [Step]?
        var timeline: [Step]?
    }

    /// One `setup` or `timeline` entry: a timed step (`t`), a trigger (`on`), or a
    /// trigger's follow-up (`after`).
    struct Step: Decodable {
        var t: Double?
        var after: Double?
        var on: String?
        var then: [Step]?
        var `do`: String?
        var pane: String?
        var status: String?
        var screen: String?
        var cue: String?
        var text: String?
        var `for`: Double?
    }
}

public enum DemoError: Error, Equatable, Sendable {
    case invalidScenario(String)
}

/// A UI step the scenario asks the app to perform, relayed through `DemoHost.cues`.
public enum DemoCue: Sendable, Equatable {
    /// Open the pane with this id.
    case openPane(String)
    /// Return to the session's root list.
    case back
    /// Switch the session list: `agents` or `workspaces`.
    case mode(String)
    /// Type this text into the open pane's composer.
    case draft(String)
    /// Send the composer's text.
    case send
    /// Present a sheet by name (`settings`); nil dismisses it.
    case sheet(String?)
}

struct TimedStep: Sendable {
    var at: Double
    var action: Action
}

/// Runs `then` (delays relative to the request) when the app calls `method` on `pane`.
struct Trigger: Sendable {
    var method: String
    var pane: String?
    var then: [TimedStep]
}

enum Action: Sendable {
    case status(pane: String, AgentStatus)
    case screen(pane: String, path: String)
    case cue(DemoCue)
    /// Kill every channel and refuse new ones for `seconds`, or for good when nil.
    case drop(Double?)

    init(_ step: DemoScenario.Step, panes: Set<String>, resolve: (String) -> String) throws {
        func pane() throws -> String {
            guard let id = step.pane else { throw DemoError.invalidScenario("\(step.do ?? "step") needs pane") }
            guard panes.contains(id) else { throw DemoError.invalidScenario("unknown pane \(id)") }
            return id
        }
        switch step.do {
        case "status":
            guard let raw = step.status, let status = AgentStatus(rawValue: raw), status != .unknown else {
                throw DemoError.invalidScenario("bad status \(step.status ?? "nil")")
            }
            self = .status(pane: try pane(), status)
        case "screen":
            guard let path = step.screen else { throw DemoError.invalidScenario("screen step needs screen") }
            self = .screen(pane: try pane(), path: resolve(path))
        case "drop":
            self = .drop(step.for)
        case "ui":
            switch step.cue {
            case "openPane": self = .cue(.openPane(try pane()))
            case "back": self = .cue(.back)
            case "mode":
                guard let mode = step.text, mode == "agents" || mode == "workspaces" else {
                    throw DemoError.invalidScenario("mode cue needs text agents or workspaces")
                }
                self = .cue(.mode(mode))
            case "draft": self = .cue(.draft(step.text ?? ""))
            case "send": self = .cue(.send)
            case "sheet": self = .cue(.sheet(step.text))
            default: throw DemoError.invalidScenario("bad ui cue \(step.cue ?? "nil")")
            }
        default:
            throw DemoError.invalidScenario("unknown step \(step.do ?? "nil")")
        }
    }
}
