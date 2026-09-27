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
        case signingIn
        case installing
        case finished
        case failed(String)
    }

    struct Confirmation {
        let fingerprint: String
        let address: String
        /// The key matched one the tailnet advertises for this peer.
        let advertised: Bool
    }

    private(set) var state: State = .idle
    private(set) var result: HostProfile?
    private var profile: HostProfile?
    private var password = ""
    private var tailnet: Tailnet?
    private var ssh: SSHConnection?
    private var presented: CapturedHostKey?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    var isPresented: Bool {
        if case .idle = state { return false }
        return true
    }
    var isInstalling: Bool {
        switch state {
        case .signingIn, .installing: true
        default: false
        }
    }

    func begin(profile: HostProfile, password: String, tailnet: Tailnet) {
        invalidateOperation()
        self.profile = profile
        self.password = password
        self.tailnet = tailnet
        result = nil
        state = .connecting
        let generation = generation
        operation = Task { [weak self] in await self?.connectForSetup(generation: generation) }
    }

    /// Signs in with the password against the confirmed host key, then keeps the password.
    func keepPassword() {
        guard let profile, let hostKey = presented?.value?.publicKey else { return }
        invalidateOperation()
        let generation = generation
        state = .signingIn
        operation = Task { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            do {
                let ssh = try await self.dial(profile: profile, authentication: .password(self.password), expected: hostKey)
                guard self.isCurrent(generation) else { await ssh.close(); return }
                await ssh.close()
                guard self.isCurrent(generation) else { return }
                try Keychain.setChecked(Data(self.password.utf8), for: profile.passwordAccount)
                try Keychain.setChecked(Data(hostKey.utf8), for: profile.hostKeyAccount)
                self.result = profile
                self.password = ""
                self.state = .finished
            } catch {
                guard self.isCurrent(generation) else { return }
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    /// Signs in with the password against the confirmed host key, installs this device's key,
    /// then proves a key login before dropping the password.
    func install() {
        guard let profile, let hostKey = presented?.value?.publicKey else { return }
        invalidateOperation()
        let generation = generation
        state = .signingIn
        operation = Task { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            do {
                let ssh = try await self.dial(profile: profile, authentication: .password(self.password), expected: hostKey)
                guard self.isCurrent(generation) else { await ssh.close(); return }
                self.ssh = ssh
                self.state = .installing
                _ = try await AuthorizedKeyInstall.install(line: try DeviceKey.authorizedKeysLine, client: HerdrClient(runner: ssh))
                guard self.isCurrent(generation) else { return }
                self.closeSSH()
                let verified: SSHConnection
                do {
                    verified = try await self.dial(profile: profile, authentication: .ed25519(try DeviceKey.load()), expected: hostKey)
                } catch SSHError.authenticationFailed {
                    throw SetupError.keyRefused
                }
                await verified.close()
                guard self.isCurrent(generation) else { return }
                try Keychain.setChecked(Data(hostKey.utf8), for: profile.hostKeyAccount)
                var saved = profile
                saved.auth = .deviceKey
                self.result = saved
                self.password = ""
                self.state = .finished
            } catch {
                guard self.isCurrent(generation) else { return }
                self.closeSSH()
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    func retry() {
        guard let profile, let tailnet else { return }
        begin(profile: profile, password: password, tailnet: tailnet)
    }

    func dismiss() {
        invalidateOperation()
        password = ""
        profile = nil
        tailnet = nil
        presented = nil
        state = .idle
        result = nil
    }

    /// Learns the host key without authenticating: the validator records the key and refuses it,
    /// so the handshake stops before user auth and the password never leaves the device unconfirmed.
    private func connectForSetup(generation: UUID) async {
        guard isCurrent(generation), let profile else { return }
        let capture = CapturedHostKey()
        presented = capture
        let advertised = advertisedKeys(for: profile)
        do {
            let ssh = try await dial(profile: profile, authentication: .none, expected: nil, capture: capture)
            await ssh.close()
            throw SetupError.noHostKey
        } catch {
            guard isCurrent(generation) else { return }
            guard let key = capture.value, case SSHError.hostKeyRejected = error else {
                state = .failed(Self.message(for: error))
                return
            }
            if !advertised.isEmpty, !advertised.contains(Self.identity(key.publicKey)) {
                state = .failed(SetupError.advertisedMismatch.localizedDescription)
                return
            }
            state = .confirming(Confirmation(fingerprint: key.fingerprint, address: "\(profile.username)@\(profile.address)", advertised: !advertised.isEmpty))
        }
    }

    private func advertisedKeys(for profile: HostProfile) -> Set<String> {
        guard case .tailnet(let nodeID, _, _) = profile.route else { return [] }
        return Set((tailnet?.peer(id: nodeID)?.sshHostKeys ?? []).map(Self.identity))
    }

    /// With `capture`, records the presented key and refuses it (discovery); otherwise accepts only `expected`.
    private func dial(profile: HostProfile, authentication: SSHAuthentication, expected: String?, capture: CapturedHostKey? = nil) async throws -> SSHConnection {
        let validator: HostKeyValidator = { key in
            if let capture {
                capture.set(key)
                return false
            }
            guard let expected else { return false }
            return Self.identity(expected) == Self.identity(key.publicKey)
        }
        switch profile.route {
        case .direct(let host, let port):
            return try await SSHConnection.connect(host: host, port: port, username: profile.username, authentication: authentication, hostKeyValidator: validator)
        case .tailnet(let nodeID, _, let address):
            guard let tailnet else { throw TailnetError.notRunning }
            let handle = try await tailnet.readyHandle()
            let peer = tailnet.peer(id: nodeID)
            let fd = try await withTimeout(.seconds(15)) {
                try await tailnet.dial(address: peer?.address ?? address, port: 22, handle: handle)
            }
            return try await SSHConnection.connect(adoptingConnectedSocket: fd, username: profile.username, authentication: authentication, hostKeyValidator: validator)
        }
    }

    private func invalidateOperation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        closeSSH()
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        self.generation == generation && !Task.isCancelled
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
        case noHostKey, keyRefused, advertisedMismatch
        var errorDescription: String? {
            switch self {
            case .noHostKey: "The server did not present a host key."
            case .keyRefused: "The key was added, but the server still refuses key logins. Check that sshd allows PubkeyAuthentication, or keep using the password."
            case .advertisedMismatch: "This server's host key does not match the one your tailnet advertises for it. Nothing was sent."
            }
        }
    }

    private final class CapturedHostKey: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: SSHHostKey?
        var value: SSHHostKey? {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
        func set(_ value: SSHHostKey) { lock.lock(); captured = value; lock.unlock() }
    }
}
