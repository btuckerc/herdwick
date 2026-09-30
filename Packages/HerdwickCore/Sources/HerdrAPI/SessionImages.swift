import Foundation

extension HerdrClient {
    /// Every image a tool returned over the whole transcript file, oldest first, listed on the
    /// host so a long session costs its image-bearing lines, not a download. omp blobs come
    /// back as hashes; inline base64 is left on the host and fetched one image at a time
    /// (`transcriptImage`) when shown. Codex tools return no images.
    public func transcriptToolImages(path: String, format: TranscriptFormat) async throws -> [TranscriptImage] {
        guard format != .codex else { return [] }
        let script = "f=" + shellQuote(path) + #"; [ -r "$f" ] || exit 0; LC_ALL=C awk -v fmt="#
            + format.rawValue + " " + shellQuote(Self.imageListScript) + #" "$f""#
        return Self.parseImageList(try await Self.collect(try await runner.exec(Self.posix(script))), format: format)
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

    /// Tool-result lines with an image, each inline payload swapped for `hwline:<line>:<ordinal>`.
    static let imageListScript = """
    fmt == "omp" && !/"role":"toolResult"/ { next }
    fmt == "claude" && !/"tool_result"/ { next }
    /"type":"image"/ {
        out = ""; rest = $0; k = 0
        while (match(rest, \(payload))) {
            if (RLENGTH > 200) { out = out substr(rest, 1, RSTART - 1) "\\"data\\":\\"hwline:" NR ":" k "\\""; k++ }
            else out = out substr(rest, 1, RSTART + RLENGTH - 1)
            rest = substr(rest, RSTART + RLENGTH)
        }
        print out rest
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

    static func parseImageList(_ data: [UInt8], format: TranscriptFormat) -> [TranscriptImage] {
        var reader = TranscriptReader(format: format)
        return reader.append(data + [0x0A]).flatMap { entry -> [TranscriptImage] in
            guard case .message(let message) = entry, message.role == .toolResult else { return [] }
            return message.images.map { image in
                guard case .base64(let text) = image.source, text.hasPrefix("hwline:") else { return image }
                let parts = text.split(separator: ":")
                guard parts.count == 3, let line = Int(parts[1]), let ordinal = Int(parts[2]) else { return image }
                return TranscriptImage(source: .transcriptLine(line, ordinal: ordinal), mimeType: image.mimeType)
            }
        }
    }
}
