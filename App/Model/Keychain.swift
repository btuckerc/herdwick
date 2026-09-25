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

/// The one Ed25519 identity this device uses for every host.
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
}
