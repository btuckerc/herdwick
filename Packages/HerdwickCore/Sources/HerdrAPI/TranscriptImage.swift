import Foundation

/// An image in a transcript, held by reference. omp stores pasted and tool images as blobs
/// beside its sessions (`"data": "blob:sha256:<hex>"`), so a row carries only the hash and
/// the bytes are read from the host when the image is shown. Claude and Codex inline base64,
/// kept undecoded until then. A class so view diffs compare identity, never bytes.
public final class TranscriptImage: Sendable, Hashable {
    public enum Source: Sendable, Equatable {
        /// SHA-256 hex of a blob under omp's `blobs` folder.
        case blob(String)
        case base64(String)
        /// An inline image left in the transcript on the host: its 1-based line and its place
        /// among that line's images (`HerdrClient.transcriptToolImages`).
        case transcriptLine(Int, ordinal: Int)
    }

    public let source: Source
    public let mimeType: String?
    /// The transcript a listed image lives in when it isn't the conversation's own: a subagent's.
    public let file: String?
    /// Who returned it, when not the conversation's own agent: the subagent's name.
    public let origin: String?
    /// Its record's time, as the transcript wrote it, for ordering across files.
    public let at: String?
    /// Same bytes, same key: a blob's hash.
    public let fingerprint: String?

    public init(source: Source, mimeType: String?, file: String? = nil, origin: String? = nil, at: String? = nil, fingerprint: String? = nil) {
        self.source = source; self.mimeType = mimeType
        self.file = file; self.origin = origin; self.at = at; self.fingerprint = fingerprint
    }

    /// Same bytes, same key: an omp blob's hash. Inline images have none; two screenshots can
    /// share any sample of their bytes, so only identical blobs are taken as one.
    public var key: String? {
        if let fingerprint { return fingerprint }
        if case .blob(let hash) = source { return hash }
        return nil
    }

    /// Oldest first by record time (images without one keep their place), then each image
    /// once, where it last appeared.
    public static func newestOfEach(_ images: [TranscriptImage]) -> [TranscriptImage] {
        let ordered = images.enumerated().sorted { a, b in
            (a.element.at ?? "", a.offset) < (b.element.at ?? "", b.offset)
        }.map(\.element)
        var seen = Set<String>()
        var kept: [TranscriptImage] = []
        for image in ordered.reversed() {
            if let key = image.key, !seen.insert(key).inserted { continue }
            kept.append(image)
        }
        return kept.reversed()
    }

    /// The bytes of an inline image; nil for a blob, which lives on the host.
    public var inlineData: Data? {
        guard case .base64(let text) = source else { return nil }
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    /// Where a blob lives on the host: omp's `blobs` folder sits beside `sessions`, which
    /// holds the transcript (a subagent's is one folder deeper).
    public func blobPath(transcript: String) -> String? {
        guard case .blob(let hash) = source,
              let sessions = transcript.range(of: "/sessions/", options: .backwards) else { return nil }
        return transcript[..<sessions.lowerBound] + "/blobs/" + hash
    }

    public static func == (a: TranscriptImage, b: TranscriptImage) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// omp: `{"type": "image", "data": "blob:sha256:<hex>" | <base64>, "mimeType": …}`.
    static func omp(_ block: [String: Any]) -> TranscriptImage? {
        guard let data = block["data"] as? String, !data.isEmpty else { return nil }
        let mime = block["mimeType"] as? String
        if data.hasPrefix("blob:sha256:") {
            let hash = data.dropFirst("blob:sha256:".count)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return TranscriptImage(source: .blob(String(hash)), mimeType: mime)
        }
        return TranscriptImage(source: .base64(data), mimeType: mime)
    }

    /// Claude: `{"type": "image", "source": {"type": "base64", "media_type": …, "data": …}}`.
    static func claude(_ block: [String: Any]) -> TranscriptImage? {
        guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
              let data = source["data"] as? String, !data.isEmpty else { return nil }
        return TranscriptImage(source: .base64(data), mimeType: source["media_type"] as? String)
    }

    /// Codex: `{"type": "input_image", "image_url": "data:image/png;base64,…"}`.
    static func dataURL(_ url: String) -> TranscriptImage? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64") else { return nil }
        let mime = url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count)
        return TranscriptImage(source: .base64(String(url[url.index(after: comma)...])),
                               mimeType: mime.isEmpty ? nil : String(mime))
    }
}
