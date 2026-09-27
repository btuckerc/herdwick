import Foundation
import Observation

/// Text and images shared into Herdwick, waiting on the Inbox's Shared shelf until a send that
/// carried them succeeds. Refreshed when a window becomes active; never presents itself.
@MainActor @Observable
final class SharedInbox {
    static let shared = SharedInbox()

    private(set) var packages: [SharePackage] = []
    /// Why the shelf couldn't be read (a locked device); the last packages read stay listed.
    private(set) var error: String?

    struct Occupied: LocalizedError {
        var errorDescription: String? {
            "This conversation already holds another share. Send it or remove it from Shared first."
        }
    }

    func refresh() {
        do {
            packages = try SharePackage.pending()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func package(_ id: UUID) -> SharePackage? { packages.first { $0.id == id } }

    /// Makes `draftID` the package's home: at most one share per draft, restored on reopening.
    func stage(_ id: UUID, in draftID: String) throws {
        guard var package = package(id) else { return }
        package.staged = draftID
        try package.save()
        replace(package)
    }

    func remove(_ id: UUID) throws {
        try package(id)?.remove()
        packages.removeAll { $0.id == id }
    }

    private func replace(_ package: SharePackage) {
        if let index = packages.firstIndex(where: { $0.id == package.id }) { packages[index] = package }
    }
}
