import Foundation
import HerdrAPI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs commands as local `/bin/sh -c` processes: the test stand-in for SSH exec.
///
/// Uses `posix_spawn` with one reaper thread per child rather than Foundation `Process`,
/// whose Linux reaping stalls short-lived children while a long-lived one (an event
/// subscription, a terminal stream) is still running.
public struct LocalProcessRunner: CommandRunner {
    public init() {}

    public func exec(_ command: String) async throws -> any ExecChannel {
        try LocalProcessChannel(command: command)
    }
}

final class LocalProcessChannel: ExecChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let pid: pid_t
    private let lock = NSLock()
    private var stdinFD: Int32
    private let exited = Flag()

    init(command: String) throws {
        var stdinPipe: [Int32] = [0, 0], stdoutPipe: [Int32] = [0, 0], stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw CommandError.channelClosed
        }
        // Parent ends must not leak into this or any other child.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        for fd in [stdinPipe[0], stdoutPipe[1], stderrPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, environ)
        for fd in [stdinPipe[0], stdoutPipe[1], stderrPipe[1]] { sysClose(fd) }
        guard status == 0 else {
            for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { sysClose(fd) }
            throw CommandError.channelClosed
        }
        self.pid = pid
        self.stdinFD = stdinPipe[1]

        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        output = stream
        let stdoutFD = stdoutPipe[0], stderrFD = stderrPipe[0], child = pid
        let stderrBox = StderrBox()
        let exited = exited
        let stderrDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            stderrBox.bytes = Self.drain(stderrFD) { _ in }
            stderrDone.signal()
        }
        Thread.detachNewThread {
            _ = Self.drain(stdoutFD) { continuation.yield($0) }
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
            exited.set()
            stderrDone.wait()
            // Exit code, or 128 + signal like a shell reports it.
            let code = raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
            if code == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: CommandError.exited(status: code, stderr: String(decoding: stderrBox.bytes, as: UTF8.self)))
            }
        }
    }

    /// Reads `fd` to EOF, handing each chunk to `sink`; returns everything read.
    private static func drain(_ fd: Int32, _ sink: ([UInt8]) -> Void) -> [UInt8] {
        var all: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            let chunk = Array(buffer[..<n])
            sink(chunk)
            all += chunk
        }
        sysClose(fd)
        return all
    }

    func write(_ bytes: [UInt8]) async throws {
        try lock.withLock {
            guard stdinFD >= 0 else { throw CommandError.channelClosed }
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { sysWrite(stdinFD, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CommandError.channelClosed }
                offset += n
            }
        }
    }

    func closeInput() async throws {
        lock.withLock {
            guard stdinFD >= 0 else { return }
            sysClose(stdinFD)
            stdinFD = -1
        }
    }

    /// Like closing an SSH channel: EOF first. A command that ignores EOF gets SIGTERM after 2 s.
    func close() async {
        try? await closeInput()
        for _ in 0..<20 {
            if exited.isSet { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !exited.isSet { kill(pid, SIGTERM) }
    }

    deinit {
        if stdinFD >= 0 { sysClose(stdinFD) }
    }
}

private final class StderrBox: @unchecked Sendable { var bytes: [UInt8] = [] }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// The channel's `write`/`close` methods shadow the syscalls inside the class.
private func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
private func sysClose(_ fd: Int32) { _ = close(fd) }
