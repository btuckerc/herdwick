import CryptoKit
import Foundation
import HerdwickSSH
import Security

/// Secrets live in the data-protection keychain, readable after first unlock so a
/// reconnect right after the phone wakes still works, and never synced off device.
enum Keychain {
    private static let service = "dev.btuckerc.herdwick"

    static func data(for account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ data: Data, for account: String) {
        let query = base(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func set(_ string: String, for account: String) {
        set(Data(string.utf8), for: account)
    }

    static func setChecked(_ data: Data, for account: String) throws {
        let query = base(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// The active Ed25519 identity, with a separate pending replacement until every host is confirmed.
enum DeviceKey {
    private static let account = "device-key.ed25519"

    static func load() -> Curve25519.Signing.PrivateKey {
        if let raw = Keychain.data(for: account), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = SSHKeys.generate()
        Keychain.set(key.rawRepresentation, for: account)
        return key
    }

    /// The line to append to `~/.ssh/authorized_keys` on a host.
    static var authorizedKeysLine: String {
        SSHKeys.publicKeyLine(for: load(), comment: "herdwick")
    }

    static var fingerprint: String {
        SSHKeys.fingerprint(ofPublicKeyLine: authorizedKeysLine) ?? ""
    }

    struct Rotation: Codable {
        var privateKey: Data
        var hosts: [UUID: String]
        var confirmed: Set<UUID> = []
        var testing: Set<UUID> = []

        var publicKeyLine: String {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return "" }
            return SSHKeys.publicKeyLine(for: key, comment: "herdwick")
        }
    }

    private static let rotationAccount = "device-key.rotation"

    static func rotation() -> Rotation? {
        guard let data = Keychain.data(for: rotationAccount) else { return nil }
        return try? JSONDecoder().decode(Rotation.self, from: data)
    }

    static func load(hostID: UUID) -> Curve25519.Signing.PrivateKey {
        if let pending = rotation(), pending.testing.contains(hostID) || pending.confirmed.contains(hostID),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: pending.privateKey) { return key }
        return load()
    }

    static func beginRotation(profiles: [HostProfile]) throws -> Rotation {
        if let pending = rotation() { return pending }
        // Ensure the current identity remains available throughout the transaction.
        let old = load()
        try Keychain.setChecked(old.rawRepresentation, for: account)
        let pending = Rotation(privateKey: SSHKeys.generate().rawRepresentation,
                               hosts: Dictionary(uniqueKeysWithValues: profiles.filter { $0.auth == .deviceKey }.map { ($0.id, $0.name) }))
        try saveRotation(pending)
        return pending
    }

    static func saveRotation(_ rotation: Rotation) throws {
        try Keychain.setChecked(JSONEncoder().encode(rotation), for: rotationAccount)
    }

    /// Only after explicit per-host confirmation; remote authorized_keys are never edited here.
    static func finishRotation(_ rotation: Rotation, profiles: [HostProfile]) throws {
        let required = Set(rotation.hosts.keys).union(profiles.filter { $0.auth == .deviceKey }.map(\.id))
        guard required.isSubset(of: rotation.confirmed),
              let stored = self.rotation(), stored.privateKey == rotation.privateKey else {
            throw NSError(domain: "DeviceKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Confirm the replacement works on every listed host first."])
        }
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: rotation.privateKey)
        try Keychain.setChecked(rotation.privateKey, for: account)
        Keychain.delete(rotationAccount)
    }
}
