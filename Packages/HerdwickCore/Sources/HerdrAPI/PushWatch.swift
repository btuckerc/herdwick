import Foundation

/// The host side of push alerts: a POSIX `sh` watcher the app starts over SSH as it leaves
/// the foreground and stops when it comes back.
///
/// Footprint while armed, per watched agent: one `herdr agent wait` blocked on herdr's socket
/// (measured at no CPU and no wakeups, about 6 MB) and its `sh` loop. For each working omp pane,
/// one transcript tail plus `perl`/JSON::PP every 15 s; a pending PTY call adds one pane read.
/// Once every 120 s one `herdr agent list` (about 20 ms of CPU) finds agents started meanwhile.
/// Each alert is one `curl`. Disarmed, nothing runs. The watcher exits on its own after `ttl` or
/// when herdr stops. PTY detection needs `perl` with the core JSON::PP module.
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
        public var installationID: UUID
        public var secret: String
        public var mutes: [Mute]
        public var activity: Activity?
        /// Claude finishes the app held (`TurnSettle`) as it left, each to alert after `seconds`
        /// unless the agent moves on first: a backstop can't wait for the next turn.
        public var held: [Held] = []
        /// Pane → the Claude transcript the app found for it (an agent's own
        /// `CLAUDE_CONFIG_DIR` included); the watcher looks in the default folders for the rest.
        public var claudeTranscripts: [String: String] = [:]

        /// `deadline`: when it alerts, in epoch seconds on the host's clock; nil while the app
        /// was still checking it, so the watcher checks it as it starts. `reference`: the
        /// conversation it belongs to. `alert` false: read already, so only its Live Activity ends.
        public struct Held: Sendable, Equatable {
            public var pane: String
            public var seq: Int
            public var deadline: Int?
            public var reference: String?
            public var alert: Bool
            public init(pane: String, seq: Int, deadline: Int?, reference: String? = nil, alert: Bool = true) {
                self.pane = pane; self.seq = seq; self.deadline = deadline; self.reference = reference; self.alert = alert
            }
        }

        public struct Activity: Sendable, Equatable {
            public var pane: String
            public var token: String
            public init(pane: String, token: String) {
                self.pane = pane
                self.token = token
            }
        }

        public struct Mute: Sendable, Equatable {
            public var pane: String
            public var reference: String
            public var expires: Int
            public init(pane: String, reference: String, expires: Int) {
                self.pane = pane
                self.reference = reference
                self.expires = expires
            }
        }

        public init(relay: URL, deviceToken: String, environment: String, hostID: UUID,
                    states: [String], installationID: UUID, secret: String, mutes: [Mute] = [],
                    activity: Activity? = nil, ttl: Duration = .seconds(24 * 60 * 60)) {
            self.relay = relay
            self.deviceToken = deviceToken
            self.environment = environment
            self.hostID = hostID
            self.states = states
            self.ttl = ttl
            self.installationID = installationID
            self.secret = secret
            self.mutes = mutes
            self.activity = activity
        }
    }

    public enum WatchError: Error, Equatable {
        /// A value would not be safe inside the watcher's JSON or shell.
        case unsafe(String)
        case handoffFailed
    }

    /// Starts (or restarts) the watcher for `session`.
    public static func arm(_ config: Config, session: String, herdrPath: String, runner: any CommandRunner) async throws {
        try await run(installer(config, session: session, herdrPath: herdrPath), runner: runner)
    }

    /// Stops the watcher for `session`, if one runs, and removes its files unless another
    /// session's watcher still needs them.
    public static func disarm(installationID: UUID, hostID: UUID, session: String, runner: any CommandRunner) async throws {
        try check(session, allowed: safeName, "session")
        try await run("""
            dir="$HOME/.herdwick/\(installationID.uuidString)-\(hostID.uuidString)"
            pid="$dir/watch.\(session).pid"
            if [ -f "$pid" ]; then
                old=$(cat "$pid")
                kill "$old" 2>/dev/null || true
                n=0; while kill -0 "$old" 2>/dev/null && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
                kill -0 "$old" 2>/dev/null && exit 1
                rm -f "$pid" "$dir/push.\(session).env"
            fi
            ls "$dir"/watch.*.pid >/dev/null 2>&1 || { rm -f "$dir/watch.sh"; rmdir "$dir" 2>/dev/null || true; }
            echo HERDWICK_OK
            """, runner: runner)
    }

    /// `sh -s` reads the program from stdin, so no secret appears in a process list and any
    /// login shell (fish included) only has to start `sh`.
    private static func run(_ program: String, runner: any CommandRunner) async throws {
        let channel = try await runner.exec("/bin/sh -s")
        do {
            try await channel.write(Array(program.utf8))
            try await channel.closeInput()
            var output = Data()
            for try await bytes in channel.output { output.append(contentsOf: bytes) }
            guard String(decoding: output, as: UTF8.self).contains("HERDWICK_OK") else {
                throw WatchError.handoffFailed
            }
        } catch {
            await channel.close()
            throw error
        }
        await channel.close()
    }

    static func installer(_ config: Config, session: String, herdrPath: String) throws -> String {
        try check(session, allowed: safeName, "session")
        if !config.deviceToken.isEmpty || config.activity == nil {
            try check(config.deviceToken, allowed: "0123456789abcdef", "device token")
        }
        try check(config.environment, allowed: safeName, "environment")
        if !config.states.isEmpty { try check(config.states.joined(), allowed: safeName, "states") }
        if let activity = config.activity {
            try check(activity.pane, allowed: safeName + ":", "activity pane")
            try check(activity.token, allowed: "0123456789abcdef", "activity token")
        }
        try check(config.secret, allowed: "0123456789abcdef", "secret")
        for mute in config.mutes { try check(mute.pane, allowed: safeName + ":", "pane") }
        for held in config.held { try check(held.pane, allowed: safeName + ":", "held pane") }
        // Paths travel base64-encoded, so any character a folder may hold survives the env file.
        let transcripts = config.claudeTranscripts.filter { pane, path in
            pane.allSatisfy { (safeName + ":").contains($0) } && path.hasPrefix("/")
        }.sorted { $0.key < $1.key }.map { "\($0.key)|\(Data($0.value.utf8).base64EncodedString())" }.joined(separator: "\n")
        let held = config.held.map { held in
            let reference = held.reference.flatMap { $0.allSatisfy { safeName.contains($0) } ? $0 : nil } ?? ""
            return "\(held.pane)|\(held.seq)|\(max(0, held.deadline ?? 0))|\(held.alert ? 1 : 0)|\(reference)"
        }.joined(separator: "\n")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let mutes = try config.mutes.map {
            let encoded = String(decoding: try encoder.encode($0.reference), as: UTF8.self)
            return "\($0.pane)|\($0.expires)|\(Data(encoded.dropFirst().dropLast().utf8).base64EncodedString())"
        }.joined(separator: "\n")
        let relay = config.relay.absoluteString
        guard config.relay.scheme == "https", !relay.contains("'") else { throw WatchError.unsafe("relay") }
        let ttl = Int(config.ttl.components.seconds)
        return """
            set -e
            umask 077
            dir="$HOME/.herdwick/\(config.installationID.uuidString)-\(config.hostID.uuidString)"
            mkdir -p "$dir"
            # Stop a previous watcher first: on its way out it may clear these files.
            pid="$dir/watch.\(session).pid"
            if [ -f "$pid" ]; then
                old=$(cat "$pid")
                rm -f "$pid"
                kill "$old" 2>/dev/null || true
                n=0; while kill -0 "$old" 2>/dev/null && [ $n -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
                kill -0 "$old" 2>/dev/null && exit 1
            fi
            cat > "$dir/push.\(session).env" <<'HERDWICK_ENV'
            HW_URL='\(relay.hasSuffix("/") ? String(relay.dropLast()) : relay)'
            HW_TOKEN='\(config.deviceToken)'
            HW_ENV='\(config.environment)'
            HW_HOST='\(config.hostID.uuidString)'
            HW_STATES='\(config.states.joined(separator: " "))'
            HW_TTL=\(ttl)
            HW_SECRET='\(config.secret)'
            HW_MUTES='\(mutes)'
            HW_ACTIVITY_PANE='\(config.activity?.pane ?? "")'
            HW_ACTIVITY_TOKEN='\(config.activity?.token ?? "")'
            HW_HELD='\(held)'
            HW_CLAUDE='\(transcripts)'
            HERDWICK_ENV
            cat > "$dir/watch.sh.new.$$" <<'HERDWICK_WATCH'
            \(script)
            HERDWICK_WATCH
            mv "$dir/watch.sh.new.$$" "$dir/watch.sh"
            nohup /bin/sh "$dir/watch.sh" \(shellQuote(herdrPath)) \(session) >/dev/null 2>&1 </dev/null &
            echo $! > "$pid"
            sleep 0.1
            kill -0 "$(cat "$pid")"
            echo HERDWICK_OK
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
        dir=$(dirname "$0")
        . "$dir/push.$session.env" || exit 1
        run="$dir/run.$session.$$"
        mkdir -p "$run" || exit 1
        deadline=$(( $(date +%s) + ${HW_TTL:-86400} ))

        reap() { for child in $(pgrep -P "$1"); do reap "$child"; kill "$child" 2>/dev/null; done; }
        stop() {
            trap - TERM INT HUP
            reap $$
            rm -rf "$run"
            # Only remove this run's session files; never another owner's files.
            if [ "$(cat "$dir/watch.$session.pid" 2>/dev/null)" = $$ ]; then
                rm -f "$dir/watch.$session.pid" "$dir/push.$session.env"
            fi
            exit 0
        }
        trap stop TERM INT HUP

        field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

        # Activity updates are independent of ordinary alert toggles and conversation mutes.
        # The kind is domain-separated from alert MACs. APNs, not the NSE, consumes this payload.
        activity() {
            [ "$1" = "$HW_ACTIVITY_PANE" ] && [ -n "$HW_ACTIVITY_TOKEN" ] || return 0
            [ ! -e "$run/activity-ended" ] || return 0
            case $2 in working|blocked|done) ;; *) return 0 ;; esac
            case $3 in ''|*[!0-9]*) return 0 ;; esac
            mac=$(printf 'v1|liveactivity|%s|%s|%s|%s|%s' "$HW_HOST" "$session" "$1" "$2" "$3" |
                openssl dgst -sha256 -hmac "$HW_SECRET" 2>/dev/null | sed 's/^.*= //')
            auth=
            case "$mac" in ''|*[!0-9a-f]*) ;; *) [ ${#mac} -eq 64 ] && auth=",\"mac\":\"$mac\"" ;; esac
            curl -fsS -m 20 --retry 3 -o /dev/null -H 'content-type: application/json' \
                --data-binary @- "$HW_URL/v1/push" <<EOF || true
        {"kind":"liveactivity","token":"$HW_ACTIVITY_TOKEN","env":"$HW_ENV","host":"$HW_HOST","session":"$session","pane":"$1","state":"$2","seq":$3$auth}
        EOF
            [ "$2" != done ] || : > "$run/activity-ended"
        }

        post() {
            case " $HW_STATES " in *" $2 "*) ;; *) return 0 ;; esac
            case $3 in ''|*[!0-9]*) set -- "$1" "$2" 0 ;; esac
            ref=$(printf '%s\n' "$4" | sed -nE 's/.*"value":"(([^"\\]|\\.)*)".*/\1/p' | tr -d '\n' | base64 | tr -d '\n')
            now=$(date +%s)
            while IFS='|' read -r muted until reference; do
                if [ "$muted" = "$1" ] && [ "$reference" = "$ref" ] &&
                   { [ "$until" = 0 ] || [ "$until" -gt "$now" ]; }; then return 0; fi
            done <<MUTES
        $HW_MUTES
        MUTES
            mac=$(printf 'v1|%s|%s|%s|%s|%s' "$HW_HOST" "$session" "$1" "$2" "$3" |
                openssl dgst -sha256 -hmac "$HW_SECRET" 2>/dev/null | sed 's/^.*= //')
            auth=
            case "$mac" in ''|*[!0-9a-f]*) ;; *) [ ${#mac} -eq 64 ] && auth=",\"mac\":\"$mac\"" ;; esac
            curl -fsS -m 20 --retry 3 -o /dev/null -H 'content-type: application/json' \
                --data-binary @- "$HW_URL/v1/push" <<EOF || true
        {"token":"$HW_TOKEN","env":"$HW_ENV","host":"$HW_HOST","session":"$session","pane":"$1","state":"$2","seq":$3$auth}
        EOF
        }

        jsonpp=no
        perl -MJSON::PP -e1 >/dev/null 2>&1 && jsonpp=yes || :

        # `hold <seconds left>` when a Claude finish is a wake turn with background tasks still
        # running (`TurnSettle`), counted on this host's clock from when the transcript says the
        # turn ended; anything unknown alerts as before. A turn not yet written as ended gets one
        # more look 2 s on.
        settle() {
            sid=$(printf '%s\n' "$2" | sed -n 's/.*"agent_session":{[^}]*"agent":"claude"[^}]*"kind":"id"[^}]*"value":"\([A-Za-z0-9_-]*\)".*/\1/p')
            [ -n "$sid" ] || return 0
            file=
            while IFS='|' read -r p encoded; do
                [ "$p" = "$1" ] || continue
                path=$(printf '%s' "$encoded" | openssl base64 -d -A 2>/dev/null || :)
                case $path in */"$sid".jsonl) [ -r "$path" ] && file=$path ;; esac
            done <<CLAUDE
        $HW_CLAUDE
        CLAUDE
            if [ -z "$file" ]; then
                for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$sid".jsonl "$HOME"/.claude/projects/*/"$sid".jsonl; do
                    [ -r "$f" ] && { file=$f; break; }
                done
            fi
            [ -n "$file" ] || return 0
            f=$file
            set -- $(\#(TurnSettle.pipeline))
            # The finish seen was the person's own turn: a later look can't make it a wake.
            [ "$2" = human ] && return 0
            if [ "$3" != 1 ]; then sleep 2; set -- $(\#(TurnSettle.pipeline)); fi
            case $1$4$5 in ''|*[!0-9]*) return 0 ;; esac
            left=$(( ${HW_BACKSTOP:-600} - ($1 - $5) ))
            [ "$2" = wake ] && [ "$3" = 1 ] && [ "$4" -gt 0 ] && [ "$left" -gt 0 ] && echo "hold $left"
            return 0
        }

        # Alerts a held finish at its deadline unless the agent has moved on meanwhile (another
        # change, or another conversation in the pane: `$4`, when known). `$5` 0: its Live
        # Activity only. A herdr that can't say fails open: the alert goes.
        backstop() {
            # At least a second, so its record (written just after the fork) is there to remove.
            [ "$3" -ge 1 ] 2>/dev/null || set -- "$1" "$2" 1 "$4" "$5"
            ( sleep "$3"
              due=yes
              # Only what herdr clearly says otherwise stops it: another change, another
              # conversation, work under way. A field it doesn't give is no reason to drop the alert.
              if now=$("$herdr" --session "$session" agent get "$1" 2>/dev/null); then
                  s=$(field "$now" state_change_seq); case $s in ''|*[!0-9]*) ;; *) [ "$s" = "$2" ] || due=no ;; esac
                  v=$(field "$now" value); [ -z "$4" ] || [ -z "$v" ] || [ "$v" = "$4" ] || due=no
                  case $(field "$now" agent_status) in ''|idle|done) ;; *) due=no ;; esac
              else
                  case $now in *agent_not_found*|*pane_not_found*) due=no ;; esac
              fi
              if [ "$due" = yes ]; then
                  activity "$1" done "$2"
                  # Mutes match by conversation: the one known here when herdr didn't say.
                  [ -n "$(field "$now" value)" ] || [ -z "$4" ] || now="{\"agent_session\":{\"value\":\"$4\"}}"
                  [ "${5:-1}" = 0 ] || post "$1" done "$2" "$now"
              fi
              # Its record goes with it, so nothing later signals a pid the host has reused.
              [ "$(cut -d' ' -f2 "$run/hold.${1:?}" 2>/dev/null)" = "$2" ] && rm -f "$run/hold.${1:?}" ) &
            printf '%s %s\n' "$!" "$2" > "$run/hold.$1"
        }

        # Cancels a pane's held finish, if its timer still runs.
        unhold() {
            held_pid=$(cut -d' ' -f1 "$run/hold.${1:?}" 2>/dev/null || :)
            if [ -n "$held_pid" ]; then reap "$held_pid"; kill "$held_pid" 2>/dev/null; fi
            rm -f "$run/hold.${1:?}"
        }

        # One blocked wait at a time per pane: until it works, then until it stops.
        follow() {
            probe() {
                [ "$jsonpp" = yes ] || return 0
                agent_json=$1
                perl - "$agent_json" <<'PERL'
        use strict; use warnings; use JSON::PP; use Time::Local qw(timegm);
        my $x = eval { decode_json($ARGV[0]) } or exit;
        my @q = ($x);
        my $path;
        while (@q) {
            my $v = shift @q;
            next unless ref($v) eq 'HASH';
            if (($v->{agent} // '') eq 'omp' && ref($v->{agent_session}) eq 'HASH'
                && ($v->{agent_session}{kind} // '') eq 'path'
                && defined($v->{agent_session}{value})) {
                $path = $v->{agent_session}{value}; last;
            }
            push @q, values %$v;
        }
        exit unless defined($path) && -f $path;
        my $size = -s $path;
        open my $tail, '-|', 'tail', '-c', '262144', $path or exit;
        local $/;
        my $text = <$tail> // '';
        close $tail;
        my @lines = split /\n/, $text, -1;
        shift @lines if $size > 262144; # first tail line may be partial
        my (@records, $last);
        for my $line (@lines) {
            my $r = eval { decode_json($line) };
            next unless ref($r) eq 'HASH';
            push @records, $r;
            $last = $r if ($r->{type} // '') eq 'message';
        }
        exit unless $last && ref($last->{message}) eq 'HASH';
        my $m = $last->{message};
        if (($m->{role} // '') eq 'assistant' && ref($m->{content}) eq 'ARRAY'
            && @{$m->{content}}) {
            my $c = $m->{content}[-1];
            if (ref($c) eq 'HASH' && ($c->{type} // '') eq 'toolCall'
                && ($c->{name} // '') eq 'bash' && ref($c->{arguments}) eq 'HASH'
                && JSON::PP::is_bool($c->{arguments}{pty}) && $c->{arguments}{pty}) {
                my $id = $c->{id} // '';
                my $done = grep {
                    ref($_->{message}) eq 'HASH'
                    && ($_->{message}{role} // '') eq 'toolResult'
                    && ($_->{message}{toolCallId} // '') eq $id
                } @records;
                # omp stamps the message in epoch ms and the record in ISO 8601 UTC.
                my $at = defined($m->{timestamp}) ? int($m->{timestamp} / 1000) : undef;
                if (!defined($at) && ($last->{timestamp} // '') =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/) {
                    $at = timegm($6, $5, $4, $3, $2 - 1, $1);
                }
                unless ($done || !$id || !defined($at)) {
                    print "pty $id $at\n";
                    exit;
                }
            }
        }
        if (($m->{role} // '') eq 'toolResult' && !$m->{isError}
            && ($m->{toolName} // '') eq 'write' && ref($m->{content}) eq 'ARRAY') {
            my $text = join '', map { ref($_) eq 'HASH' ? ($_->{text} // '') : '' } @{$m->{content}};
            if ($text =~ s/^\s+|\s+$//gr eq 'Plan ready for review.') {
                my $id = $m->{toolCallId} // '';
                for my $r (@records) {
                    my $a = $r->{message};
                    next unless ref($a) eq 'HASH' && ($a->{role} // '') eq 'assistant'
                        && ref($a->{content}) eq 'ARRAY';
                    for my $c (@{$a->{content}}) {
                        if (ref($c) eq 'HASH' && ($c->{type} // '') eq 'toolCall'
                            && ($c->{id} // '') eq $id && ($c->{name} // '') eq 'write'
                            && ref($c->{arguments}) eq 'HASH'
                            && ($c->{arguments}{path} // '') eq 'xd://propose'
                            && length($c->{arguments}{content} // '')) {
                            print "plan $id\n"; exit;
                        }
                    }
                }
            }
        }
        PERL
            }

            while out=$("$herdr" --session "$session" agent wait "$1" --until working); do
                # Working again: a held finish (see `settle`) was not the end after all.
                unhold "$1"
                seq=$(field "$out" state_change_seq)
                activity "$1" working "$seq"
                wait_out="$run/wait.$1"
                if [ "$jsonpp" = yes ]; then
                    # Wait in the background so the transcript can be probed meanwhile; the
                    # wait cuts the current probe sleep short, so done alerts aren't delayed.
                    # It marks itself done before looking for the sleep, and a sleep is
                    # published before the mark is checked, so neither side misses the other.
                    done_mark="$run/done.$1"
                    rm -f "$done_mark"
                    (
                        "$herdr" --session "$session" agent wait "$1" >"$wait_out"
                        rc=$?
                        : > "$done_mark"
                        sleeper=$(cat "$run/sleep.$1" 2>/dev/null || :)
                        [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
                        exit $rc
                    ) &
                    wait_pid=$!
                    while [ ! -e "$done_mark" ] && kill -0 "$wait_pid" 2>/dev/null; do
                        sleep "${HW_PROBE:-15}" &
                        sleep_pid=$!
                        printf '%s\n' "$sleep_pid" > "$run/sleep.$1"
                        [ -e "$done_mark" ] && kill "$sleep_pid" 2>/dev/null
                        wait "$sleep_pid" || :
                        rm -f "$run/sleep.$1"
                        if [ -e "$done_mark" ] || ! kill -0 "$wait_pid" 2>/dev/null; then break; fi
                        result=$(probe "$out" 2>/dev/null || :)
                        IFS=' ' read -r kind tool_id timestamp <<EOF
        $result
        EOF
                        if [ "$kind" = pty ] && [ -n "$tool_id" ] && [ -n "$timestamp" ] &&
                           [ "$(($(date +%s) - $timestamp))" -ge 10 ]; then
                            id=$(printf '%s' "$tool_id" | tr -cd 'A-Za-z0-9._-')
                            marker="$run/pty.$id"
                            if [ -n "$id" ] && [ ! -e "$marker" ]; then
                                screen=$("$herdr" --session "$session" pane read "$1" --source visible --format text 2>/dev/null || :)
                                if printf '%s\n' "$screen" | grep -F '⟨running⟩' >/dev/null &&
                                   printf '%s\n' "$screen" | grep -F 'input forwarded to PTY' >/dev/null; then
                                    # From the command on: the spinner before it turns between reads.
                                    overlay=$(printf '%s\n' "$screen" | awk '/⟨running⟩/{take=1; i=index($0, "Console "); if (i) $0=substr($0, i)} take{print} /input forwarded to PTY/{exit}')
                                    checksum=$(printf '%s\n' "$overlay" | cksum)
                                    previous=$(cat "$run/pty.$id.check" 2>/dev/null || :)
                                    printf '%s\n' "$checksum" > "$run/pty.$id.check"
                                    if [ -n "$previous" ] && [ "$previous" = "$checksum" ]; then
                                        : > "$marker"
                                        activity "$1" blocked "$seq"
                                        post "$1" blocked "$seq" "$out"
                                    fi
                                else
                                    rm -f "$run/pty.$id.check"
                                fi
                            fi
                        fi
                    done
                    wait "$wait_pid" || break
                    rm -f "$done_mark"
                    out=$(cat "$wait_out")
                else
                    out=$("$herdr" --session "$session" agent wait "$1") || break
                fi
                state=$(field "$out" agent_status)
                [ "$state" = idle ] && state=done
                # Only omp has a Plan Review to look for; a Claude finish goes straight to `settle`.
                case $out in *'"agent":"omp"'*) omp=yes ;; *) omp=no ;; esac
                if [ "$state" = done ] && [ "$jsonpp" = yes ] && [ "$omp" = yes ]; then
                    plan=$(probe "$out" 2>/dev/null || :)
                    if [ -z "$plan" ]; then sleep 2; plan=$(probe "$out" 2>/dev/null || :); fi
                    case $plan in plan\ *) state=blocked ;; esac
                fi
                final_seq=$(field "$out" state_change_seq)
                held=
                [ "$state" = done ] && held=$(settle "$1" "$out")
                if [ -n "$held" ]; then
                    # A background task woke Claude and others still run: their last one alerts,
                    # or, ten minutes after this turn ended with nothing new, this one does.
                    backstop "$1" "$final_seq" "${held#hold }" "$(field "$out" value)"
                else
                    activity "$1" "$state" "$final_seq"
                    post "$1" "$state" "$final_seq" "$out"
                fi
                rm -f "$wait_out"
            done
            # The agent is gone: so is any finish held for it.
            unhold "$1"
            rm -f "$run/${1:?}"
        }

        # Finishes the app was holding (or still checking) as it left keep their deadlines here,
        # beside the panes' own followers rather than ahead of them. (`due_at`, not `deadline`:
        # that is this watcher's own lifetime.)
        (
        while IFS='|' read -r pane seq due_at alert reference; do
            case $pane in ''|*[!A-Za-z0-9:._-]*) continue ;; esac
            case $seq$due_at$alert in ''|*[!0-9]*) continue ;; esac
            if [ "$due_at" = 0 ]; then
                # As `backstop`: only what herdr clearly says otherwise drops it.
                if ! now=$("$herdr" --session "$session" agent get "$pane" 2>/dev/null); then
                    case $now in *agent_not_found*|*pane_not_found*) continue ;; esac
                    activity "$pane" done "$seq"
                    [ -z "$reference" ] || now="{\"agent_session\":{\"value\":\"$reference\"}}"
                    [ "$alert" = 0 ] || post "$pane" done "$seq" "$now"
                    continue
                fi
                s=$(field "$now" state_change_seq); case $s in ''|*[!0-9]*) ;; *) [ "$s" = "$seq" ] || continue ;; esac
                v=$(field "$now" value); [ -z "$reference" ] || [ -z "$v" ] || [ "$v" = "$reference" ] || continue
                case $(field "$now" agent_status) in ''|idle|done) ;; *) continue ;; esac
                # Mutes match by conversation: the one handed over when herdr didn't say.
                [ -n "$v" ] || [ -z "$reference" ] || now="{\"agent_session\":{\"value\":\"$reference\"}}"
                held=$(settle "$pane" "$now")
                # The scan takes time: if the pane has moved on meanwhile, its follower has it.
                again=$("$herdr" --session "$session" agent get "$pane" 2>/dev/null) && {
                    s=$(field "$again" state_change_seq); case $s in ''|*[!0-9]*) ;; *) [ "$s" = "$seq" ] || continue ;; esac
                    case $(field "$again" agent_status) in ''|idle|done) ;; *) continue ;; esac
                }
                if [ -n "$held" ]; then
                    backstop "$pane" "$seq" "${held#hold }" "$(field "$now" value)" "$alert"
                else
                    activity "$pane" done "$seq"
                    [ "$alert" = 0 ] || post "$pane" done "$seq" "$now"
                fi
            else
                left=$((due_at - $(date +%s)))
                [ "$left" -gt 0 ] || left=0
                backstop "$pane" "$seq" "$left" "$reference" "$alert"
            fi
        done <<HELD
        $HW_HELD
        HELD
        # Its timers stay its children, so stopping the watcher reaps them too.
        wait
        ) &

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
