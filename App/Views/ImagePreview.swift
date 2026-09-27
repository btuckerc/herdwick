import HerdrAPI
import ImageIO
import SwiftUI
import UIKit

/// An image to show full screen: ones embedded in the transcript, or a file on the host,
/// fetched only when opened.
enum ImagePreviewSource: Identifiable {
    case embedded([TranscriptImage], index: Int)
    case file(String)

    var id: String {
        switch self {
        case .embedded(let images, let index): "embedded:\(ObjectIdentifier(images[index]).hashValue)"
        case .file(let path): "file:\(path)"
        }
    }
}

extension EnvironmentValues {
    /// Opens the image preview; nil where previews aren't available.
    @Entry var previewImage: (@MainActor (ImagePreviewSource) -> Void)? = nil
    /// Full detail: embedded images show inline rather than as a label.
    @Entry var inlineImages = false
    @Entry var imageLoader: ImageLoader? = nil
}

/// Fetches an embedded image's bytes when it is shown: inline ones decode in place, omp
/// blobs are read from the host beside the transcript.
struct ImageLoader {
    let connection: HostConnection
    let transcript: String?

    @MainActor func data(_ image: TranscriptImage) async throws -> Data {
        if case .base64 = image.source {
            guard let data = await Task.detached(priority: .userInitiated, operation: { image.inlineData }).value else {
                throw FileUnreadable(path: "image")
            }
            return data
        }
        guard let client = connection.client, let transcript, let path = image.blobPath(transcript: transcript) else {
            throw FileUnreadable(path: "image")
        }
        await fetchGate.enter()
        defer { fetchGate.leave() }
        return try await client.readFile(path: path)
    }
}

/// Two host reads at a time: a transcript of screenshots opened in Full detail asks for all
/// of them at once, and sshd refuses channels past its session limit.
@MainActor private let fetchGate = FetchGate(limit: 2)

@MainActor private final class FetchGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// File extensions previewed from a tapped filename.
func isImagePath(_ path: String) -> Bool {
    ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
        .contains((path as NSString).pathExtension.lowercased())
}

private let imageLinkScheme = "herdwick-image"

/// A link that opens `path` (absolute, `~/…` or relative to the agent's folder) in the preview.
func imageLink(_ path: String) -> URL? {
    var components = URLComponents()
    components.scheme = imageLinkScheme
    components.path = path
    return components.url
}

func imageLinkPath(_ url: URL) -> String? {
    guard url.scheme == imageLinkScheme else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
}

/// Decodes at most `maxPixel` on the long side, off the main thread: never the full bitmap.
private func downsample(_ data: Data, maxPixel: CGFloat) async -> CGImage? {
    await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }.value
}

/// Bounded: it also keeps its keys, and so their compressed bytes, alive.
@MainActor private let thumbnails: NSCache<TranscriptImage, UIImage> = {
    let cache = NSCache<TranscriptImage, UIImage>()
    cache.countLimit = 40
    cache.totalCostLimit = 16 * 1024 * 1024
    return cache
}()

/// An embedded image, small, in the transcript; tap to open it. Holds its bitmap only while
/// on screen: `visible` in the transcript, and within its strip. The transcript isn't lazy,
/// so an off-screen row would otherwise keep it.
struct TranscriptImageThumbnail: View {
    let images: [TranscriptImage]
    let index: Int
    let visible: Bool
    @Environment(\.previewImage) private var previewImage
    @Environment(\.imageLoader) private var loader
    @State private var image: UIImage?
    @State private var inStrip = false

    var body: some View {
        Button { previewImage?(.embedded(images, index: index)) } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.fill.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image \(index + 1)")
        .onScrollVisibilityChange(threshold: 0.01) { inStrip = $0 }
        .task(id: visible && inStrip ? ObjectIdentifier(images[index]) : nil) {
            guard visible, inStrip else { image = nil; return }
            let source = images[index]
            if let cached = thumbnails.object(forKey: source) { image = cached; return }
            guard let loader, let data = try? await loader.data(source),
                  let decoded = await downsample(data, maxPixel: 360), !Task.isCancelled else { return }
            let thumbnail = UIImage(cgImage: decoded)
            thumbnails.setObject(thumbnail, forKey: source, cost: decoded.bytesPerRow * decoded.height)
            image = thumbnail
        }
    }
}

/// Images a message or tool result carries: thumbnails in Full detail, otherwise one label
/// that shows them in place, so nothing is fetched until asked for. A thumbnail opens full screen.
struct TranscriptImages: View {
    let images: [TranscriptImage]
    @Environment(\.inlineImages) private var inline
    @Environment(\.previewImage) private var previewImage
    /// On screen in the transcript's scroll view (the strip's own scroll view doesn't count).
    @State private var visible = false
    @State private var expanded = false

    var body: some View {
        if inline || expanded {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(images.indices, id: \.self) {
                        TranscriptImageThumbnail(images: images, index: $0, visible: visible)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: images.count < 3, vertical: true)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        } else {
            Button { expanded = true } label: {
                Label(images.count == 1 ? "Image" : "\(images.count) images", systemImage: "photo")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(previewImage == nil)
        }
    }
}

/// Full-screen, zoomable preview of one image or a set of embedded ones.
struct ImagePreview: View {
    let source: ImagePreviewSource
    let loader: ImageLoader
    let cwd: String?
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        NavigationStack {
            Group {
                switch source {
                case .embedded(let images, _):
                    TabView(selection: $page) {
                        ForEach(images.indices, id: \.self) { index in
                            PreviewPage(load: { await downsample(try await loader.data(images[index]), maxPixel: Self.screenPixels) }).tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                case .file(let path):
                    PreviewPage(load: { try await fetch(path) })
                }
            }
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { if case .embedded(_, let index) = source { page = index } }
    }

    private var title: String {
        switch source {
        case .embedded(let images, _): images.count > 1 ? "Image \(page + 1) of \(images.count)" : "Image"
        case .file(let path): (path as NSString).lastPathComponent
        }
    }

    /// Sharp on any phone screen with room to zoom, but never the full bitmap of a huge image.
    private static let screenPixels: CGFloat = 3000

    private func fetch(_ path: String) async throws -> CGImage? {
        guard let client = loader.connection.client else { throw HerdrError.noResponse }
        let absolute = path.hasPrefix("/") || path.hasPrefix("~") || cwd == nil ? path : (cwd! as NSString).appendingPathComponent(path)
        let data = try await client.readFile(path: absolute)
        return await downsample(data, maxPixel: Self.screenPixels)
    }
}

private struct PreviewPage: View {
    let load: () async throws -> CGImage?
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else if let failure {
                ContentUnavailableView("Can't show image", systemImage: "photo.badge.exclamationmark", description: Text(failure))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                if let decoded = try await load() { image = UIImage(cgImage: decoded) } else { failure = "Not an image this device can open." }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Pinch and double-tap zoom, as in Photos.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
            }
        }
    }
}
