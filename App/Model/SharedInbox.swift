import Foundation
import Observation

/// Text and images shared into Herdwick, waiting on the Inbox's Shared shelf until a send that
/// carried them succeeds. Refreshed when a window becomes active; never presents itself.
@MainActor @Observable
final class SharedInbox {
    static let shared = SharedInbox()

    private(set) var packages: [SharePackage.Metadata] = []
    private var revision = UUID()
    private var refreshing = false
    private var refreshAgain = false
    /// Why the shelf couldn't be read (a locked device); the last packages read stay listed.
    private(set) var error: String?

    struct Occupied: LocalizedError {
        var errorDescription: String? {
            "This conversation already holds another share. Send it or remove it from Shared first."
        }
    }

    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let revision = UUID()
        self.revision = revision
        Task {
            defer {
                refreshing = false
                if refreshAgain { refreshAgain = false; refresh() }
            }
            do {
                let packages = try await Task.detached { try SharePackage.pending() }.value
                guard self.revision == revision else { return }
                self.packages = packages
                error = nil
            } catch {
                guard self.revision == revision else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func package(_ id: UUID) -> SharePackage.Metadata? { packages.first { $0.id == id } }

    func load(_ id: UUID) async throws -> SharePackage {
        let package = try await Task.detached { try SharePackage.load(id) }.value
        try Task.checkCancellation()
        guard self.package(id) != nil else { throw CocoaError(.fileNoSuchFile) }
        return package
    }

    /// Makes `draftID` the package's home: at most one share per draft, restored on reopening.
    func stage(_ id: UUID, in draftID: String) throws {
        guard !packages.contains(where: { $0.staged == draftID && $0.id != id }) else { throw Occupied() }
        guard var package = package(id) else { return }
        package.staged = draftID
        try package.save()
        revision = UUID()
        if refreshing { refreshAgain = true }
        replace(package)
    }

    func remove(_ id: UUID) throws {
        try package(id)?.remove()
        revision = UUID()
        if refreshing { refreshAgain = true }
        packages.removeAll { $0.id == id }
    }

    private func replace(_ package: SharePackage.Metadata) {
        if let index = packages.firstIndex(where: { $0.id == package.id }) { packages[index] = package }
    }
}
