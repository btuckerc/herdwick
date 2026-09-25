import Crypto
import Foundation
import HerdrAPI
import NIOCore
import NIOPosix
import NIOSSH

public struct SSHHostKey: Sendable, Equatable {
    /// `ssh-ed25519 AAAA…` without a comment.
    public let publicKey: String
    public let fingerprint: String
}

public typealias HostKeyValidator = @Sendable (SSHHostKey) -> Bool

public enum SSHAuthentication: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case password(String)
    /// `none` auth, which Tailscale SSH accepts for tailnet peers it authorises.
    case none
}

/// One authenticated SSH transport. Commands run on multiplexed session channels.
public final class SSHConnection: CommandRunner, @unchecked Sendable {
    private let channel: Channel
    private let handler: NIOLoopBound<NIOSSHHandler>
    private let keepalive: Task<Void, Never>?

    fileprivate init(channel: Channel, handler: NIOLoopBound<NIOSSHHandler>, keepaliveInterval: Duration?) {
        self.channel = channel
        self.handler = handler
        guard let keepaliveInterval else {
            keepalive = nil
            return
        }
        keepalive = Task { [channel, handler] in
            while !Task.isCancelled, channel.isActive {
                try? await Task.sleep(for: keepaliveInterval)
                guard !Task.isCancelled else { return }
                do {
                    try await Self.probe(channel: channel, handler: handler, timeout: .seconds(10))
                } catch {
                    // A missed probe means the path is dead; closing wakes `waitUntilClosed`.
                    channel.close(promise: nil)
                    return
                }
            }
        }
    }

    deinit { keepalive?.cancel() }

    /// Connects by hostname or IP literal.
    public static func connect(
        host: String,
        port: Int = 22,
        username: String,
        authentication: SSHAuthentication,
        hostKeyValidator: @escaping HostKeyValidator,
        keepaliveInterval: Duration? = .seconds(15),
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        let setup = Setup(username: username, authentication: authentication, validator: hostKeyValidator)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelInitializer(setup.initialize)
            .connect(host: host, port: port)
            .get()
        return try await setup.finish(channel: channel, timeout: timeout, keepaliveInterval: keepaliveInterval)
    }

    /// Adopts an already-connected stream socket, e.g. one returned by `tailscale_dial`.
    /// The connection owns the descriptor from here on.
    public static func connect(
        adoptingConnectedSocket fd: CInt,
        username: String,
        authentication: SSHAuthentication,
        hostKeyValidator: @escaping HostKeyValidator,
        keepaliveInterval: Duration? = .seconds(15),
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        let setup = Setup(username: username, authentication: authentication, validator: hostKeyValidator)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer(setup.initialize)
            .withConnectedSocket(fd)
            .get()
        return try await setup.finish(channel: channel, timeout: timeout, keepaliveInterval: keepaliveInterval)
    }

    public func exec(_ command: String) async throws -> any ExecChannel {
        let exec = ExecHandler(eventLoop: channel.eventLoop)
        let opened = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute { [handler] in
            handler.value.createChannel(opened, channelType: .session) { child, _ in
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                    child.pipeline.addHandler(exec)
                }
            }
        }
        let child = try await opened.futureResult.get()
        do {
            try await child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            ).get()
            try await exec.accepted.futureResult.get()
        } catch {
            child.close(promise: nil)
            throw error
        }
        return SSHExecChannel(channel: child, handler: exec)
    }

    /// One round trip: opens and closes a session channel. Throws `keepaliveTimeout` if the peer is silent.
    public func ping(timeout: TimeAmount = .seconds(10)) async throws {
        try await Self.probe(channel: channel, handler: handler, timeout: timeout)
    }

    public var isActive: Bool { channel.isActive }

    public func close() async {
        keepalive?.cancel()
        try? await channel.close().get()
    }

    /// Returns when the transport closes for any reason.
    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    private static func probe(channel: Channel, handler: NIOLoopBound<NIOSSHHandler>, timeout: TimeAmount) async throws {
        let loop = channel.eventLoop
        let opened = loop.makePromise(of: Channel.self)
        loop.execute {
            // Both callbacks run on `loop`, so exactly one of success or timeout completes `opened`.
            let deadline = loop.scheduleTask(in: timeout) { opened.fail(SSHError.keepaliveTimeout) }
            opened.futureResult.whenComplete { _ in deadline.cancel() }
            handler.value.createChannel(opened, channelType: .session, nil)
        }
        let child = try await opened.futureResult.get()
        child.close(promise: nil)
    }
}

/// Handshake wiring shared by both connect paths.
private final class Setup: @unchecked Sendable {
    let username: String
    let authentication: SSHAuthentication
    let validator: HostKeyValidator
    private var handler: NIOLoopBound<NIOSSHHandler>?
    private var watcher: AuthWatcher?

    init(username: String, authentication: SSHAuthentication, validator: @escaping HostKeyValidator) {
        self.username = username
        self.authentication = authentication
        self.validator = validator
    }

    @Sendable func initialize(_ channel: Channel) -> EventLoopFuture<Void> {
        let hostAuth = HostAuth(validator: validator)
        let handler = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: ClientAuth(username: username, authentication: authentication),
                serverAuthDelegate: hostAuth
            )),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
        )
        let watcher = AuthWatcher(eventLoop: channel.eventLoop, hostAuth: hostAuth)
        self.handler = NIOLoopBound(handler, eventLoop: channel.eventLoop)
        self.watcher = watcher
        // NIOSSHHandler swallows channelInactive, so a pre-auth close is caught here.
        channel.closeFuture.whenComplete { _ in watcher.complete(SSHError.connectionClosed) }
        do {
            try channel.pipeline.syncOperations.addHandlers(handler, watcher)
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    func finish(channel: Channel, timeout: TimeAmount, keepaliveInterval: Duration?) async throws -> SSHConnection {
        // `initialize` ran on the channel's loop before the bootstrap future completed.
        guard let handler, let watcher else { throw SSHError.connectionClosed }
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            watcher.complete(SSHError.timedOut)
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        do {
            try await watcher.authenticated.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return SSHConnection(channel: channel, handler: handler, keepaliveInterval: keepaliveInterval)
    }
}

private final class ClientAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let authentication: SSHAuthentication
    private var offered = false

    init(username: String, authentication: SSHAuthentication) {
        self.username = username
        self.authentication = authentication
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // One attempt with the configured credential. Failing the promise is how NIOSSH
        // ends the handshake; succeeding with nil would leave it waiting.
        guard !offered else { return nextChallengePromise.fail(SSHError.authenticationFailed) }
        offered = true
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch authentication {
        case .ed25519(let key):
            guard availableMethods.contains(.publicKey) else { return nextChallengePromise.fail(SSHError.authenticationFailed) }
            offer = .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        case .password(let password):
            guard availableMethods.contains(.password) else { return nextChallengePromise.fail(SSHError.authenticationFailed) }
            offer = .password(.init(password: password))
        case .none:
            offer = .none
        }
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: offer))
    }
}

private final class HostAuth: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let validator: HostKeyValidator
    var rejected: String?

    init(validator: @escaping HostKeyValidator) { self.validator = validator }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let key = SSHHostKey(publicKey: line, fingerprint: SSHKeys.fingerprint(ofPublicKeyLine: line) ?? "SHA256:?")
        if validator(key) {
            validationCompletePromise.succeed(())
        } else {
            rejected = key.fingerprint
            validationCompletePromise.fail(SSHError.hostKeyRejected(fingerprint: key.fingerprint))
        }
    }
}

/// Completes `authenticated` once user auth succeeds, or fails it with the most specific cause.
/// Every method runs on the channel's event loop.
private final class AuthWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    let authenticated: EventLoopPromise<Void>
    private var pending = true
    private let hostAuth: HostAuth

    init(eventLoop: any EventLoop, hostAuth: HostAuth) {
        self.authenticated = eventLoop.makePromise()
        self.hostAuth = hostAuth
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { complete(nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(error)
        context.fireErrorCaught(error)
    }

    func complete(_ error: (any Error)?) {
        guard pending else { return }
        pending = false
        if let fingerprint = hostAuth.rejected {
            authenticated.fail(SSHError.hostKeyRejected(fingerprint: fingerprint))
        } else if let error {
            authenticated.fail(error)
        } else {
            authenticated.succeed(())
        }
    }
}

private final class ExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    let accepted: EventLoopPromise<Void>
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private var exitStatus: Int32?
    private var stderr: [UInt8] = []
    private var pendingAccept = true

    init(eventLoop: any EventLoop) {
        accepted = eventLoop.makePromise()
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        if message.type == .stdErr {
            stderr.append(contentsOf: buffer.readableBytesView.prefix(64 * 1024 - stderr.count))
        } else {
            continuation.yield(Array(buffer.readableBytesView))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            settle(nil)
        case is ChannelFailureEvent:
            settle(SSHError.execRejected)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = Int32(truncatingIfNeeded: status.exitStatus)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        settle(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(SSHError.connectionClosed)
        switch exitStatus {
        case 0?:
            continuation.finish()
        case let status?:
            continuation.finish(throwing: CommandError.exited(status: status, stderr: String(decoding: stderr, as: UTF8.self)))
        case nil:
            continuation.finish(throwing: CommandError.channelClosed)
        }
        context.fireChannelInactive()
    }

    private func settle(_ error: (any Error)?) {
        guard pendingAccept else { return }
        pendingAccept = false
        if let error { accepted.fail(error) } else { accepted.succeed(()) }
    }
}

private final class SSHExecChannel: ExecChannel, @unchecked Sendable {
    let channel: Channel
    let output: AsyncThrowingStream<[UInt8], any Error>

    init(channel: Channel, handler: ExecHandler) {
        self.channel = channel
        self.output = handler.output
    }

    func write(_ bytes: [UInt8]) async throws {
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    func closeInput() async throws {
        do {
            try await channel.close(mode: .output).get()
        } catch ChannelError.alreadyClosed {
            // The command already exited and the peer closed the channel: EOF is moot, and
            // its output and exit status are already buffered in `output`.
        }
    }

    func close() async {
        try? await channel.close().get()
    }
}
