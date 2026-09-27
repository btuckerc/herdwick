import Foundation

public struct FileUnreadable: LocalizedError, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
    public var errorDescription: String? { "Couldn't read \(path)." }
}

public struct FileTooLarge: LocalizedError, Equatable {
    public var path: String
    public var bytes: Int
    public init(path: String, bytes: Int) { self.path = path; self.bytes = bytes }
    public var errorDescription: String? {
        "\(path) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), too large to show."
    }
}

extension HerdrClient {
    /// Reads a host file in one remote command, for previewing an image the agent named.
    /// Relative paths resolve against the login home; a leading `~/` means the same. The
    /// size is checked first, so an oversized file costs one short reply; the read itself is
    /// capped too, in case the file grows in between.
    public func readFile(path: String, maxBytes: Int = 20_000_000) async throws -> Data {
        var target = path
        if target.hasPrefix("~/") { target.removeFirst(2) }
        let script = #"cd -- "$HOME" 2>/dev/null; f="# + shellQuote(target)
            + #"; [ -f "$f" ] && [ -r "$f" ] || exit 0; s=$(wc -c < "$f" | tr -d ' '); if [ "$s" -gt "#
            + String(maxBytes) + #" ]; then printf 'L%s' "$s"; else printf 'F'; head -c "#
            + String(maxBytes + 1) + #" -- "$f"; fi"#
        let data = try await Self.collect(try await runner.exec(Self.posix(script)))
        return try Self.parseFile(data, path: path, maxBytes: maxBytes)
    }

    static func parseFile(_ data: [UInt8], path: String, maxBytes: Int) throws -> Data {
        switch data.first {
        case UInt8(ascii: "F"):
            guard data.count - 1 <= maxBytes else { throw FileTooLarge(path: path, bytes: data.count - 1) }
            return Data(data.dropFirst())
        case UInt8(ascii: "L"):
            throw FileTooLarge(path: path, bytes: Int(String(decoding: data.dropFirst(), as: UTF8.self)) ?? 0)
        default: throw FileUnreadable(path: path)
        }
    }
}
