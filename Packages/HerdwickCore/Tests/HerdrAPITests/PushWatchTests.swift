import Foundation
import HerdrTestSupport
import Testing
@testable import HerdrAPI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs commands locally with a fixed environment, standing in for a host's login shell.
private struct EnvRunner: CommandRunner {
    let prefix: String
    func exec(_ command: String) async throws -> any ExecChannel {
        try await LocalProcessRunner().exec(prefix + command)
    }
}

/// `herdr` that has one agent working, then idle (as herdr reports the desk-focused pane),
/// then never works again: the next wait blocks in a `sleep` whose pid it records.
private let stubHerdr = #"""
    #!/bin/sh
    shift 2
    case "$1 $2" in
    "agent list") echo '{"id":"cli:agent:list","result":{"agents":[{"pane_id":"w1:p1","agent_status":"working"}]}}' ;;
    "agent wait")
        if [ "$5" = working ]; then
            if [ -e "$STUB_DIR/finished" ]; then echo $$ > "$STUB_DIR/sleeper.pid"; exec sleep 300; fi
            echo '{"result":{"agent":{"agent_status":"working","pane_id":"w1:p1","state_change_seq":6},"type":"agent_info"}}'
        else
            : > "$STUB_DIR/finished"
            echo '{"result":{"agent":{"agent_status":"idle","pane_id":"w1:p1","state_change_seq":7},"type":"agent_info"}}'
        fi ;;
    esac
    """#

private let stubCurl = """
    #!/bin/sh
    cat >> "$STUB_DIR/posts"
    """

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

@Test func watcherPostsAFinishOnceWithOpaqueIDsAndDisarmLeavesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin")
    for dir in [home, bin] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, body) in [("herdr", stubHerdr), ("curl", stubCurl)] {
        let file = bin.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let runner = EnvRunner(prefix: "HOME=\(root.path)/home STUB_DIR=\(root.path) PATH=\(bin.path):$PATH ")
    let host = UUID()
    let config = PushWatch.Config(relay: URL(string: "https://relay.example")!, deviceToken: "ab12",
                                  environment: "development", hostID: host, states: ["blocked", "done"])

    try await PushWatch.arm(config, session: "s1", herdrPath: bin.appendingPathComponent("herdr").path, runner: runner)

    let posts = root.appendingPathComponent("posts"), sleeper = root.appendingPathComponent("sleeper.pid")
    #expect(await eventually { FileManager.default.fileExists(atPath: sleeper.path) })
    let lines = try String(contentsOf: posts, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    let post = try JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as? [String: Any]
    #expect(post?["state"] as? String == "done")
    #expect(post?["seq"] as? Int == 7)
    #expect(post?["pane"] as? String == "w1:p1")
    #expect(post?["session"] as? String == "s1")
    #expect(post?["host"] as? String == host.uuidString)
    #expect(post?["token"] as? String == "ab12")
    #expect(Set(post?.keys.map { $0 } ?? []) == ["token", "env", "host", "session", "pane", "state", "seq"])
    let env = home.appendingPathComponent(".herdwick/push.env")
    #expect(try FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as? Int == 0o600)

    let watcher = try #require(pid_t(String(contentsOf: home.appendingPathComponent(".herdwick/watch.s1.pid"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    let waiting = try #require(pid_t(String(contentsOf: sleeper, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(alive(watcher) && alive(waiting))

    try await PushWatch.disarm(session: "s1", runner: runner)

    #expect(await eventually { !alive(watcher) && !alive(waiting) })
    #expect(await eventually { !FileManager.default.fileExists(atPath: home.appendingPathComponent(".herdwick").path) })
}

@Test func installerRejectsValuesThatCouldEscapeTheScript() {
    let good = PushWatch.Config(relay: URL(string: "https://relay.example")!, deviceToken: "ab12",
                                environment: "production", hostID: UUID(), states: ["blocked"])
    #expect(throws: PushWatch.WatchError.unsafe("session")) {
        try PushWatch.installer(good, session: "a'b; $(touch x)", herdrPath: "/usr/bin/herdr")
    }
    var badEnv = good
    badEnv.environment = "x' HW_URL='https://evil"
    #expect(throws: PushWatch.WatchError.unsafe("environment")) {
        try PushWatch.installer(badEnv, session: "main", herdrPath: "/usr/bin/herdr")
    }
    var plain = good
    plain.relay = URL(string: "http://relay.example")!
    #expect(throws: PushWatch.WatchError.unsafe("relay")) {
        try PushWatch.installer(plain, session: "main", herdrPath: "/usr/bin/herdr")
    }
    #expect(throws: Never.self) { try PushWatch.installer(good, session: "main", herdrPath: "/opt/my herdr/herdr") }
}
