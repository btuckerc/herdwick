import Foundation

/// When an agent's conversation last moved for the person following it: the user sent a
/// message (a prompt or a steer mid-turn), or the agent finished a turn. Thinking, narration
/// between tool calls, tool calls and their results are work inside a turn and don't count;
/// harness text never becomes a message at all. Also tracks how far the file has been read.
/// Transcripts are append-only (omp's padded title line is rewritten in place at the same
/// size), so each refresh reads only what was appended since.
///
/// A first read takes the file's tail; when that holds no such moment (one long tool run,
/// say), it pages backwards until it finds one or reaches the start. File times are never
/// used: tool output and title rewrites change them without a message.
public struct TranscriptActivity: Codable, Sendable, Equatable {
    public static let window = 256 * 1024
    /// Backward pages read before giving up on an old conversation's last turn.
    static let maxLookBackPages = 8

    public let path: String
    public let format: TranscriptFormat
    /// The newest user message or turn end, by the transcript's own clock; nil while unknown.
    public private(set) var lastTurnAt: Date?
    /// Newest observed user/assistant text, independently of turn-completion time.
    public private(set) var preview: String?
    public private(set) var previewAt: Date?
    /// The preview's message's closing warning callout, if any (`caution(_:)`).
    public private(set) var caution: String?
    /// The newest record's own time, work inside a turn included: when a blocked agent started
    /// waiting (its question or approval is the last thing it wrote).
    public private(set) var activityAt: Date?
    /// The newest unanswered tool call in the Now line's words ("Running swift test",
    /// "Editing Store.swift"); nil once its result, the user or the turn's end follows it.
    public private(set) var step: String?
    private var stepCall: String?
    /// End of the last complete line read; appends are read from here. Nil before the first read.
    public private(set) var offset: Int?
    /// While looking back for a message: the end of the next page, and pages read so far.
    private var lookBack: LookBack?
    /// The last forward read filled its limit, so more is already waiting.
    private var behind = false
    /// `offset` sits inside a line longer than a whole read; the next read skips to its end.
    private var midLine = false

    struct LookBack: Codable, Sendable, Equatable {
        var end: Int
        var pages: Int
    }

    public init(path: String, format: TranscriptFormat) {
        self.path = path
        self.format = format
    }

    public struct Read: Sendable, Equatable {
        /// Byte offset to start at; nil reads the last `limit` bytes.
        public let from: Int?
        public let limit: Int
    }

    /// The next range to read. A caught-up transcript still reads from its end, which costs
    /// only the size check.
    public var nextRead: Read {
        if let lookBack {
            let from = max(0, lookBack.end - Self.window)
            return Read(from: from, limit: lookBack.end - from)
        }
        guard let offset else { return Read(from: nil, limit: Self.window) }
        return Read(from: offset, limit: Self.forwardLimit)
    }

    static let forwardLimit = window * 4

    /// Another read would find more right away: a backward search or a backlog of appends.
    public var needsMore: Bool { lookBack != nil || behind }

    /// Backward preview searches must never be appended to a warm conversation.
    public var isLookingBack: Bool { lookBack != nil }

    /// Takes the bytes `nextRead` asked for. `size` is the file's size (nil: no such file
    /// yet, as omp creates its transcript on the first message); `from` where `bytes` start.
    public mutating func absorb(size: Int?, from: Int, bytes: [UInt8]) {
        guard let size else {
            self = TranscriptActivity(path: path, format: format)
            return
        }
        if let lookBack {
            // Older pages: the tail already read set where the work stands now.
            let (found, _, text, at, _) = Self.scanDetails(bytes, format: format, startsMidFile: from > 0, flush: true)
            absorbPreview(text, at: at)
            lastTurnAt = found
            self.lookBack = found == nil && from > 0 && lookBack.pages + 1 < Self.maxLookBackPages
                ? LookBack(end: from + Self.partialLineLength(bytes), pages: lookBack.pages + 1) : nil
            return
        }
        guard let offset else {
            // First read: the tail. Its last line may still be being written; counting it now
            // is harmless, as it is read again from `offset` once complete.
            let (found, consumed, text, at, entries) = Self.scanDetails(bytes, format: format, startsMidFile: from > 0, flush: true)
            absorbPreview(text, at: at)
            absorbWork(entries)
            lastTurnAt = found
            self.offset = from + consumed
            if found == nil, from > 0 { lookBack = LookBack(end: from + Self.partialLineLength(bytes), pages: 0) }
            return
        }
        if size < offset {
            // Truncated or replaced: whatever it holds now is a different history.
            self = TranscriptActivity(path: path, format: format)
            return
        }
        let (found, consumed, text, at, entries) = Self.scanDetails(bytes, format: format, startsMidFile: midLine, flush: false)
        absorbPreview(text, at: at)
        absorbWork(entries)
        if let found { lastTurnAt = max(lastTurnAt ?? found, found) }
        let full = bytes.count >= Self.forwardLimit
        if consumed == 0, full {
            // One line fills the whole read: step past it rather than rereading it forever.
            self.offset = offset + bytes.count
            midLine = true
        } else {
            self.offset = offset + consumed
            if consumed > 0 { midLine = false }
        }
        behind = full
    }

    /// The newest user message or turn end among `bytes`' complete lines, and the bytes those
    /// lines span. `flush` also parses a final line that lacks its newline.
    static func scan(_ bytes: [UInt8], format: TranscriptFormat, startsMidFile: Bool, flush: Bool) -> (Date?, Int) {
        let result = scanDetails(bytes, format: format, startsMidFile: startsMidFile, flush: flush)
        return (result.0, result.1)
    }

    private mutating func absorbPreview(_ text: (text: String, caution: String?)?, at: Date?) {
        guard let text else { return }
        if preview == nil || (at != nil && (previewAt == nil || at! >= previewAt!)) {
            preview = text.text; caution = text.caution; previewAt = at
        }
    }

    /// Follows `activityAt` and `step` through records in file order.
    private mutating func absorbWork(_ entries: [TranscriptEntry]) {
        for entry in entries {
            switch entry {
            case .message(let message):
                if let at = message.timestamp { activityAt = max(activityAt ?? at, at) }
                switch message.role {
                case .user: step = nil; stepCall = nil
                case .toolResult:
                    if message.toolCallId == stepCall { step = nil; stepCall = nil }
                case .assistant:
                    guard !message.toolCalls.isEmpty else { continue }
                    var conversation = Conversation()
                    conversation.apply(.message(message))
                    guard let tool = conversation.runningTools.first else { continue }
                    // A bare `wait` names nothing a row can use; the row keeps its preview.
                    step = tool.name == "wait" ? nil : StepRun([.tool(tool)]).running
                    stepCall = tool.id
                }
            case .turnEnded(let at):
                if let at { activityAt = max(activityAt ?? at, at) }
                step = nil; stepCall = nil
            default: break
            }
        }
    }

    private static func scanDetails(_ bytes: [UInt8], format: TranscriptFormat, startsMidFile: Bool, flush: Bool) -> (Date?, Int, (text: String, caution: String?)?, Date?, [TranscriptEntry]) {
        var reader = TranscriptReader(format: format, startsMidFile: startsMidFile)
        var entries = reader.append(bytes)
        // This reader is recreated each scan; leave an unterminated skipped line to
        // `absorb`'s midLine paging logic rather than treating it as a complete record.
        let consumed = startsMidFile && !bytes.contains(0x0A) ? 0 : reader.consumedBytes
        if flush { entries += reader.append([0x0A]) }
        let newest = entries.compactMap { entry -> Date? in
            switch entry {
            case .message(let message) where message.role == .user:
                message.images.isEmpty && !message.text.contains { !$0.isWhitespace } ? nil : message.timestamp
            case .turnEnded(let at): at
            default: nil
            }
        }.max()
        var preview: (text: String, caution: String?)?, previewAt: Date?
        for entry in entries {
            guard case .message(let message) = entry, message.role != .toolResult,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if preview == nil || message.timestamp == nil || previewAt == nil || message.timestamp! >= previewAt! {
                preview = (previewLine(message.text), caution(message.text))
                previewAt = message.timestamp
            }
        }
        return (newest, consumed, preview, previewAt, entries)
    }

    /// A message's closing warning callout on one line ("Before deploying: apply 0042 first; …"),
    /// for a row whose verdict alone would read as all clear (round 41: sa#1, sb#1, opus#2, "No
    /// blocking findings in PR #412" hid "apply 0042 first"). Only a final top-level paragraph
    /// counts, as the Done card moves only that one under its verdict, and only its first
    /// sentence, the thing to do (round 53: sb#10, opus#3, "I left the working tree unchanged"
    /// took a third loud line in every row). Up to 140 characters: rows give it two lines
    /// (round 42: at 90 it was cut before "need team IDs").
    public static func caution(_ text: String) -> String? {
        guard let last = text.components(separatedBy: "\n\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty }), isWarningCallout(last) else { return nil }
        let first = last.firstMatch(of: /\.\s+(?=[A-Z])/).map { String(last[..<$0.range.lowerBound]) + "." } ?? last
        return previewLine(first, limit: 140)
    }

    /// A paragraph led by a bold label naming a warning or deployment ("**Before deploying:**",
    /// "**Warning:**").
    public static func isWarningCallout(_ paragraph: String) -> Bool {
        guard let lead = paragraph.firstMatch(of: /^\*\*([^*]+):\*\*/) else { return false }
        let label = String(lead.1)
        return label.localizedCaseInsensitiveContains("warning") || label.localizedCaseInsensitiveContains("deploy")
    }

    /// A message as one line of at most `limit` characters: whitespace collapsed, Markdown's
    /// list, heading and quote markers dropped, and list items joined with " · " (a list ran
    /// into "deployed. - Both migrations applied" as a sentence with a stray dash). Bold and
    /// code-span marks go too (round 17: "**Move:**" showed literally in Overview's Activity).
    /// A longer one ends at a word with "…" (round 8: previews stopped mid-word with nothing
    /// saying so).
    public static func previewLine(_ text: String, limit: Int = 140) -> String {
        let (line, cut, atWord) = joinedLine(text, limit: limit)
        guard cut, limit > 1 else { return line }
        var short = Substring(line)
        if !atWord || short.count > limit - 1 {
            short = short.prefix(limit - 1)
            if let space = short.lastIndex(of: " "), short.distance(from: short.startIndex, to: space) > limit / 2 {
                short = short[..<space]
            }
        }
        while let last = short.last, last.isWhitespace || last.isPunctuation { short = short.dropLast() }
        return "\(short)…"
    }

    /// A `previewLine`'s opening sentence when a list item follows it, for a row with one line
    /// to give it: it ends on the verdict, not on the first word of the next item (round 28:
    /// "No blocking findings in PR #412. · Move: the…"). A lead that isn't a sentence (a heading
    /// such as "Summary") keeps the whole line.
    public static func verdict(_ preview: String) -> String {
        guard let item = preview.range(of: " · ") else { return preview }
        let lead = preview[..<item.lowerBound]
        guard let last = lead.last, ".!?".contains(last) else { return preview }
        return String(lead)
    }

    /// A `previewLine` with each list item on a line of its own, for a preview given several
    /// lines: a result reads as its verdict over its points rather than one run-on line (round
    /// 29: "No blocking findings in PR #412. · Move: the old team's… · Access…").
    public static func itemLines(_ preview: String) -> String {
        preview.replacingOccurrences(of: " · ", with: "\n")
    }

    /// A `previewLine` split for a preview given several lines: its opening sentence, the
    /// verdict, and the rest with each list item on a line of its own (`itemLines`), nil when
    /// there's none. Prose after the verdict counts too (round 31: "Fixed. The test now runs …"
    /// stayed one grey block where "No blocking findings. · Move: …" had its verdict apart).
    /// A sentence ends at ".", "!" or "?" before a capital or digit, in the text before the first
    /// list item; without one the lead before a list is the verdict, else the whole preview. An
    /// opening of one or two words ("Fixed.", "All set.") only acknowledges, so the verdict runs
    /// on through the next sentence, or the whole lead (round 32: a bright "Fixed." over the
    /// grey sentence that said what was fixed).
    public static func opening(_ preview: String) -> (verdict: String, rest: String?) {
        let head = preview[..<(preview.range(of: " · ")?.lowerBound ?? preview.endIndex)]
        let sentenceEnd = /[.!?] (?=[A-Z0-9])/
        if var end = head.firstRange(of: sentenceEnd) {
            if head[..<end.lowerBound].split(separator: " ").count <= 2 {
                guard let next = head[end.upperBound...].firstRange(of: sentenceEnd) else {
                    let rest = preview[head.endIndex...].dropFirst(" · ".count)
                    return (String(head), rest.isEmpty ? nil : itemLines(String(rest)))
                }
                end = next
            }
            return (String(preview[...end.lowerBound]), itemLines(String(preview[end.upperBound...])))
        }
        let lead = verdict(preview)
        guard lead != preview else { return (preview, nil) }
        return (lead, itemLines(String(preview.dropFirst(lead.count + " · ".count))))
    }

    /// The message's lines run together as `previewLine` describes, up to `limit` characters;
    /// `cut` when some of it didn't fit, `atWord` when that was at a word's end.
    private static func joinedLine(_ text: String, limit: Int) -> (line: String, cut: Bool, atWord: Bool) {
        var short = "", count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            var body = line.drop { $0.isWhitespace }
            var item = false
            if let first = body.first, "-*+•".contains(first), body.dropFirst().first?.isWhitespace == true {
                body = body.dropFirst(2); item = true
            } else if case let digits = body.prefix(while: \.isNumber), !digits.isEmpty, digits.count <= 3,
                      let mark = body.dropFirst(digits.count).first, mark == "." || mark == ")",
                      body.dropFirst(digits.count + 1).first?.isWhitespace == true {
                body = body.dropFirst(digits.count + 2); item = true
            } else if body.first == "#" || body.first == ">",
                      body.drop(while: { $0 == "#" || $0 == ">" }).first?.isWhitespace != false {
                body = body.drop { $0 == "#" || $0 == ">" }
            }
            var space = !short.isEmpty
            var separator = item && !short.isEmpty
            for character in body.replacingOccurrences(of: "**", with: "").filter({ $0 != "`" }) {
                if character.isWhitespace { space = !short.isEmpty; continue }
                if separator || space {
                    let gap = separator ? " · " : " "
                    if count + gap.count + 1 > limit { return (short, true, true) }
                    short += gap; count += gap.count; separator = false; space = false
                }
                if count + 1 > limit { return (short, true, false) }
                short.append(character); count += 1
            }
        }
        return (short, false, false)
    }

    /// Bytes up to and including the first newline: the line a mid-file read cannot parse.
    /// Without one, the whole page is inside a single line and the next page ends where it began.
    private static func partialLineLength(_ bytes: [UInt8]) -> Int {
        bytes.firstIndex(of: 0x0A).map { $0 + 1 } ?? 0
    }
}

extension HerdrClient {
    public struct FileChunk: Sendable, Equatable {
        /// The file's size, or nil when it does not exist.
        public let size: Int?
        public let from: Int
        public let bytes: [UInt8]
    }

    /// Reads a range of each file in one remote command: `from` nil means the last `limit`
    /// bytes. Keyed like `reads`.
    public func readChunks(_ reads: [String: (path: String, read: TranscriptActivity.Read)]) async throws -> [String: FileChunk] {
        guard !reads.isEmpty else { return [:] }
        let keys = Array(reads.keys)
        var script = "for spec in"
        for (index, key) in keys.enumerated() {
            let entry = reads[key]!
            script += " " + shellQuote("\(index)|\(entry.read.from ?? -1)|\(entry.read.limit)|\(entry.path)")
        }
        script += #"; do i=${spec%%|*}; r=${spec#*|}; f=${r%%|*}; r=${r#*|}; n=${r%%|*}; p=${r#*|}; "#
        script += #"if [ ! -f "$p" ]; then printf '%s -\n' "$i"; continue; fi; "#
        script += #"s=$(wc -c < "$p" | tr -d ' '); if [ "$f" -lt 0 ]; then f=$((s > n ? s - n : 0)); fi; "#
        script += #"printf '%s %s %s ' "$i" "$s" "$f"; "#
        script += #"if [ "$f" -lt "$s" ]; then tail -c +$((f + 1)) "$p" | head -c "$n" | base64 | tr -d '\n'; fi; echo; done"#
        let output = try await Self.collect(try await runner.exec(Self.posix(script)))
        var result: [String: FileChunk] = [:]
        for line in output.split(separator: 0x0A) {
            let fields = line.split(separator: 0x20, omittingEmptySubsequences: false)
            guard fields.count >= 2, let index = Int(String(decoding: fields[0], as: UTF8.self)),
                  keys.indices.contains(index) else { continue }
            if fields[1] == [UInt8(ascii: "-")] {
                result[keys[index]] = FileChunk(size: nil, from: 0, bytes: [])
                continue
            }
            guard fields.count >= 3, let size = Int(String(decoding: fields[1], as: UTF8.self)),
                  let from = Int(String(decoding: fields[2], as: UTF8.self)) else { continue }
            let encoded = fields.count > 3 ? Data(fields[3]) : Data()
            guard let bytes = encoded.isEmpty ? Data() : Data(base64Encoded: encoded) else { continue }
            result[keys[index]] = FileChunk(size: size, from: from, bytes: Array(bytes))
        }
        return result
    }
}
