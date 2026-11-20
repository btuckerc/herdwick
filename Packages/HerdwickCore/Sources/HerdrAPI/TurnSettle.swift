import Foundation

/// Whether a Claude conversation's latest finished turn is one worth an alert ("settled"), read
/// from its whole transcript on the host by one POSIX `awk` program that both the app and the
/// away watcher run, so the two never disagree about the same turn.
///
/// Claude Code 2.1 marks every user record with `turnOrigin`: `human` for the person's own
/// prompt, `task_notification` for a background task waking the agent. A turn the person
/// started always alerts when it ends. A wake turn alerts only once nothing launched since that
/// prompt is still running: background commands (`backgroundTaskId`) launched in the three hours
/// before the turn ended, closed by a `<task-notification>` naming the task (any status) or a
/// `task_status` that isn't running. A prompt in between (a check-in mid-council) doesn't forget
/// them.
/// So a council's seats finishing one by one wake the agent without an alert each; the last one
/// alerts. A held finish still alerts after `backstop` (a dev server, a killed task, a restart
/// that never reports): a delay, never silence. Only keys written unescaped count, so the
/// same text quoted inside tool output can't match.
public struct TurnSettle: Sendable, Equatable {
    public enum Origin: String, Sendable { case human, wake, none }
    public let origin: Origin
    /// A `turn_duration` follows the newest user record: the turn is over.
    public let ended: Bool
    /// Background tasks launched in the three hours before the turn ended, not yet reported done.
    public let pending: Int
    /// When the turn ended, by the host's clock.
    public let endedAt: Date?
    /// The host's clock when it scanned, so the backstop counts in host time whatever this
    /// device's clock says.
    public let hostNow: Date?
    /// This device's clock when the scan came back.
    public let scannedAt: Date

    public static let backstop: TimeInterval = 600

    public init(origin: Origin, ended: Bool, pending: Int, endedAt: Date?, hostNow: Date? = nil, scannedAt: Date = .now) {
        self.origin = origin; self.ended = ended; self.pending = pending; self.endedAt = endedAt
        self.hostNow = hostNow; self.scannedAt = scannedAt
    }

    /// Seconds since the turn ended at `now`, in host time; nil without an end time.
    public func age(now: Date = .now) -> TimeInterval? {
        guard let endedAt else { return nil }
        guard let hostNow else { return now.timeIntervalSince(endedAt) }
        return hostNow.timeIntervalSince(endedAt) + now.timeIntervalSince(scannedAt)
    }

    /// The finish waits for more work: a wake turn ended with tasks still running, not yet past
    /// the backstop. Anything else (a human turn, a transcript without `turnOrigin`, a turn the
    /// file doesn't show ending, or one without a time to count the backstop from) alerts as
    /// before. The watcher's `settle` applies the same test to the same scan, on the same clock.
    public func holds(now: Date = .now) -> Bool {
        guard origin == .wake, ended, pending > 0, let age = age(now: now) else { return false }
        return age < Self.backstop
    }

    /// When a held finish alerts anyway, on this device's clock.
    public func releaseAt(now: Date = .now) -> Date? { age(now: now).map { now.addingTimeInterval(Self.backstop - $0) } }

    /// `<host now> <origin> <ended 0|1> <pending> <endedAt|->`, times in epoch seconds.
    public static func parse(_ text: String, scannedAt: Date = .now) -> TurnSettle? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5, let origin = Origin(rawValue: String(fields[1])),
              let ended = Int(fields[2]), let pending = Int(fields[3]) else { return nil }
        func date(_ field: Substring) -> Date? { Int(field).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        return TurnSettle(origin: origin, ended: ended == 1, pending: pending, endedAt: date(fields[4]),
                          hostNow: date(fields[0]), scannedAt: scannedAt)
    }

    /// Lines that can matter, picked by `grep -F` so the long image and output lines between
    /// them cost a byte scan, not a regex each.
    static let keys = [#""turnOrigin":""#, #""commandMode":""#, #""type":"task_status""#,
                       #""backgroundTaskId":""#, #""subtype":"turn_duration""#, #""type":"user""#]

    /// Prints one `parse`-able line for the file on stdin.
    public static let awk = #"""
        # UTC "YYYY-MM-DDTHH:MM:SS…" as epoch seconds (days from the civil date), else "".
        function epoch(t,   y, m, d, h, mi, sec, mp, era, yoe, doe, dim) {
            if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?Z$/) return ""
            y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
            h = substr(t, 12, 2) + 0; mi = substr(t, 15, 2) + 0; sec = substr(t, 18, 2) + 0
            if (m < 1 || m > 12 || d < 1 || h > 23 || mi > 59 || sec > 60) return ""
            dim = substr("312831303130313130313031", m * 2 - 1, 2) + 0
            if (m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))) dim = 29
            if (d > dim) return ""
            if (m <= 2) y--
            era = int(y / 400); yoe = y - era * 400; mp = (m + 9) % 12
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + int((153 * mp + 2) / 5) + d - 1
            return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec
        }
        function stamp() { if (match($0, /"timestamp":"[^"]*"/)) return epoch(substr($0, RSTART + 13, RLENGTH - 14)); return "" }
        # Every task the line reports ended (a notification can carry several).
        function settle(   rest, id) {
            rest = $0
            while (match(rest, /<task-id>[A-Za-z0-9_-]+<\/task-id>/)) {
                id = substr(rest, RSTART + 9, RLENGTH - 19); if (id in pend) delete pend[id]
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
        # A launch first, whatever else its record says.
        /"backgroundTaskId":"/ {
            if (match($0, /"backgroundTaskId":"[A-Za-z0-9_-]+"/)) { id = substr($0, RSTART + 20, RLENGTH - 21); if (!(id in pend)) pend[id] = "@" stamp() }
        }
        # The person's own words: a prompt, or one typed mid-turn (a queued prompt).
        /"turnOrigin":"human"/ || /"commandMode":"prompt"/ { origin = "human"; ended = 0; endat = ""; next }
        /"turnOrigin":"task_notification"/ || /"commandMode":"task-notification"/ {
            if ($0 ~ /"turnOrigin":"task_notification"/) { origin = "wake"; ended = 0 }
            settle()
            next
        }
        # An origin this scan doesn't know: not a turn it understands.
        /"turnOrigin":"/ { origin = "none"; ended = 0; next }
        /"type":"task_status"/ {
            if (match($0, /"taskId":"[A-Za-z0-9_-]+"/)) {
                id = substr($0, RSTART + 10, RLENGTH - 11)
                if ($0 !~ /"status":"running"/ && (id in pend)) delete pend[id]
            }
            next
        }
        /"subtype":"turn_duration"/ { ended = 1; endat = stamp(); next }
        # A prompt with no origin at all (an interrupt; not a tool result, a reminder or a
        # compaction's summary): not a turn this scan understands, so it alerts as before.
        /"type":"user"/ {
            ended = 0
            if ($0 !~ /"tool_result"/ && $0 !~ /"isMeta":true/ && $0 !~ /"isCompactSummary":true/ && $0 !~ /"turnOrigin":"/) origin = "none"
        }
        END {
            # Running when the turn ended, and launched within the three hours before: a task
            # that never reported (a restart, a kill) stops counting rather than hold forever.
            n = 0
            for (id in pend) { at = substr(pend[id], 2); if (at == "" || endat == "" || endat - at < 10800) n++ }
            print (origin == "" ? "none" : origin), ended + 0, n, (endat == "" ? "-" : endat)
        }
        """#

    /// The shell pipeline over the file named by `$f`.
    /// Prefixed with the host's own clock, which the backstop counts in.
    public static var pipeline: String {
        #"printf '%s ' "$(date +%s)"; LC_ALL=C grep -F "# + keys.map { "-e " + shellQuote($0) }.joined(separator: " ") + #" -- "$f" | LC_ALL=C awk "# + shellQuote(awk)
    }
}

extension HerdrClient {
    /// `TurnSettle` for one Claude transcript; nil when it can't be read.
    public func turnSettle(path: String) async throws -> TurnSettle? {
        let script = "f=" + shellQuote(path) + #"; [ -r "$f" ] || exit 0; "# + TurnSettle.pipeline
        return TurnSettle.parse(String(decoding: try await Self.collect(try await runner.exec(Self.posix(script))), as: UTF8.self))
    }
}
