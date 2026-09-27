import Foundation

/// A completed package is a single atomic, protected file. No provider URLs survive import.
/// It stays intact on the app's Shared shelf until a send that carried it succeeds.
struct SharePackage: Codable, Identifiable {
    struct Image: Codable { let filename: String; let data: Data }
    /// The agent picked in the share sheet: a suggestion shown in the app, never a delivery.
    struct Destination: Codable, Equatable {
        /// The conversation's `DraftStore` id, which survives herdr reusing a pane id.
        let draftID: String
        let title: String
        let place: String
    }
    let id: UUID
    var text: String
    var images: [Image]
    var saved = Date()
    var destination: Destination?
    /// The draft this share was staged in; that conversation restores its images on opening.
    var staged: String?
    static let maximumBytes = 20 * 1024 * 1024
    /// The composer's attachment limit.
    static let maximumImages = 4

    init(id: UUID, text: String, images: [Image]) {
        self.id = id
        self.text = text
        self.images = images
    }

    static func directory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.btuckerc.herdwick") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        return directory
    }
    func save() throws {
        guard images.count <= Self.maximumImages,
              text.utf8.count + images.reduce(0, { $0 + $1.data.count }) <= Self.maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let url = try Self.directory().appendingPathComponent(id.uuidString + ".json")
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        try metadata.save()
    }
    /// Newest first. Old packages acquire a lightweight sidecar once, on the I/O worker.
    static func pending() throws -> [Metadata] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let sidecar = url.deletingPathExtension().appendingPathExtension("metadata")
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: sidecar))
                }
                let metadata = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).metadata
                try metadata.save()
                return metadata
            }
            .sorted { $0.saved > $1.saved }
    }

    static func load(_ id: UUID) throws -> Self {
        let root = try directory()
        var package = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json")))
        let sidecar = root.appendingPathComponent(id.uuidString + ".metadata")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            package.staged = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: sidecar)).staged
        }
        return package
    }

    var metadata: Metadata {
        Metadata(id: id, text: text, images: images.map { .init(filename: $0.filename) },
                 saved: saved, destination: destination, staged: staged)
    }

    struct Metadata: Codable, Identifiable, Sendable {
        struct Image: Codable, Sendable { let filename: String }
        let id: UUID
        let text: String
        let images: [Image]
        let saved: Date
        let destination: Destination?
        var staged: String?

        func save() throws {
            let url = try SharePackage.directory().appendingPathComponent(id.uuidString + ".metadata")
            try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        }

        func remove() throws {
            let root = try SharePackage.directory()
            try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".metadata"))
        }
    }
}

extension SharePackage {
    private enum CodingKeys: String, CodingKey { case id, text, images, saved, destination, staged }

    /// Packages saved before the shelf existed load as unassigned and oldest.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        images = try c.decode([Image].self, forKey: .images)
        saved = try c.decodeIfPresent(Date.self, forKey: .saved) ?? .distantPast
        destination = try c.decodeIfPresent(Destination.self, forKey: .destination)
        staged = try c.decodeIfPresent(String.self, forKey: .staged)
    }
}

extension SharePackage: Sendable {}
extension SharePackage.Image: Sendable {}
extension SharePackage.Destination: Sendable {}
