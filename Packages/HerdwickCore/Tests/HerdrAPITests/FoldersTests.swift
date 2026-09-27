import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

@Suite struct FoldersTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    @Test func listsAwkwardNamesMarksRepositoriesAndSkipsDotFoldersAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folders \(UUID().uuidString) it's")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["two words", "it's", "new\nline", ".hidden", "repo/.git", "worktree", "b", "B2", "$(touch x)"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("gitdir: /elsewhere\n".utf8).write(to: root.appendingPathComponent("worktree/.git"))
        try Data().write(to: root.appendingPathComponent("file.txt"))

        let listing = try await client.folders(in: root.path)
        #expect(listing.path == root.resolvingSymlinksInPath().path)
        #expect(Set(listing.folders.map { $0.name }) == ["two words", "it's", "new\nline", "repo", "worktree", "b", "B2", "$(touch x)"])
        #expect(listing.folders.filter { $0.isRepository }.map { $0.name }.sorted() == ["repo", "worktree"])
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    @Test func homeIsTheDefaultAndMissingFoldersAreErrors() async throws {
        let home = try await client.folders(in: nil)
        #expect(home.path == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path)
        #expect(try await client.folders(in: "~").path == home.path)
        let error = await #expect(throws: FolderUnreadable.self) { try await client.folders(in: "/no/such/folder") }
        #expect(error?.path == "/no/such/folder")
    }
}
