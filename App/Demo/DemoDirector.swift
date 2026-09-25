import Foundation
import HerdrAPI
import HerdrDemo
import SwiftUI

/// What a marketing capture asks for, read from launch arguments (the argument domain of
/// `UserDefaults`, so `-appearance dark` and `-theme.dark tokyo-night` also work as-is):
///
///     -HerdwickDemo <scenario>                  studio | preview | any bundled HerdrDemo scenario
///     -HerdwickScene <scene>                    agents | workspaces | pane:<id> | onboarding | tailscale | settings
///     -HerdwickDraft <text>                     composer text on the opened pane
///     -HerdwickDrop YES                         drop the link after the first snapshot (reconnect UI)
///     -HerdwickHold YES                         start the timeline only once Documents/demo-go exists
///
/// Once the scene has rendered, the app writes `Documents/demo-ready` for the capture script.
struct DemoLaunch: Equatable {
    enum Scene: Equatable {
        case agents, workspaces, pane(String), onboarding, tailscale, settings

        init?(_ raw: String) {
            switch raw {
            case "agents": self = .agents
            case "workspaces": self = .workspaces
            case "onboarding": self = .onboarding
            case "tailscale": self = .tailscale
            case "settings": self = .settings
            default:
                guard raw.hasPrefix("pane:") else { return nil }
                self = .pane(String(raw.dropFirst(5)))
            }
        }

        /// Scenes shown before any host exists.
        var isOnboarding: Bool { self == .onboarding || self == .tailscale }
    }

    var scenario: String
    var scene: Scene
    var draft: String?
    var dropAfterReady: Bool
    var holdClock: Bool

    static let current: DemoLaunch? = {
        let defaults = UserDefaults.standard
        guard let scenario = defaults.string(forKey: "HerdwickDemo"), !scenario.isEmpty else { return nil }
        return DemoLaunch(
            scenario: scenario,
            scene: defaults.string(forKey: "HerdwickScene").flatMap(Scene.init) ?? .agents,
            draft: defaults.string(forKey: "HerdwickDraft"),
            dropAfterReady: defaults.bool(forKey: "HerdwickDrop"),
            holdClock: defaults.bool(forKey: "HerdwickHold")
        )
    }()
}

/// Runs a demo: a scripted herdr host (`HerdrDemo`) behind the real UI. It serves the
/// in-app "Explore a Demo" host and the marketing captures, and relays the scenario's UI
/// cues (open a pane, type a reply, send it) to the views. Nothing is saved.
@MainActor @Observable
final class DemoDirector {
    let launch: DemoLaunch?
    let scenario: DemoScenario
    @ObservationIgnored let host: DemoHost

    /// Navigation and composer state the views mirror.
    private(set) var mode: SessionView.Mode = .agents
    private(set) var paneID: String?
    private(set) var showsSettings = false
    private(set) var draft: String?
    private(set) var sendCount = 0
    /// Set by the open pane once its terminal has painted a frame.
    var terminalReady = false

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// `launch == nil` is the in-app demo; it always opens the static `studio` scenario.
    init(launch: DemoLaunch?) throws {
        self.launch = launch
        scenario = try DemoScenario.bundled(launch?.scenario ?? "studio")
        host = DemoHost(scenario: scenario, dropAfterReady: launch?.dropAfterReady ?? false)
        switch launch?.scene {
        case .workspaces: mode = .workspaces
        case .pane(let id): paneID = id
        case .settings: showsSettings = true
        default: break
        }
        draft = launch?.draft
    }

    /// The ephemeral host the demo connects to; it is never added to the saved hosts.
    var profile: HostProfile {
        HostProfile(
            name: launch == nil ? "Demo" : scenario.host.name,
            route: .direct(host: scenario.host.address, port: 22),
            username: scenario.host.user,
            auth: .deviceKey
        )
    }

    var tailnetPeers: [Tailnet.Peer] {
        (scenario.tailnet?.peers ?? []).map {
            Tailnet.Peer(id: $0.id, name: $0.name, dnsName: $0.dnsName, address: $0.address,
                         online: $0.online, sshHostKeys: $0.ssh ? ["ssh-ed25519 demo"] : [])
        }
    }

    func run(connection: HostConnection?) {
        tasks.append(Task { [weak self, host] in
            for await cue in host.cues {
                guard let self else { return }
                await self.apply(cue)
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            if launch?.holdClock == true {
                await self.markReady(connection: connection)
                await Self.waitForFile("demo-go")
                host.startClock()
            } else {
                host.startClock()
                await self.markReady(connection: connection)
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func apply(_ cue: DemoCue) async {
        switch cue {
        case .openPane(let id):
            terminalReady = false
            paneID = id
        case .back:
            paneID = nil
        case .mode(let raw):
            mode = raw == "workspaces" ? .workspaces : .agents
        case .sheet(let name):
            showsSettings = name == "settings"
        case .draft(let text):
            // Typed at a human pace so the composer grows the way it would under a thumb.
            for end in text.indices.dropFirst() + [text.endIndex] {
                draft = String(text[..<end])
                try? await Task.sleep(for: .milliseconds(55))
            }
        case .send:
            sendCount += 1
        }
    }

    // MARK: Capture handshake

    /// Writes `Documents/demo-ready` once the requested scene has settled.
    private func markReady(connection: HostConnection?) async {
        guard launch != nil else { return }
        try? FileManager.default.removeItem(at: Self.file("demo-ready"))
        while !Task.isCancelled, !sceneIsReady(connection) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Let navigation pushes, glass morphs and the list's first layout finish.
        try? await Task.sleep(for: .milliseconds(1200))
        FileManager.default.createFile(atPath: Self.file("demo-ready").path, contents: Data())
    }

    private func sceneIsReady(_ connection: HostConnection?) -> Bool {
        guard let launch else { return true }
        if launch.scene.isOnboarding { return true }
        guard let connection, connection.snapshot != nil else { return false }
        if launch.dropAfterReady {
            if case .waiting = connection.phase { return true }
            return false
        }
        guard connection.isLive else { return false }
        if case .pane = launch.scene { return terminalReady }
        return true
    }

    private static func waitForFile(_ name: String) async {
        while !Task.isCancelled, !FileManager.default.fileExists(atPath: file(name).path) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func file(_ name: String) -> URL {
        URL.documentsDirectory.appendingPathComponent(name)
    }
}
