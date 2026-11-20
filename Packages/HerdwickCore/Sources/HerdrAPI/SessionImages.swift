import Foundation

extension HerdrClient {
    /// Every image a tool returned over the whole transcript file and, with `subagents`, its
    /// subagents' transcripts, oldest first by each record's time; an omp blob returned twice is
    /// kept once (at its newest). Listed on the host so a long session costs its image-bearing lines,
    /// not a download. omp blobs come back as hashes; inline base64 is left on the host and fetched
    /// one image at a time (`transcriptImage`) when shown. Codex tools return no images. `names`
    /// maps a subagent id to the name its image is shown with.
    public func transcriptToolImages(path: String, format: TranscriptFormat, subagents: Bool = false,
                                     names: [String: String] = [:]) async throws -> [TranscriptImage] {
        guard format != .codex, format != .agy else { return [] }
        // A subagent's transcript sits in a folder named after its parent's (Claude: `subagents/agent-<id>.jsonl`).
        let children = !subagents ? "" : format == .claude ? #"; for c in "${f%.jsonl}"/subagents/agent-*.jsonl; do [ -r "$c" ] && set -- "$@" "$c"; done"#
            : #"; for c in "${f%.jsonl}"/*.jsonl; do [ -r "$c" ] && set -- "$@" "$c"; done"#
        let script = "f=" + shellQuote(path) + #"; [ -r "$f" ] || exit 0; set -- "$f""# + children
            + "; LC_ALL=C awk -v fmt=" + format.rawValue + " " + shellQuote(Self.imageListScript) + #" "$@""#
        let listed = Self.parseImageList(try await Self.collect(try await runner.exec(Self.posix(script))), format: format, parent: path, names: names)
        return TranscriptImage.newestOfEach(listed)
    }

    /// The bytes of an inline image `transcriptToolImages` left on the host.
    public func transcriptImage(path: String, line: Int, ordinal: Int) async throws -> Data {
        let script = "f=" + shellQuote(path) + #"; [ -r "$f" ] || exit 0; LC_ALL=C awk -v n="# + String(line)
            + " -v want=" + String(ordinal) + " " + shellQuote(Self.imageFetchScript) + #" "$f""#
        let text = try await Self.collect(try await runner.exec(Self.posix(script)))
        guard let data = Data(base64Encoded: Data(text), options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw FileUnreadable(path: "image")
        }
        return data
    }

    /// An inline image is a long base64 JSON string under `data` (omp's content block, Claude's
    /// `source`); both scripts number them the same way, so a listed ordinal fetches its image.
    /// POSIX awk: no interval expressions, so the length is checked after matching.
    private static let payload = #"/"data":"[A-Za-z0-9+\/=\\]+"/"#

    /// Each file opens with `\u{1}<path>`; then its tool-result lines with an image, as
    /// `<record time>\t<line>`, each inline payload swapped for `hwline:<line>:<ordinal>`.
    static let imageListScript = """
    FNR == 1 { print "\\001" FILENAME }
    fmt == "omp" && !/"role":"toolResult"/ { next }
    fmt == "claude" && !/"tool_result"/ { next }
    /"type":"image"/ {
        out = ""; rest = $0; k = 0
        while (match(rest, \(payload))) {
            if (RLENGTH > 200) { out = out substr(rest, 1, RSTART - 1) "\\"data\\":\\"hwline:" FNR ":" k "\\""; k++ }
            else out = out substr(rest, 1, RSTART + RLENGTH - 1)
            rest = substr(rest, RSTART + RLENGTH)
        }
        out = out rest
        at = ""
        if (match(out, /"timestamp":"[^"]*"/)) at = substr(out, RSTART + 13, RLENGTH - 14)
        print at "\t" out
    }
    """

    static let imageFetchScript = """
    NR == n {
        rest = $0; k = 0
        while (match(rest, \(payload))) {
            if (RLENGTH > 200) { if (k == want) { print substr(rest, RSTART + 8, RLENGTH - 9); exit }; k++ }
            rest = substr(rest, RSTART + RLENGTH)
        }
        exit
    }
    """

    static func parseImageList(_ data: [UInt8], format: TranscriptFormat, parent: String, names: [String: String] = [:]) -> [TranscriptImage] {
        var images: [TranscriptImage] = []
        var file = parent
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.first == 0x01 { file = String(decoding: line.dropFirst(), as: UTF8.self); continue }
            guard let tab = line.firstIndex(of: 0x09) else { continue }
            let at = tab == line.startIndex ? nil : String(decoding: line[..<tab], as: UTF8.self)
            let child = file == parent ? nil : file
            let origin = child.map { names[SubagentTranscript.id(childPath: $0, format: format)] ?? "Subagent" }
            var reader = TranscriptReader(format: format)
            for entry in reader.append(Array(line[line.index(after: tab)...]) + [0x0A]) {
                guard case .message(let message) = entry, message.role == .toolResult else { continue }
                for image in message.images {
                    if case .blob(let hash) = image.source {
                        images.append(TranscriptImage(source: image.source, mimeType: image.mimeType, file: child, origin: origin, at: at, fingerprint: hash))
                        continue
                    }
                    guard case .base64(let text) = image.source else { continue }
                    // A payload short enough to be left in the listing travels whole.
                    guard text.hasPrefix("hwline:") else {
                        images.append(TranscriptImage(source: image.source, mimeType: image.mimeType, file: child, origin: origin, at: at))
                        continue
                    }
                    let parts = text.split(separator: ":")
                    guard parts.count == 3, let number = Int(parts[1]), let ordinal = Int(parts[2]) else { continue }
                    images.append(TranscriptImage(source: .transcriptLine(number, ordinal: ordinal), mimeType: image.mimeType,
                                                  file: child, origin: origin, at: at))
                }
            }
        }
        return images
    }
}
