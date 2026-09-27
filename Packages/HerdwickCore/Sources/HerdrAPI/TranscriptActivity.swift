import Foundation

extension TranscriptMessage {
    /// A message the user sent or the agent wrote to them. Thinking, tool calls and tool
    /// results are work, not messages; harness text never becomes a message at all.
    public var isConversation: Bool {
        role != .toolResult && (imageCount > 0 || text.contains { !$0.isWhitespace })
    }
}

/// When an agent's transcript last recorded a conversation message, and how far the file has
/// been read. Transcripts are append-only (omp's padded title line is rewritten in place at
/// the same size), so each refresh reads only what was appended since.
///
/// A first read takes the file's tail; when that holds no message (one long tool run, say),
/// it pages backwards until it finds one or reaches the start. File times are never used:
/// tool output and title rewrites change them without a message.
public struct TranscriptActivity: Codable, Sendable, Equatable {
    public static let window = 256 * 1024
    /// Backward pages read before giving up on an old conversation's last message.
    static let maxLookBackPages = 8

    public let path: String
    public let format: TranscriptFormat
    /// The newest conversation message's own timestamp; nil while none is known.
    public private(set) var lastMessageAt: Date?
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

    /// Takes the bytes `nextRead` asked for. `size` is the file's size (nil: no such file
    /// yet, as omp creates its transcript on the first message); `from` where `bytes` start.
    public mutating func absorb(size: Int?, from: Int, bytes: [UInt8]) {
        guard let size else {
            self = TranscriptActivity(path: path, format: format)
            return
        }
        if let lookBack {
            let (found, _) = Self.scan(bytes, format: format, startsMidFile: from > 0, flush: true)
            lastMessageAt = found
            self.lookBack = found == nil && from > 0 && lookBack.pages + 1 < Self.maxLookBackPages
                ? LookBack(end: from + Self.partialLineLength(bytes), pages: lookBack.pages + 1) : nil
            return
        }
        guard let offset else {
            // First read: the tail. Its last line may still be being written; counting it now
            // is harmless, as it is read again from `offset` once complete.
            let (found, consumed) = Self.scan(bytes, format: format, startsMidFile: from > 0, flush: true)
            lastMessageAt = found
            self.offset = from + consumed
            if found == nil, from > 0 { lookBack = LookBack(end: from + Self.partialLineLength(bytes), pages: 0) }
            return
        }
        if size < offset {
            // Truncated or replaced: whatever it holds now is a different history.
            self = TranscriptActivity(path: path, format: format)
            return
        }
        let (found, consumed) = Self.scan(bytes, format: format, startsMidFile: midLine, flush: false)
        if let found { lastMessageAt = max(lastMessageAt ?? found, found) }
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

    /// The newest conversation message among `bytes`' complete lines, and the bytes those
    /// lines span. `flush` also parses a final line that lacks its newline.
    static func scan(_ bytes: [UInt8], format: TranscriptFormat, startsMidFile: Bool, flush: Bool) -> (Date?, Int) {
        var reader = TranscriptReader(format: format, startsMidFile: startsMidFile)
        var entries = reader.append(bytes)
        let consumed = reader.consumedBytes
        if flush { entries += reader.append([0x0A]) }
        let newest = entries.compactMap { entry -> Date? in
            guard case .message(let message) = entry, message.isConversation else { return nil }
            return message.timestamp
        }.max()
        return (newest, consumed)
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
