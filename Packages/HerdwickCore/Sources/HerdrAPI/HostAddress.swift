import Foundation

/// What a user types to reach a host: `mac.local`, `tux@10.0.0.5:2222`,
/// `ssh://me@[fd7a::1]:22`, or a pasted `https://box.example.com/path`.
public struct HostAddress: Equatable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// Nil when the input names no usable host.
    public static func parse(_ input: String) -> HostAddress? {
        var rest = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let slash = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<slash] }

        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
            if user!.isEmpty { user = nil }
        }

        var host = rest
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { portText = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = rest[..<colon]
            portText = rest[rest.index(after: colon)...]
        }

        var port: Int?
        if let portText {
            guard let value = Int(portText), (1...65_535).contains(value) else { return nil }
            port = value
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        return HostAddress(user: user, host: String(host).lowercased(), port: port)
    }
}
