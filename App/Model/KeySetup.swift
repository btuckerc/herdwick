import Foundation
import HerdrAPI
import HerdwickSSH
import Observation

/// Turns a one-time password login into the device-key setup without persisting the password.
@MainActor @Observable
final class KeySetup {
    enum State {
        case idle
        case connecting
        case confirming(Confirmation)
        case installing
        case finished
        case failed(String)
    }

    struct Confirmation {
        let fingerprint: String
        let address: String
    }

    private(set) var state: State = .idle
    private(set) var result: HostProfile?
    private var profile: HostProfile?
    private var password = ""
    private var tailnet: Tailnet?
    private var ssh: SSHConnection?
    private var presented: CapturedHostKey?

    var isPresented: Bool {
        if case .idle = state { return false }
        return true
    }
    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    func begin(profile: HostProfile, password: String, tailnet: Tailnet) {
        self.profile = profile
        self.password = password
        self.tailnet = tailnet
        result = nil
        state = .connecting
        Task { [weak self] in await self?.connectForSetup() }
    }

    func keepPassword() {
        guard let profile else { return }
        Keychain.set(password, for: profile.passwordAccount)
        if let key = presented?.value { Keychain.set(key.publicKey, for: profile.hostKeyAccount) }
        result = profile
        state = .finished
        password = ""
        closeSSH()
    }
    func install() {
        guard let profile, let ssh, let hostKey = presented?.value?.publicKey else { return }
        state = .installing
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await AuthorizedKeyInstall.install(line: DeviceKey.authorizedKeysLine, client: HerdrClient(runner: ssh))
                self.closeSSH()
                let verified: SSHConnection
                do {
                    verified = try await self.dial(profile: profile, authentication: .ed25519(DeviceKey.load()), expected: hostKey)
                } catch SSHError.authenticationFailed {
                    throw SetupError.keyRefused
                }
                await verified.close()
                Keychain.set(hostKey, for: profile.hostKeyAccount)
                var saved = profile
                saved.auth = .deviceKey
                self.result = saved
                self.password = ""
                self.state = .finished
            } catch {
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    func retry() {
        guard let profile else { return }
        if ssh != nil, presented != nil { install() }
        else { begin(profile: profile, password: password, tailnet: tailnet!) }
    }

    func dismiss() {
        closeSSH()
        state = .idle
        result = nil
    }

    private func connectForSetup() async {
        guard let profile else { return }
        do {
            let capture = CapturedHostKey()
            presented = capture
            let ssh = try await dial(profile: profile, authentication: .password(password), expected: nil, capture: capture)
            self.ssh = ssh
            guard let key = capture.value else { throw SetupError.noHostKey }
            state = .confirming(Confirmation(fingerprint: key.fingerprint, address: "\(profile.username)@\(profile.address)"))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func dial(profile: HostProfile, authentication: SSHAuthentication, expected: String?, capture: CapturedHostKey? = nil) async throws -> SSHConnection {
        let knownKeys: Set<String>
        switch profile.route {
        case .direct:
            knownKeys = []
        case .tailnet(let nodeID, _, _):
            knownKeys = Set((tailnet?.peer(id: nodeID)?.sshHostKeys ?? []).map(Self.identity))
        }
        let validator: HostKeyValidator = { key in
            if let expected { return Self.identity(expected) == Self.identity(key.publicKey) }
            capture?.set(key)
            return knownKeys.isEmpty || knownKeys.contains(Self.identity(key.publicKey))
        }
        switch profile.route {
        case .direct(let host, let port):
            return try await SSHConnection.connect(host: host, port: port, username: profile.username, authentication: authentication, hostKeyValidator: validator)
        case .tailnet(let nodeID, _, let address):
            guard let tailnet else { throw TailnetError.notRunning }
            let handle = try await tailnet.readyHandle()
            let peer = tailnet.peer(id: nodeID)
            let fd = try await tailnet.dial(address: peer?.address ?? address, port: 22, handle: handle)
            return try await SSHConnection.connect(adoptingConnectedSocket: fd, username: profile.username, authentication: authentication, hostKeyValidator: validator)
        }
    }

    private func closeSSH() {
        guard let ssh else { return }
        self.ssh = nil
        Task { await ssh.close() }
    }

    nonisolated private static func identity(_ line: String) -> String { line.split(separator: " ").prefix(2).joined(separator: " ") }

    private static func message(for error: Error) -> String {
        if case SSHError.authenticationFailed = error { return "The username or password is wrong." }
        if let error = error as? AuthorizedKeyInstallError, case .failed(let message) = error { return "Key install failed: \(message)" }
        if error is SSHError { return "SSH setup failed: \(error.localizedDescription)" }
        return error.localizedDescription
    }

    private enum SetupError: LocalizedError {
        case noHostKey, keyRefused
        var errorDescription: String? {
            switch self {
            case .noHostKey: "The server did not present a host key."
            case .keyRefused: "The key was added, but the server still refuses key logins. Check that sshd allows PubkeyAuthentication, or keep using the password."
            }
        }
    }

    private final class CapturedHostKey: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value: SSHHostKey?
        func set(_ value: SSHHostKey) { lock.lock(); self.value = value; lock.unlock() }
    }
}
