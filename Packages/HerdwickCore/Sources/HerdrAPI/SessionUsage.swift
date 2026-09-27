import Foundation

extension HerdrClient {
    /// Usage over the whole transcript file, totalled on the host so a long session costs one
    /// short reply instead of a download. Counts the same fields as `TranscriptRecord.decode`:
    /// omp and Claude assistant `usage` (Claude deduplicated by API message id, last copy wins),
    /// and Codex's cumulative `total_token_usage` from its latest `token_count`. omp sums every
    /// branch, abandoned ones included, since they were still spent. `nil` when nothing is recorded.
    public func sessionUsage(path: String, format: TranscriptFormat) async throws -> TranscriptUsage? {
        let script = "f=" + shellQuote(path) + #"; [ -r "$f" ] || exit 0; LC_ALL=C awk -v fmt="#
            + format.rawValue + " " + shellQuote(Self.usageScript) + #" "$f""#
        return Self.parseUsage(try await Self.collect(try await runner.exec(Self.posix(script))))
    }

    /// POSIX awk (BSD and GNU alike): bracketed braces and no interval expressions.
    static let usageScript = #"""
    function n(s, k) { return match(s, "\"" k "\":[0-9]+") ? substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3) + 0 : 0 }
    fmt == "codex" { if (match($0, /"total_token_usage":[{][^}]*[}]/)) { u = substr($0, RSTART, RLENGTH); ti = n(u, "input_tokens"); to = n(u, "output_tokens"); seen = 1 }; next }
    /"role":"assistant"/ && match($0, /"usage":[{][^{}]*([{][^{}]*[}][^{}]*)*[}]/) {
        u = substr($0, RSTART, RLENGTH); seen = 1
        if (fmt == "omp") {
            ti += n(u, "input") + n(u, "cacheRead") + n(u, "cacheWrite"); to += n(u, "output")
            if (match(u, /"cost":[{][^}]*[}]/)) { c = substr(u, RSTART, RLENGTH); if (match(c, /"total":[0-9.eE+-]+/)) { tc += substr(c, RSTART + 8, RLENGTH - 8); hc = 1 } }
        } else {
            id = match($0, /"id":"msg_[^"]*"/) ? substr($0, RSTART, RLENGTH) : "#" NR
            if (!(id in ci)) ids[++m] = id
            ci[id] = n(u, "input_tokens") + n(u, "cache_read_input_tokens") + n(u, "cache_creation_input_tokens"); co[id] = n(u, "output_tokens")
        }
    }
    END { for (j = 1; j <= m; j++) { ti += ci[ids[j]]; to += co[ids[j]] }; if (seen) printf "%.0f %.0f %s\n", ti, to, hc ? sprintf("%.6f", tc) : "-" }
    """#

    static func parseUsage(_ data: [UInt8]) -> TranscriptUsage? {
        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, let input = Int(fields[0]), let output = Int(fields[1]) else { return nil }
        return .init(inputTokens: input, outputTokens: output, cost: Double(fields[2]))
    }
}
