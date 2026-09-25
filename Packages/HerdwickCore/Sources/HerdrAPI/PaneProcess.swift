import Foundation

public struct PaneProcessInfo: Codable, Sendable, Equatable {
    public var paneID: String
    public var shellPID: UInt32?
    public var foregroundProcessGroupID: UInt32?
    public var foregroundProcesses: [PaneProcessInfoProcess]?
    public var tty: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", shellPID = "shell_pid"
        case foregroundProcessGroupID = "foreground_process_group_id"
        case foregroundProcesses = "foreground_processes", tty
    }
}

public struct PaneProcessInfoProcess: Codable, Sendable, Equatable {
    public var pid: UInt32
    public var name: String
    public var argv0: String?
    public var argv: [String]?
    public var cmdline: String?
    public var cwd: String?

    public var command: String {
        let executable = argv0 ?? argv?.first ?? name
        return String(executable.split(separator: "/").last ?? Substring(executable))
    }

    public var isShell: Bool {
        switch command.drop(while: { $0 == "-" }) {
        case "bash", "zsh", "fish", "sh", "dash", "nu", "ksh", "tcsh": true
        default: false
        }
    }
}

extension HerdrClient {
    public func processInfo(paneID: String, session: String) async throws -> PaneProcessInfo {
        struct Params: Encodable, Sendable { var pane_id: String }
        struct Result: Decodable, Sendable {
            var process_info: PaneProcessInfo
        }
        let result: Result = try await request("pane.process_info", params: Params(pane_id: paneID), session: session)
        return result.process_info
    }
}
