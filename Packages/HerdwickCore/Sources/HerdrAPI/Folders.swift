import Foundation

/// One level of a host directory, for picking where a new agent works.
public struct FolderListing: Sendable, Equatable {
    /// Absolute, symlink-resolved path of the listed folder.
    public var path: String
    /// Visible subfolders (dot folders omitted), sorted by name.
    public var folders: [Folder]

    public struct Folder: Sendable, Equatable, Hashable {
        public var name: String
        /// Holds a `.git` directory or worktree gitfile.
        public var isRepository: Bool
    }
}

public struct FolderUnreadable: LocalizedError, Equatable {
    public var path: String
    public var errorDescription: String? { "Couldn't open \(path)." }
}

extension HerdrClient {
    /// Lists the subfolders of `path` in one remote command. Relative paths and nil resolve
    /// against the login home; a leading `~/` means the same. Names are NUL-framed, so any
    /// byte a filename may hold survives.
    public func folders(in path: String?) async throws -> FolderListing {
        var target = path ?? ""
        if target == "~" { target = "" } else if target.hasPrefix("~/") { target.removeFirst(2) }
        let enter = target.isEmpty ? "" : " && cd -- \(shellQuote(target))"
        let script = #"cd -- "$HOME""# + enter + #" 2>/dev/null || exit 0; printf '%s\000' "$(pwd -P)"; for p in *; do [ -d "$p" ] || continue; if [ -e "$p/.git" ]; then g=1; else g=0; fi; printf '%s%s\000' "$g" "$p"; done"#
        let data = try await Self.collect(try await runner.exec(Self.posix(script)))
        return try Self.parseFolders(data, requested: path ?? "~")
    }

    static func parseFolders(_ data: [UInt8], requested: String) throws -> FolderListing {
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }
        guard let head = records.first, head.first == UInt8(ascii: "/") else { throw FolderUnreadable(path: requested) }
        let folders = records.dropFirst().compactMap { record -> FolderListing.Folder? in
            guard let flag = record.first, record.count > 1 else { return nil }
            return FolderListing.Folder(name: String(decoding: record.dropFirst(), as: UTF8.self), isRepository: flag == UInt8(ascii: "1"))
        }
        return FolderListing(path: String(decoding: head, as: UTF8.self),
                             folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
