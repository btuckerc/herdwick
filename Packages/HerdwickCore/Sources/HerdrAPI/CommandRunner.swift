import Foundation

/// A running remote (or local) command with streaming stdio.
///
/// `output` yields stdout chunks in order and finishes when the command's
/// stdout closes. It finishes by throwing `CommandError.exited` when the
/// command exits non-zero, carrying the exit status and captured stderr.
public protocol ExecChannel: Sendable {
    var output: AsyncThrowingStream<[UInt8], any Error> { get }
    func write(_ bytes: [UInt8]) async throws
    /// Half-closes stdin (EOF) while keeping stdout readable.
    func closeInput() async throws
    /// Tears the channel down; idempotent.
    func close() async
}

/// Starts commands on a host. SSH on device; a local process in tests.
public protocol CommandRunner: Sendable {
    /// `command` is a POSIX shell command line, interpreted by the remote login shell.
    func exec(_ command: String) async throws -> any ExecChannel
}

public enum CommandError: Error, Equatable, Sendable, LocalizedError {
    case exited(status: Int32, stderr: String)
    case channelClosed

    public var errorDescription: String? {
        switch self {
        case .exited(let status, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "The command exited with status \(status)." : message
        case .channelClosed:
            return "The connection closed before the command finished."
        }
    }
}
