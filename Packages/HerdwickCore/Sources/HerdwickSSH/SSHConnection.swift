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

    fileprivate init(channel: Channel, handler: NIOLoopBound<NIOSSHHandler>, activity: InboundActivity, keepaliveInterval: Duration?) {
        self.channel = channel
        self.handler = handler
        guard let keepaliveInterval else {
            keepalive = nil
            return
        }
        keepalive = Task { [channel, handler, activity] in
            var delay = keepaliveInterval
            while !Task.isCancelled, channel.isActive {
                do {
                    try await Task.sleep(for: delay)
                    let idle = try await channel.eventLoop.submit { activity.idleTime }.get()
                    if idle < keepaliveInterval {
                        delay = keepaliveInterval - idle
                        continue
                    }
                    try Task.checkCancellation()
                    try await Self.probe(channel: channel, handler: handler, timeout: .seconds(10))
                    delay = keepaliveInterval
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
    /// Probes after `keepaliveInterval` without inbound bytes (default 60 s); nil disables probes.
    public static func connect(
        host: String,
        port: Int = 22,
        username: String,
        authentication: SSHAuthentication,
        hostKeyValidator: @escaping HostKeyValidator,
        keepaliveInterval: Duration? = .seconds(60),
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
    /// Probes after `keepaliveInterval` without inbound bytes (default 60 s); nil disables probes.
    public static func connect(
        adoptingConnectedSocket fd: CInt,
        username: String,
        authentication: SSHAuthentication,
        hostKeyValidator: @escaping HostKeyValidator,
        keepaliveInterval: Duration? = .seconds(60),
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
        try Task.checkCancellation()
        let operation = PendingChannel(eventLoop: channel.eventLoop)
        let exec = ExecHandler(eventLoop: channel.eventLoop)
        operation.result.futureResult.whenFailure { exec.failedToOpen($0) }
        let child = try await withTaskCancellationHandler {
            channel.eventLoop.execute { [handler] in
                guard operation.isPending else { return }
                let opened = self.channel.eventLoop.makePromise(of: Channel.self)
                handler.value.createChannel(opened, channelType: .session) { child, _ in
                    guard operation.attach(child) else {
                        return child.eventLoop.makeFailedFuture(CancellationError())
                    }
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.pipeline.addHandler(exec)
                    }
                }
                opened.futureResult.flatMap { child in
                    guard operation.isPending else {
                        child.close(promise: nil)
                        return child.eventLoop.makeFailedFuture(CancellationError())
                    }
                    return child.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                    ).flatMap { exec.accepted.futureResult }.map { child }
                }.whenComplete { operation.complete($0) }
            }
            return try await operation.result.futureResult.get()
        } onCancel: {
            self.channel.eventLoop.execute { operation.complete(.failure(CancellationError())) }
        }
        if Task.isCancelled {
            child.close(promise: nil)
            throw CancellationError()
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
        try Task.checkCancellation()
        let loop = channel.eventLoop
        let operation = PendingChannel(eventLoop: loop)
        try await withTaskCancellationHandler {
            loop.execute {
                guard operation.isPending else { return }
                let deadline = loop.scheduleTask(in: timeout) {
                    operation.complete(.failure(SSHError.keepaliveTimeout))
                }
                operation.result.futureResult.whenComplete { _ in deadline.cancel() }
                let opened = loop.makePromise(of: Channel.self)
                opened.futureResult.whenComplete { operation.complete($0) }
                handler.value.createChannel(opened, channelType: .session) { child, _ in
                    guard operation.attach(child) else {
                        return loop.makeFailedFuture(CancellationError())
                    }
                    return loop.makeSucceededVoidFuture()
                }
            }
            let child = try await operation.result.futureResult.get()
            child.close(promise: nil)
            try Task.checkCancellation()
        } onCancel: {
            loop.execute { operation.complete(.failure(CancellationError())) }
        }
    }
}

/// All state and completions are confined to the transport's event loop.
private final class PendingChannel: @unchecked Sendable {
    let result: EventLoopPromise<Channel>
    private(set) var isPending = true
    private var child: Channel?

    init(eventLoop: any EventLoop) { result = eventLoop.makePromise() }

    func attach(_ child: Channel) -> Bool {
        guard isPending else {
            child.close(promise: nil)
            return false
        }
        self.child = child
        return true
    }

    func complete(_ outcome: Result<Channel, any Error>) {
        guard isPending else {
            if case .success(let child) = outcome { child.close(promise: nil) }
            return
        }
        isPending = false
        if case .failure = outcome { child?.close(promise: nil) }
        child = nil
        result.completeWith(outcome)
    }
}

/// Raw reads, including command replies and events, share one idle deadline.
private final class InboundActivity: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var lastRead = NIODeadline.now()

    var idleTime: Duration { .nanoseconds((NIODeadline.now() - lastRead).nanoseconds) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if unwrapInboundIn(data).readableBytes > 0 { lastRead = .now() }
        context.fireChannelRead(data)
    }
}

/// Handshake wiring shared by both connect paths.
private final class Setup: @unchecked Sendable {
    let username: String
    let authentication: SSHAuthentication
    let validator: HostKeyValidator
    private var handler: NIOLoopBound<NIOSSHHandler>?
    private var watcher: AuthWatcher?
    private let activity = InboundActivity()

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
            try channel.pipeline.syncOperations.addHandlers(activity, handler, watcher)
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
        return SSHConnection(channel: channel, handler: handler, activity: activity, keepaliveInterval: keepaliveInterval)
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

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        continuation.onTermination = { _ in channel.close(promise: nil) }
    }

    func failedToOpen(_ error: any Error) {
        settle(error)
        continuation.finish(throwing: error)
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
        try Task.checkCancellation()
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await waitForWrite(channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))))
    }

    func closeInput() async throws {
        try Task.checkCancellation()
        do {
            try await waitForWrite(channel.close(mode: .output))
        } catch ChannelError.alreadyClosed {
            // The command already exited and the peer closed the channel: EOF is moot, and
            // its output and exit status are already buffered in `output`.
        }
    }

    private func waitForWrite(_ future: EventLoopFuture<Void>) async throws {
        let operation = PendingChannel(eventLoop: channel.eventLoop)
        try await withTaskCancellationHandler {
            channel.eventLoop.execute {
                guard operation.attach(self.channel) else { return }
                future.whenComplete { outcome in
                    operation.complete(outcome.map { self.channel })
                }
            }
            _ = try await operation.result.futureResult.get()
            try Task.checkCancellation()
        } onCancel: {
            self.channel.eventLoop.execute { operation.complete(.failure(CancellationError())) }
        }
    }

    func close() async {
        // SSH close acknowledgement can wait forever on a blackholed peer.
        channel.close(promise: nil)
    }
}
