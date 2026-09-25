import Crypto
import Foundation
import NIOSSH

public enum SSHError: Error, Equatable, Sendable {
    case authenticationFailed
    case hostKeyRejected(fingerprint: String)
    case invalidPrivateKey(String)
    case execRejected
    /// The TCP connection opened but the SSH handshake did not finish in time.
    case timedOut
    case keepaliveTimeout
    case connectionClosed
}

/// OpenSSH-compatible Ed25519 key helpers.
public enum SSHKeys {
    public static func generate() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    /// `ssh-ed25519 AAAA… comment`, ready for `authorized_keys`.
    public static func publicKeyLine(for key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        var blob: [UInt8] = []
        blob.appendSSHString(Array("ssh-ed25519".utf8))
        blob.appendSSHString(Array(key.publicKey.rawRepresentation))
        let line = "ssh-ed25519 " + Data(blob).base64EncodedString()
        return comment.isEmpty ? line : line + " " + comment
    }

    /// `SHA256:…` exactly as `ssh-keygen -l` prints it.
    public static func fingerprint(ofPublicKeyLine line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        return fingerprint(ofBlob: blob)
    }

    public static func fingerprint(of key: NIOSSHPublicKey) -> String {
        fingerprint(ofPublicKeyLine: String(openSSHPublicKey: key)) ?? "SHA256:?"
    }

    static func fingerprint(ofBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Parses an unencrypted `-----BEGIN OPENSSH PRIVATE KEY-----` Ed25519 key.
    public static func parseOpenSSHPrivateKey(_ pem: String) throws -> Curve25519.Signing.PrivateKey {
        let body = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw SSHError.invalidPrivateKey("not base64") }
        var r = Reader(Array(data))
        guard r.take(15) == Array("openssh-key-v1\0".utf8) else { throw SSHError.invalidPrivateKey("not an OpenSSH key") }
        let cipher = try r.string(), kdf = try r.string()
        _ = try r.string()
        guard cipher == Array("none".utf8), kdf == Array("none".utf8) else {
            throw SSHError.invalidPrivateKey("encrypted keys are not supported; remove the passphrase first")
        }
        guard try r.uint32() == 1 else { throw SSHError.invalidPrivateKey("expected exactly one key") }
        _ = try r.string()
        var p = Reader(try r.string())
        guard try p.uint32() == p.uint32() else { throw SSHError.invalidPrivateKey("corrupt key") }
        guard try p.string() == Array("ssh-ed25519".utf8) else { throw SSHError.invalidPrivateKey("only Ed25519 keys are supported") }
        let publicKey = try p.string(), secret = try p.string()
        guard publicKey.count == 32, secret.count == 64, Array(secret[32...]) == publicKey else {
            throw SSHError.invalidPrivateKey("corrupt key")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: secret[..<32])
    }

    private struct Reader {
        var bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ n: Int) -> [UInt8]? {
            guard index + n <= bytes.count else { return nil }
            defer { index += n }
            return Array(bytes[index..<index + n])
        }

        mutating func uint32() throws -> UInt32 {
            guard let b = take(4) else { throw SSHError.invalidPrivateKey("truncated key") }
            return b.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() throws -> [UInt8] {
            guard let b = take(Int(try uint32())) else { throw SSHError.invalidPrivateKey("truncated key") }
            return b
        }
    }
}

extension [UInt8] {
    mutating func appendSSHString(_ value: [UInt8]) {
        let n = UInt32(value.count)
        append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        append(contentsOf: value)
    }
}
