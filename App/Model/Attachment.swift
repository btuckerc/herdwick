import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import HerdrAPI

struct DraftAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let isImage: Bool
    var state = "Ready"
    var remotePath: String?
    var thumbnail: UIImage?

    static func prepare(_ data: Data, filename: String, imageRequired: Bool = false) throws -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard !imageRequired else { throw AttachmentError.invalidImage }
            guard data.count <= 20 * 1024 * 1024 else { throw AttachmentError.fileTooLarge }
            return Self(data: data, filename: filename, isImage: false)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
        ] as CFDictionary) else { throw AttachmentError.invalidImage }
        let sourceType = CGImageSourceGetType(source) as String? ?? ""
        let allowed = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier]
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let type = allowed.contains(sourceType) && supported.contains(sourceType) ? sourceType : UTType.jpeg.identifier
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            throw AttachmentError.invalidImage
        }
        let properties: CFDictionary? = type == UTType.jpeg.identifier
            ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.invalidImage }
        guard output.length <= 5 * 1024 * 1024 else { throw AttachmentError.imageTooLarge }
        let ext = UTType(type)?.preferredFilenameExtension ?? "jpg"
        let name = (filename as NSString).deletingPathExtension + "." + ext
        return Self(data: output as Data, filename: name, isImage: true, thumbnail: UIImage(cgImage: image))
    }
}

enum AttachmentRetention: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week
    var id: Self { self }
    var label: String { switch self { case .hour: "1 hour"; case .day: "1 day"; case .week: "1 week" } }
    var minutes: Int { switch self { case .hour: 60; case .day: 1440; case .week: 10080 } }
}

enum AttachmentError: LocalizedError {
    case invalidImage, imageTooLarge, fileTooLarge, tooMany
    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image couldn't be read."
        case .imageTooLarge: "Images must be 5 MB or smaller after conversion."
        case .fileTooLarge: "Files must be 20 MB or smaller."
        case .tooMany: "You can attach up to four items."
        }
    }
}

/// Uploads every item before delivering any paste. Failed drafts retain their local data.
@MainActor
func deliverDraft(_ text: String, attachments initial: [DraftAttachment], connection: HostConnection,
                  pane: String, agent: Bool, retention: AttachmentRetention,
                  update: ([DraftAttachment]) -> Void) async throws {
    var attachments = initial
    for index in attachments.indices {
        attachments[index].state = "Uploading"
        update(attachments)
        do {
            attachments[index].remotePath = try await connection.upload(
                attachments[index].data, filename: "\(attachments[index].id.uuidString)-\(attachments[index].filename)",
                retention: retention)
            attachments[index].state = "Uploaded"
            update(attachments)
        } catch {
            attachments[index].state = "Failed"
            update(attachments)
            throw error
        }
    }
    if agent {
        for attachment in attachments where attachment.isImage {
            try await connection.sendText(attachment.remotePath!, pane: pane, submit: false)
            try await Task.sleep(for: .milliseconds(150))
        }
        let files = attachments.filter { !$0.isImage }.map { "@" + $0.remotePath! }
        let message = (files + (text.isEmpty ? [] : [text])).joined(separator: " ")
        try await connection.sendText(message, pane: pane, submit: true)
    } else {
        let paths = attachments.map { shellQuote($0.remotePath!) }
        try await connection.sendText((paths + (text.isEmpty ? [] : [text])).joined(separator: " "),
                                      pane: pane, submit: true)
    }
}
