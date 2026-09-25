import Foundation

/// The host side of push alerts: a POSIX `sh` watcher the app starts over SSH as it leaves
/// the foreground and stops when it comes back.
///
/// Footprint while armed, per watched agent: one `herdr agent wait` blocked on herdr's socket
/// (measured at no CPU and no wakeups, about 6 MB) and its `sh` loop. Once every 120 s one
/// `herdr agent list` (about 20 ms of CPU) finds agents started meanwhile. Each alert is one
/// `curl`. Disarmed, nothing runs. The watcher exits on its own after `ttl` or when herdr stops.
///
/// A post carries only opaque ids (host, session, pane, state, change number); the phone
/// supplies names it already knows. Secrets travel on stdin and live in a 0600 file.
public enum PushWatch {
    public struct Config: Sendable, Equatable {
        /// The relay's base URL, e.g. `https://push.example.workers.dev`.
        public var relay: URL
        /// APNs device token, lowercase hex.
        public var deviceToken: String
        /// `production` or `development` (APNs sandbox).
        public var environment: String
        /// The app's id for this host, echoed back so the alert opens the right link.
        public var hostID: UUID
        /// States worth an alert: `blocked`, `done`.
        public var states: [String]
        public var ttl: Duration

        public init(relay: URL, deviceToken: String, environment: String, hostID: UUID,
                    states: [String], ttl: Duration = .seconds(24 * 60 * 60)) {
            self.relay = relay
            self.deviceToken = deviceToken
            self.environment = environment
            self.hostID = hostID
            self.states = states
            self.ttl = ttl
        }
    }

    public enum WatchError: Error, Equatable {
        /// A value would not be safe inside the watcher's JSON or shell.
        case unsafe(String)
    }

    /// Starts (or restarts) the watcher for `session`.
    public static func arm(_ config: Config, session: String, herdrPath: String, runner: any CommandRunner) async throws {
        try await run(installer(config, session: session, herdrPath: herdrPath), runner: runner)
    }

    /// Stops the watcher for `session`, if one runs, and removes its files unless another
    /// session's watcher still needs them.
    public static func disarm(session: String, runner: any CommandRunner) async throws {
        try check(session, allowed: safeName, "session")
        try await run("""
            dir="$HOME/.herdwick"
            pid="$dir/watch.\(session).pid"
            if [ -f "$pid" ]; then kill "$(cat "$pid")" 2>/dev/null || true; rm -f "$pid"; fi
            ls "$dir"/watch.*.pid >/dev/null 2>&1 || { rm -f "$dir/push.env" "$dir/watch.sh"; rmdir "$dir" 2>/dev/null; }
            true
            """, runner: runner)
    }

    /// `sh -s` reads the program from stdin, so no secret appears in a process list and any
    /// login shell (fish included) only has to start `sh`.
    private static func run(_ program: String, runner: any CommandRunner) async throws {
        let channel = try await runner.exec("/bin/sh -s")
        do {
            try await channel.write(Array(program.utf8))
            try await channel.closeInput()
            for try await _ in channel.output {}
        } catch {
            await channel.close()
            throw error
        }
        await channel.close()
    }

    static func installer(_ config: Config, session: String, herdrPath: String) throws -> String {
        try check(session, allowed: safeName, "session")
        try check(config.deviceToken, allowed: "0123456789abcdef", "device token")
        try check(config.environment, allowed: safeName, "environment")
        try check(config.states.joined(), allowed: safeName, "states")
        let relay = config.relay.absoluteString
        guard config.relay.scheme == "https", !relay.contains("'") else { throw WatchError.unsafe("relay") }
        let ttl = Int(config.ttl.components.seconds)
        return """
            set -e
            umask 077
            dir="$HOME/.herdwick"
            mkdir -p "$dir"
            # Stop a previous watcher first: on its way out it may clear these files.
            pid="$dir/watch.\(session).pid"
            if [ -f "$pid" ]; then
                old=$(cat "$pid")
                rm -f "$pid"
                kill "$old" 2>/dev/null || true
                n=0; while kill -0 "$old" 2>/dev/null && [ $n -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
            fi
            cat > "$dir/push.env" <<'HERDWICK_ENV'
            HW_URL='\(relay.hasSuffix("/") ? String(relay.dropLast()) : relay)'
            HW_TOKEN='\(config.deviceToken)'
            HW_ENV='\(config.environment)'
            HW_HOST='\(config.hostID.uuidString)'
            HW_STATES='\(config.states.joined(separator: " "))'
            HW_TTL=\(ttl)
            HERDWICK_ENV
            cat > "$dir/watch.sh" <<'HERDWICK_WATCH'
            \(script)
            HERDWICK_WATCH
            nohup /bin/sh "$dir/watch.sh" \(shellQuote(herdrPath)) \(session) >/dev/null 2>&1 </dev/null &
            echo $! > "$pid"
            """
    }

    private static let safeName = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

    private static func check(_ value: String, allowed: String, _ what: String) throws {
        guard !value.isEmpty, value.allSatisfy({ allowed.contains($0) }) else { throw WatchError.unsafe(what) }
    }

    /// The watcher. `idle` after `working` counts as done: herdr skips `done` for the pane
    /// focused at the desk.
    static let script = #"""
        #!/bin/sh
        # Herdwick push watcher: armed while the iPhone app is away, killed when it returns.
        herdr=$1 session=$2
        dir="$HOME/.herdwick"
        . "$dir/push.env" || exit 1
        run="$dir/run.$session.$$"
        mkdir -p "$run" || exit 1
        deadline=$(( $(date +%s) + ${HW_TTL:-86400} ))

        reap() { for child in $(pgrep -P "$1"); do reap "$child"; kill "$child" 2>/dev/null; done; }
        stop() {
            trap - TERM INT HUP
            reap $$
            rm -rf "$run"
            # Leave nothing behind once no watcher remains.
            [ "$(cat "$dir/watch.$session.pid" 2>/dev/null)" = $$ ] && rm -f "$dir/watch.$session.pid"
            ls "$dir"/watch.*.pid >/dev/null 2>&1 || { rm -f "$dir/push.env" "$dir/watch.sh"; rmdir "$dir" 2>/dev/null; }
            exit 0
        }
        trap stop TERM INT HUP

        field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

        post() {
            case " $HW_STATES " in *" $2 "*) ;; *) return 0 ;; esac
            case $3 in ''|*[!0-9]*) set -- "$1" "$2" 0 ;; esac
            curl -fsS -m 20 --retry 3 -o /dev/null -H 'content-type: application/json' \
                --data-binary @- "$HW_URL/v1/push" <<EOF || true
        {"token":"$HW_TOKEN","env":"$HW_ENV","host":"$HW_HOST","session":"$session","pane":"$1","state":"$2","seq":$3}
        EOF
        }

        # One blocked wait at a time per pane: until it works, then until it stops.
        follow() {
            while out=$("$herdr" --session "$session" agent wait "$1" --until working) &&
                  out=$("$herdr" --session "$session" agent wait "$1"); do
                state=$(field "$out" agent_status)
                [ "$state" = idle ] && state=done
                post "$1" "$state" "$(field "$out" state_change_seq)"
            done
            rm -f "$run/$1"
        }

        while [ "$(date +%s)" -lt "$deadline" ]; do
            list=$("$herdr" --session "$session" agent list) || break
            for pane in $(printf '%s\n' "$list" | grep -o '"pane_id":"[^"]*"' | cut -d'"' -f4); do
                case $pane in *[!A-Za-z0-9:._-]*) continue ;; esac
                [ -e "$run/$pane" ] && continue
                : > "$run/$pane"
                follow "$pane" &
            done
            sleep 120 & wait $!
        done
        stop
        """#
}
