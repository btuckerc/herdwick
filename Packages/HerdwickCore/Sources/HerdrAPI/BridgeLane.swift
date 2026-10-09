import Foundation
import Synchronization

/// One long-lived loop on the host that carries a session's API requests. A request then
/// costs one round trip, instead of opening a channel, starting the user's login shell and
/// a `herdr remote-api-bridge`, and waiting on each.
///
/// With perl on the host (macOS and most Linux), the loop connects to the session's API
/// socket itself and writes each request in one go: no process per request, and herdr's
/// first read finds the whole line. herdr reads a new connection's request with non-blocking
/// reads and sleeps 100 ms whenever nothing is there yet, which `remote-api-bridge`
/// (connect first, then copy stdin) hits on most requests. Without perl, or a herdr too old
/// to report its socket, each request runs its own `remote-api-bridge`, as before.
///
/// A new lane carries its first request in the command line: OpenSSH opens a session
/// channel's window only once it has started the command, so stdin costs a round trip more.
/// The fallback loop can't decode it and asks for it again (`resend`); it hasn't run.
///
/// Requests run one at a time, in arrival order. Each answers with at most one JSON line
/// (errors arrive as other lines) and then a status line: `\u{1E}<exit status>`. A request
/// whose outcome is unknown (timeout, cancellation, the lane dying mid-request) fails and is
/// never resent; the next request opens a new lane.
actor BridgeLane {
    /// Ends each request's here-document in the fallback loop; a scripted host recognises a
    /// lane by it.
    static let marker = "HERDWICK_REQUEST"
    /// The host's answer to a request carried in the command line that it couldn't decode.
    static let resend: [UInt8] = [0x1E, UInt8(ascii: "r")]
    /// Requests up to this size ride in the command line, hex-encoded.
    static let embedLimit = 8 * 1024

    /// `IO::Socket::UNIX` is core perl. No backslash pairs or single quotes: fish, as the
    /// login shell, would rewrite them inside the quoted script.
    static let perl = #"""
        use IO::Socket::UNIX; $| = 1; my ($k, $f) = @ARGV; my @q = length $f ? (pack("H*", $f)) : ();
        while (defined(my $r = @q ? shift @q : <STDIN>)) {
          my $c = IO::Socket::UNIX->new(Peer => $k);
          unless ($c) { print "herdr: cannot reach $k: $!\n\x1e1\n"; next }
          my $o = 0;
          while ($o < length $r) { my $n = syswrite($c, $r, length($r) - $o, $o); last unless $n; $o += $n }
          my $l = <$c>; close $c;
          if (defined $l) { $l .= "\n" unless $l =~ /\n\z/; print $l, "\x1e0\n" } else { print "\x1e1\n" }
        }
        """#

    /// A two-way stream to the socket (a subscription) that writes its first request at once.
    static let forwarder = #"""
        use IO::Socket::UNIX; my ($k, $f) = @ARGV;
        my $c = IO::Socket::UNIX->new(Peer => $k) or do { print STDERR "herdr: cannot reach $k: $!\n"; exit 1 };
        sub put { my ($h, $b) = @_; my $o = 0; while ($o < length $b) { my $n = syswrite($h, $b, length($b) - $o, $o); return 0 unless $n; $o += $n } 1 }
        put($c, pack("H*", $f)) or exit 1;
        my $p = fork; defined $p or exit 1;
        unless ($p) { while (sysread(STDIN, my $b, 65536)) { put($c, $b) or last } shutdown($c, 1); exit 0 }
        while (sysread($c, my $b, 65536)) { put(*STDOUT, $b) or last }
        kill "TERM", $p; exit 0;
        """#

    /// Finds the session's socket for perl, or falls through to the lines after it.
    private static func prelude(herdr: String, session: String, first: [UInt8]?, perl script: String) -> String {
        """
        h=\(shellQuote(herdr)) s=\(shellQuote(session)) herdwick_first=\(first.map(hex) ?? "")
        k=$("$h" --session "$s" status server 2>/dev/null | sed -n 's/^socket: //p')
        if [ -n "$k" ] && command -v perl >/dev/null 2>&1; then exec perl -e \(shellQuote(script)) "$k" "$herdwick_first"; fi
        [ -z "$herdwick_first" ] || printf '\\036r\\n'
        """
    }

    /// A subscription's command: its request (`first`) written as soon as the socket connects.
    /// Without perl the host answers `resend` and the caller writes the request to stdin.
    static func streamCommand(herdr: String, session: String, first: [UInt8]?) -> String {
        HerdrClient.posix(prelude(herdr: herdr, session: session, first: first, perl: forwarder)
            + "\nexec \"$h\" --session \"$s\" remote-api-bridge")
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private let runner: any CommandRunner
    private let herdr: String
    private let session: String
    private var open: Open?
    private var generation = 0
    private var busy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiter = 0

    private struct Open {
        let generation: Int
        let channel: any ExecChannel
        let frames: LaneFrames
    }

    init(runner: any CommandRunner, herdr: String, session: String) {
        self.runner = runner
        self.herdr = herdr
        self.session = session
    }

    private func command(first: [UInt8]?) -> String {
        HerdrClient.posix(Self.prelude(herdr: herdr, session: session, first: first, perl: Self.perl) + """

            while IFS= read -r r; do
              "$h" --session "$s" remote-api-bridge 2>&1 <<\(Self.marker)
            $r
            \(Self.marker)
              printf '\\036%s\\n' "$?"
            done
            """)
    }

    /// Sends one request line (newline included) carrying `id` and returns herdr's response line.
    func send(_ request: [UInt8], id: String, timeout: Duration) async throws -> [UInt8] {
        try await acquire()
        defer { release() }
        if let open, open.frames.ended {
            // The lane ended while idle (host restart, channel timeout): nothing of this
            // request has been sent, so a fresh lane takes it.
            discard(open.generation)
        }
        let lane: Open
        let embedded: Bool
        if let open {
            lane = open
            embedded = false
        } else {
            embedded = request.count <= Self.embedLimit
            let channel = try await runner.exec(command(first: embedded ? request : nil))
            generation += 1
            lane = Open(generation: generation, channel: channel, frames: LaneFrames(channel.output))
            open = lane
        }
        let frame: LaneFrames.Frame
        do {
            frame = try await HerdrClient.finite(lane.channel, timeout: timeout) { [lane] in
                if !embedded { try await lane.channel.write(request) }
                var frame = try await lane.frames.next()
                if embedded, frame.resend {
                    try await lane.channel.write(request)
                    frame = try await lane.frames.next()
                }
                return frame
            }
        } catch {
            discard(lane.generation)
            throw error
        }
        guard let response = frame.response, !frame.resend else {
            if frame.status != 0 { throw CommandError.exited(status: frame.status, stderr: frame.stderr) }
            throw HerdrError.noResponse
        }
        struct Envelope: Decodable { var id: String? }
        guard (try? JSONDecoder().decode(Envelope.self, from: Data(response)))?.id == id else {
            // Out of step with the host: nothing more on this lane can be trusted.
            discard(lane.generation)
            throw HerdrError.malformed(String(decoding: response.prefix(200), as: UTF8.self))
        }
        return response
    }

    private func discard(_ generation: Int) {
        guard let open, open.generation == generation else { return }
        self.open = nil
        let channel = open.channel
        Task { await channel.close() }
    }

    // MARK: One request at a time

    private func acquire() async throws {
        guard busy else {
            busy = true
            return
        }
        let id = nextWaiter
        nextWaiter += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Cancellation that lands before the waiter is queued is caught here.
    private func enqueue(_ id: Int, _ continuation: CheckedContinuation<Void, any Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiters.append((id, continuation))
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the lane straight to the next waiter, which inherits `busy`.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// Splits a lane's output into one frame per request, read as it arrives so an idle lane's
/// end shows before the next request is sent.
final class LaneFrames: Sendable {
    struct Frame: Sendable {
        var response: [UInt8]?
        var status: Int32 = 0
        var stderr = ""
        /// The host couldn't take the request from the command line (`BridgeLane.resend`).
        var resend = false
    }

    private struct State {
        var frames: [Frame] = []
        var end: (any Error)?
        var waiter: CheckedContinuation<Frame, any Error>?
    }

    private let state = Mutex(State())

    init(_ output: AsyncThrowingStream<[UInt8], any Error>) {
        // Holds `self` until the output finishes, which closing the channel guarantees.
        Task { [self] in
            var lines = LineSplitter()
            var frame = Frame()
            var end: any Error = HerdrError.noResponse
            do {
                for try await chunk in output {
                    for line in lines.append(chunk) {
                        if line == BridgeLane.resend {
                            deliver(Frame(resend: true))
                        } else if line.first == 0x1E {
                            frame.status = Int32(String(decoding: line.dropFirst(), as: UTF8.self)) ?? -1
                            deliver(frame)
                            frame = Frame()
                        } else if frame.response == nil, line.first == UInt8(ascii: "{") {
                            frame.response = line
                        } else if frame.stderr.utf8.count < 4096 {
                            frame.stderr += String(decoding: line, as: UTF8.self) + "\n"
                        }
                    }
                }
            } catch {
                end = error
            }
            let waiter = state.withLock { [end] state in
                state.end = end
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: end)
        }
    }

    private func deliver(_ frame: Frame) {
        let waiter = state.withLock { state -> CheckedContinuation<Frame, any Error>? in
            guard let waiter = state.waiter else {
                state.frames.append(frame)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: frame)
    }

    /// The output has finished: the loop on the host is gone.
    var ended: Bool { state.withLock { $0.end != nil } }

    /// The next request's frame. One caller at a time: the lane admits one request.
    func next() async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Frame, any Error>? = state.withLock { state in
                if !state.frames.isEmpty { return .success(state.frames.removeFirst()) }
                if let end = state.end { return .failure(end) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
