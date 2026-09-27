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
    }
    /// Newest first. Throws while the device is locked rather than reporting none.
    static func pending() throws -> [Self] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Self.self, from: Data(contentsOf: $0)) }
            .sorted { $0.saved > $1.saved }
    }
    func remove() throws {
        try FileManager.default.removeItem(at: Self.directory().appendingPathComponent(id.uuidString + ".json"))
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
