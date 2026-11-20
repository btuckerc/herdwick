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
            echo '{"result":{"agent":{"agent_status":"idle","pane_id":"w1:p1","state_change_seq":7,"agent_session":{"value":"ref-a"}},"type":"agent_info"}}'
        fi ;;
    esac
    """#

private let stubActivityHerdr = #"""
    #!/bin/sh
    shift 2
    case "$1 $2" in
    "agent list") echo '{"result":{"agents":[{"pane_id":"w1:p1"}]}}' ;;
    "agent wait")
        if [ "$5" = working ]; then
            if [ -e "$STUB_DIR/finished" ]; then echo $$ > "$STUB_DIR/sleeper.pid"; exec sleep 300; fi
            state=working; seq=6
            [ ! -e "$STUB_DIR/blocked" ] || seq=8
        elif [ ! -e "$STUB_DIR/blocked" ]; then
            : > "$STUB_DIR/blocked"
            state=blocked; seq=7
        else
            : > "$STUB_DIR/finished"
            state=idle; seq=9
        fi
        printf '{"result":{"agent":{"agent_status":"%s","state_change_seq":%s,"agent_session":{"value":"ref-a"}}}}\n' "$state" "$seq" ;;
    esac
    """#

private let scenarioHerdr = #"""
    #!/bin/sh
    shift 2
    case "$1 $2 $3" in
    "agent list ") echo '{"result":{"agents":[{"pane_id":"w1:p1"}]}}' ;;
    "agent wait "*)
        if [ "$5" = working ]; then
            if [ -e "$STUB_DIR/finished" ]; then exec sleep 300; fi
            printf '{"result":{"agent":{"agent":"omp","agent_status":"working","pane_id":"w1:p1","state_change_seq":5,"agent_session":{"kind":"path","value":"%s"}}}}\n' "$TRANSCRIPT"
        else
            if [ "$STUB_MODE" = pty ] || [ "$STUB_MODE" = no-overlay ] || [ "$STUB_MODE" = changing ]; then sleep 3; fi
            : > "$STUB_DIR/finished"
            seq=6; [ "$STUB_MODE" != plan ] || seq=8
            printf '{"result":{"agent":{"agent":"omp","agent_status":"idle","pane_id":"w1:p1","state_change_seq":%s,"agent_session":{"kind":"path","value":"%s"}}}}\n' "$seq" "$TRANSCRIPT"
        fi ;;
    "pane read "*)
        case "$STUB_MODE" in
        pty)
            # The spinner before the command turns between reads; the prompt stays put.
            n=0; [ ! -f "$STUB_DIR/read-count" ] || n=$(cat "$STUB_DIR/read-count")
            n=$((n + 1)); echo "$n" > "$STUB_DIR/read-count"
            spin='⠋'; [ $((n % 2)) = 0 ] || spin='⠙'
            printf '╭─ %s Console command ⟨running⟩ ─╮\n│ prompt text\n│ force-kill · input forwarded to PTY\n╰─╯\n' "$spin" ;;
        changing)
            n=0; [ ! -f "$STUB_DIR/read-count" ] || n=$(cat "$STUB_DIR/read-count")
            n=$((n + 1)); echo "$n" > "$STUB_DIR/read-count"
            printf '╭─ Console command ⟨running⟩ ─╮\n│ prompt %s\n│ force-kill · input forwarded to PTY\n╰─╯\n' "$n" ;;
        *) echo 'ordinary pane content' ;;
        esac ;;
    esac
    """#

private let planTranscript = #"""
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_plan","name":"write","arguments":{"path":"xd://propose","content":"review me"}}],"timestamp":1760000000000}}
    {"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"toolu_plan","toolName":"write"}}
    {"type":"message","message":{"role":"toolResult","toolCallId":"toolu_plan","toolName":"write","content":[{"type":"text","text":"Plan ready for review."}],"isError":false}}
    """#

private let ptyTranscript = #"""
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_pty","name":"bash","arguments":{"command":"read -p 'Overwrite config.yml? [y/N] '","pty":true}}],"timestamp":1760000000000}}
    {"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"toolu_pty","toolName":"bash","args":{"command":"read -p 'Overwrite config.yml? [y/N] '}}}
    """#

/// With only the record's ISO 8601 time and no epoch `message.timestamp`.
private let ptyRecordTranscript = #"""
    {"type":"message","timestamp":"2025-10-09T08:53:20.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_pty","name":"bash","arguments":{"command":"read -p 'Overwrite config.yml? [y/N] '","pty":true}}]}}
    {"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"toolu_pty","toolName":"bash","args":{"command":"read -p 'Overwrite config.yml? [y/N] '}}}
    """#

@Test(.serialized, arguments: ["plan", "pty", "pty-record", "no-overlay", "changing", "no-jsonpp"])
func watcherDetectsOmpWaits(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    let body = switch mode { case "plan": planTranscript; case "pty-record": ptyRecordTranscript; default: ptyTranscript }
    try body.write(to: transcript, atomically: true, encoding: .utf8)
    for (name, body) in [("herdr", scenarioHerdr), ("curl", stubCurl)] {
        let file = bin.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    if mode == "no-jsonpp" {
        let perl = bin.appendingPathComponent("perl")
        try "#!/bin/sh\nexit 2\n".write(to: perl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: perl.path)
    }
    // A stub written a moment ago can still be held open by a process another test is forking
    // (ETXTBSY): the watcher would stop at a failed `agent list` or lose a post to `curl`, so
    // wait until both run (the probe's post goes to a scratch directory).
    let scratch = root.appendingPathComponent("probe")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    #expect(await eventuallyAsync {
        guard let channel = try? await LocalProcessRunner().exec(
            "\(bin.path)/herdr --session s1 agent list >/dev/null && STUB_DIR=\(scratch.path) \(bin.path)/curl </dev/null"
        ) else { return false }
        return (try? await HerdrClient.collect(channel)) != nil
    })
    let stub = mode == "pty-record" ? "pty" : mode
    let runner = EnvRunner(prefix: "HOME=\(home.path) STUB_DIR=\(root.path) TRANSCRIPT=\(transcript.path) STUB_MODE=\(stub) HW_PROBE=1 PATH=\(bin.path):$PATH ")
    let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let config = PushWatch.Config(relay: URL(string: "https://relay.example")!, deviceToken: "ab12",
                                  environment: "development", hostID: host, states: ["blocked", "done"],
                                  installationID: UUID(), secret: "abcd")
    try await PushWatch.arm(config, session: "s1", herdrPath: bin.appendingPathComponent("herdr").path, runner: runner)
    let posts = root.appendingPathComponent("posts")
    let expected = mode == "plan" ? ["blocked:8"] :
        (stub == "pty" ? ["blocked:5", "done:6"] : ["done:6"])
    #expect(await eventually {
        guard let text = try? String(contentsOf: posts, encoding: .utf8) else { return false }
        return text.split(separator: "\n").count >= expected.count
    })
    let events = (try String(contentsOf: posts, encoding: .utf8)).split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    #expect(events.map { "\($0["state"] as? String ?? ""):\($0["seq"] as? Int ?? 0)" } == expected)
    try await PushWatch.disarm(installationID: config.installationID, hostID: host, session: "s1", runner: runner)
}

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

private func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

@Test(.serialized, arguments: ["none", "active", "expired", "reused", "unsigned", "activity", "activity-muted", "activity-other"])
func watcherPostsAFinishOnceWithOpaqueIDsAndDisarmLeavesNothing(mute: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin")
    for dir in [home, bin] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    let watchesActivity = mute == "activity" || mute == "activity-muted"
    for (name, body) in [("herdr", watchesActivity ? stubActivityHerdr : stubHerdr), ("curl", stubCurl)] {
        let file = bin.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    if mute == "unsigned" {
        let file = bin.appendingPathComponent("openssl")
        try "#!/bin/sh\nexit 127\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let runner = EnvRunner(prefix: "HOME=\(root.path)/home STUB_DIR=\(root.path) PATH=\(bin.path):$PATH ")
    let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    var config = PushWatch.Config(relay: URL(string: "https://relay.example")!, deviceToken: "ab12",
                                  environment: "development", hostID: host, states: ["blocked", "done"],
                                  installationID: UUID(), secret: "abcd")
    if ["active", "expired", "reused", "activity-muted"].contains(mute) {
        config.mutes = [.init(pane: "w1:p1", reference: mute == "reused" ? "old-ref" : "ref-a",
                              expires: mute == "expired" ? 1 : 0)]
    }
    if watchesActivity || mute == "activity-other" {
        config.activity = .init(pane: mute == "activity-other" ? "w1:p2" : "w1:p1", token: "de34")
        if mute == "activity" { config.states = []; config.deviceToken = "" }
    }

    try await PushWatch.arm(config, session: "s1", herdrPath: bin.appendingPathComponent("herdr").path, runner: runner)

    let posts = root.appendingPathComponent("posts"), sleeper = root.appendingPathComponent("sleeper.pid")
    #expect(await eventually { FileManager.default.fileExists(atPath: sleeper.path) })
    if watchesActivity {
        let events = try String(contentsOf: posts, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        #expect(events.compactMap { $0["kind"] as? String } == Array(repeating: "liveactivity", count: 4))
        #expect(events.compactMap { $0["token"] as? String } == Array(repeating: "de34", count: 4))
        #expect(events.compactMap { $0["state"] as? String } == ["working", "blocked", "working", "done"])
        #expect(events.compactMap { $0["mac"] as? String } == [
            "bb6bc5c63fc922b8e3f90fa94d6806da41693fa7da1dc78cb0e76c2395d6408d",
            "8b0783a5a580fc58e7c1b84dbfc1c4f8b053695285589696d92cf745469cc291",
            "a72d979aeb7d7f6754f93adcb120c7c30cca9789aa60171daa44a1be5c0dbc5d",
            "5be8c772fa3ce47422860d42a9b16a0625c51db18a7ff1ffbe74ba4b028d11fb",
        ])
        try await PushWatch.disarm(installationID: config.installationID, hostID: host, session: "s1", runner: runner)
        return
    }
    if mute == "active" {
        #expect(!FileManager.default.fileExists(atPath: posts.path))
        try await PushWatch.disarm(installationID: config.installationID, hostID: host, session: "s1", runner: runner)
        return
    }
    let lines = try String(contentsOf: posts, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    let post = try JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as? [String: Any]
    #expect(post?["state"] as? String == "done")
    #expect(post?["seq"] as? Int == 7)
    #expect(post?["pane"] as? String == "w1:p1")
    #expect(post?["session"] as? String == "s1")
    #expect(post?["host"] as? String == host.uuidString)
    #expect(post?["token"] as? String == "ab12")
    if mute == "unsigned" {
        #expect(post?["mac"] == nil)
    } else {
        #expect(post?["mac"] as? String == "c97dca262a2d55de021c1847ba9b6409872c0e96576ef7bab9e0688326fdf4b5")
    }
    let owner = ".herdwick/\(config.installationID.uuidString)-\(host.uuidString)"
    let env = home.appendingPathComponent("\(owner)/push.s1.env")
    #expect(try FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as? Int == 0o600)

    let watcher = try #require(pid_t(String(contentsOf: home.appendingPathComponent("\(owner)/watch.s1.pid"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    let waiting = try #require(pid_t(String(contentsOf: sleeper, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(alive(watcher) && alive(waiting))

    // A second phone on the same remote account owns an independent watcher.
    var other = config
    other.installationID = UUID()
    try await PushWatch.arm(other, session: "s1", herdrPath: bin.appendingPathComponent("herdr").path, runner: runner)
    let otherOwner = ".herdwick/\(other.installationID.uuidString)-\(host.uuidString)"
    let otherPID = try #require(pid_t(String(contentsOf: home.appendingPathComponent("\(otherOwner)/watch.s1.pid"),
                                               encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    try await PushWatch.disarm(installationID: config.installationID, hostID: host, session: "s1", runner: runner)

    #expect(await eventually { !alive(watcher) && !alive(waiting) })
    #expect(alive(otherPID))
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("\(otherOwner)/push.s1.env").path))
    #expect(await eventually { !FileManager.default.fileExists(atPath: home.appendingPathComponent(owner).path) })
    try await PushWatch.disarm(installationID: other.installationID, hostID: host, session: "s1", runner: runner)
    #expect(await eventually { !alive(otherPID) })
}

@Test func installerRejectsValuesThatCouldEscapeTheScript() {
    let good = PushWatch.Config(relay: URL(string: "https://relay.example")!, deviceToken: "ab12",
                                environment: "production", hostID: UUID(), states: ["blocked"],
                                installationID: UUID(), secret: "abcd")
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
