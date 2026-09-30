import HerdrAPI
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// An image to show full screen: ones embedded in the transcript, a file on the host,
/// fetched only when opened, or one about to be sent.
enum ImagePreviewSource: Identifiable {
    case embedded([TranscriptImage], index: Int)
    case file(String)
    case local(Data, name: String, id: UUID)

    var id: String {
        switch self {
        case .embedded(let images, let index): "embedded:\(ObjectIdentifier(images[index]).hashValue)"
        case .file(let path): "file:\(path)"
        case .local(_, _, let id): "local:\(id)"
        }
    }

    /// Local, with no host to read from.
    var isLocal: Bool { if case .local = self { true } else { false } }

    /// The image's original bytes, as sent or read from the host.
    @MainActor func data(_ loader: ImageLoader?) async throws -> Data {
        switch self {
        case .local(let data, _, _): return data
        case .embedded(let images, let index):
            guard let loader else { throw FileUnreadable(path: "image") }
            return try await loader.data(images[index])
        case .file(let path):
            guard let loader else { throw FileUnreadable(path: path) }
            return try await loader.data(path: path)
        }
    }
}

extension EnvironmentValues {
    /// Opens the image preview; nil where previews aren't available.
    @Entry var previewImage: EnvironmentAction<ImagePreviewSource, Void>? = nil
    /// Full detail: embedded images show inline rather than as a label.
    @Entry var inlineImages = false
    @Entry var imageLoader: ImageLoader? = nil
    /// Saves a held thumbnail's image; nil where saving isn't offered.
    @Entry var photoSaver: PhotoSaver? = nil
}

/// Saves an image's original bytes to the photo library, asking for add-only access on the
/// first save. `SavesPhotos` shows how it went.
@MainActor @Observable final class PhotoSaver {
    fileprivate(set) var saved = 0
    fileprivate var failure: PhotoSaveFailure?

    func save(_ original: @escaping @MainActor () async throws -> Data) {
        Task {
            switch await Self.authorize() {
            case .authorized, .limited: break
            case .restricted: failure = .restricted; return
            default: failure = .denied; return
            }
            do {
                try await Self.add(try await original())
                saved += 1
            } catch {
                failure = .other(error.localizedDescription)
            }
        }
    }

    // Nonisolated: Photos runs these callbacks on its own queues, and a closure written on the
    // main actor would trap there.
    private nonisolated static func authorize() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private nonisolated static func add(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

fileprivate enum PhotoSaveFailure {
    case denied, restricted, other(String)

    var title: String {
        switch self {
        case .denied: "Allow Photo Access"
        case .restricted: "Can't Save to Photos"
        case .other: "Couldn't Save Image"
        }
    }

    var message: String {
        switch self {
        case .denied: "Allow Herdwick to add photos in Settings."
        case .restricted: "Adding photos is restricted on this device."
        case .other(let reason): reason
        }
    }
}

/// Offers `saver` to the thumbnails within, and shows its outcome: a brief "Saved to Photos",
/// or an alert saying why not.
struct SavesPhotos: ViewModifier {
    let saver: PhotoSaver
    @Environment(Settings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .environment(\.photoSaver, saver)
            .overlay {
                if confirming {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .sensoryFeedback(.success, trigger: saver.saved) { _, _ in settings.haptics }
            .task(id: saver.saved) {
                guard saver.saved > 0 else { return }
                withAnimation(.snappy) { confirming = true }
                guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                withAnimation(.smooth) { confirming = false }
            }
            .alert(saver.failure?.title ?? "", isPresented: .init(get: { saver.failure != nil }, set: { if !$0 { saver.failure = nil } }),
                   presenting: saver.failure) { failure in
                if case .denied = failure {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { Text($0.message) }
    }
}

/// A closure for the environment that compares equal across updates of the view that sets
/// it. A bare closure can't be compared, so every view reading it would redraw each time
/// that view does (each keystroke in the composer). Its captures must be references (state,
/// models) that read current values when it runs.
struct EnvironmentAction<Input, Output>: Equatable {
    let run: @MainActor (Input) -> Output
    init(_ run: @escaping @MainActor (Input) -> Output) { self.run = run }
    @MainActor func callAsFunction(_ input: Input) -> Output { run(input) }
    nonisolated static func == (_: Self, _: Self) -> Bool { true }
}

/// Fetches an image's bytes when it is shown: inline ones decode in place, omp blobs are read
/// from the host beside the transcript, as are inline images of history that isn't loaded;
/// files the agent names are read relative to its folder.
struct ImageLoader: Equatable {
    let connection: HostConnection
    let transcript: String?
    var cwd: String? = nil

    @MainActor func data(_ image: TranscriptImage) async throws -> Data {
        try Task.checkCancellation()
        switch image.source {
        case .base64:
            guard let data = await Task.detached(priority: .userInitiated, operation: { image.inlineData }).value else {
                throw FileUnreadable(path: "image")
            }
            return data
        case .blob:
            guard let transcript, let path = image.blobPath(transcript: transcript) else { throw FileUnreadable(path: "image") }
            return try await read(path)
        case .transcriptLine(let line, let ordinal):
            guard let transcript, let client = connection.client else { throw FileUnreadable(path: "image") }
            try await fetchGate.enter()
            defer { fetchGate.leave() }
            try Task.checkCancellation()
            return try await client.transcriptImage(path: transcript, line: line, ordinal: ordinal)
        }
    }

    /// A file on the host: absolute, `~/…`, or relative to the agent's folder.
    @MainActor func data(path: String, maxBytes: Int = 20_000_000) async throws -> Data {
        guard path.hasPrefix("/") || path.hasPrefix("~") || cwd == nil else {
            return try await read((cwd! as NSString).appendingPathComponent(path), maxBytes: maxBytes)
        }
        return try await read(path, maxBytes: maxBytes)
    }

    @MainActor private func read(_ path: String, maxBytes: Int = 20_000_000) async throws -> Data {
        guard let client = connection.client else { throw FileUnreadable(path: path) }
        try await fetchGate.enter()
        defer { fetchGate.leave() }
        try Task.checkCancellation()
        return try await client.readFile(path: path, maxBytes: maxBytes)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connection === rhs.connection && lhs.transcript == rhs.transcript && lhs.cwd == rhs.cwd
    }
}

/// Two host reads at a time: a transcript of screenshots opened in Full detail asks for all
/// of them at once, and sshd refuses channels past its session limit.
@MainActor private let fetchGate = FetchGate(limit: 2)

@MainActor private final class FetchGate {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    init(limit: Int) { self.limit = limit }

    func enter() async throws {
        try Task.checkCancellation()
        if running < limit { running += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().continuation.resume() }
    }
}

/// File extensions previewed from a tapped filename.
func isImagePath(_ path: String) -> Bool {
    ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
        .contains((path as NSString).pathExtension.lowercased())
}

/// Text and source files opened in the file viewer from a tapped name.
func isTextPath(_ path: String) -> Bool {
    ["md", "markdown", "txt", "log", "json", "jsonl", "yml", "yaml", "toml", "xml", "plist", "csv", "tsv",
     "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "sh", "zsh", "bash", "fish", "rs", "go", "lua",
     "rb", "java", "kt", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "sql", "html", "css", "scss",
     "vue", "svelte", "proto", "graphql", "diff", "patch", "conf", "ini", "cfg", "gradle", "nix", "tf"]
        .contains((path as NSString).pathExtension.lowercased())
}

/// The file a code span or word names: no spaces or URL scheme, a line reference
/// (`a.swift:42`, `a.swift#L42-L50`) dropped, and an image or text extension.
func namedFile(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()[]<>,;"))
    guard !trimmed.contains(" "), !trimmed.contains("://") else { return nil }
    let path = trimmed.replacing(/(:\d+(-\d+)?(:\d+)?|#L\d+(-L?\d+)?)$/, with: "")
    return isImagePath(path) || isTextPath(path) ? path : nil
}

private let fileLinkScheme = "herdwick-file"

/// A link that opens `path` (absolute, `~/…` or relative to the agent's folder) in a preview.
func fileLink(_ path: String) -> URL? {
    var components = URLComponents()
    components.scheme = fileLinkScheme
    components.path = path
    return components.url
}

/// The host path a tapped link opens: one of ours, or a Markdown link with no scheme or `file:`.
func fileLinkPath(_ url: URL) -> String? {
    switch url.scheme {
    case fileLinkScheme: return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    case nil, "file":
        let path = url.scheme == nil ? (url.relativeString.removingPercentEncoding ?? url.relativeString) : url.path(percentEncoded: false)
        return namedFile(path)
    default: return nil
    }
}

/// Tapped file links: images open the image preview, text and source files the file viewer.
/// `resolve` finds what the conversation knows of a named file: its full path, and the images
/// a read of it returned (shown without asking the host).
struct FileLinks: ViewModifier {
    let loader: ImageLoader
    var resolve: @MainActor (String) -> (path: String, images: [TranscriptImage])? = { _ in nil }
    @State private var image: ImagePreviewSource?
    @State private var file: FileTarget?

    private struct FileTarget: Identifiable {
        let path: String
        var id: String { path }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let named = fileLinkPath(url) else { return .systemAction }
                let found = resolve(named)
                let path = found?.path ?? named
                if let images = found?.images, !images.isEmpty {
                    image = .embedded(images, index: 0)
                } else if isImagePath(path) {
                    image = .file(path)
                } else {
                    file = FileTarget(path: path)
                }
                return .handled
            })
            .sheet(item: $image) { ImagePreview(source: $0, loader: loader) }
            .sheet(item: $file) { FilePreview(path: $0.path, loader: loader) }
    }
}

/// A text or source file on the host, read when opened: Markdown rendered, anything else
/// monospaced, the first 3,000 lines of at most 2 MB.
struct FilePreview: View {
    let path: String
    let loader: ImageLoader
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var cut = false
    @State private var failure: String?
    private static let maxLines = 3000

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) {
                                MarkdownText(text: text)
                            } else {
                                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if cut { Text("The first \(Self.maxLines) lines.").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .padding(16)
                    }
                } else if let failure {
                    ContentUnavailableView("Couldn't Open", systemImage: "doc", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationSubtitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let text { ToolbarItem(placement: .topBarLeading) { ShareLink(item: text) } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let data = try await loader.data(path: path, maxBytes: 2_000_000)
            guard !data.contains(0), let string = String(data: data, encoding: .utf8) else {
                failure = "Not a text file."
                return
            }
            let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
            cut = lines.count > Self.maxLines
            text = cut ? lines.prefix(Self.maxLines).joined(separator: "\n") : string
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Decodes at most `maxPixel` on the long side, off the main thread: never the full bitmap.
func downsample(_ data: Data, maxPixel: CGFloat) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    return await Task.detached(priority: .userInitiated) { decode(data) { _ in maxPixel } }.value
}

/// Decodes enough to fill a square `side` pixels wide edge to edge: the short side covers it,
/// the long side at most four times that.
func downsample(_ data: Data, fill side: CGFloat) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    return await Task.detached(priority: .userInitiated) {
        decode(data) { size in side * min(4, max(1, max(size.width, size.height) / max(1, min(size.width, size.height)))) }
    }.value
}

private func decode(_ data: Data, maxPixel: (CGSize) -> CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let size = CGSize(width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0,
                      height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel(size),
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
}

/// A decoded thumbnail, good for tiles up to `covers` pixels wide.
private final class Thumbnail {
    let image: UIImage
    let covers: Int
    init(_ image: UIImage, covers: Int) { self.image = image; self.covers = covers }
}

/// Bounded: it also keeps its keys, and so their compressed bytes, alive.
@MainActor private let thumbnails: NSCache<TranscriptImage, Thumbnail> = {
    let cache = NSCache<TranscriptImage, Thumbnail>()
    cache.countLimit = 40
    cache.totalCostLimit = 16 * 1024 * 1024
    return cache
}()

/// An image, small, in the transcript; tap to open it, or hold to save it. A square tile:
/// `side` points, or the width it's given. Holds its bitmap only while on screen: `visible` in
/// the transcript, and within its strip. The transcript isn't lazy, so an off-screen row would
/// otherwise keep it.
struct TranscriptImageThumbnail: View {
    let source: ImagePreviewSource
    let number: Int
    let visible: Bool
    var side: CGFloat? = 120
    @Environment(\.previewImage) private var previewImage
    @Environment(\.imageLoader) private var loader
    @Environment(\.photoSaver) private var saver
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var inStrip = false
    @State private var width: CGFloat = 0

    private var cornerRadius: CGFloat { side == nil ? 6 : 12 }
    /// Pixels the tile covers; nil until it's on screen and measured.
    private var pixels: Int? { visible && inStrip && width > 0 ? Int((width * displayScale).rounded()) : nil }

    var body: some View {
        // The fill is laid out in the overlay of a fixed square and hit-tested by that square:
        // clipping alone left each tile's taps spilling over its neighbours.
        Button { previewImage?(source) } label: {
            tile
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .contentShape(.interaction, .rect(cornerRadius: cornerRadius))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: cornerRadius))
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image \(number)")
        .contextMenu {
            if let saver, loader != nil || source.isLocal {
                Button("Save to Photos", systemImage: "square.and.arrow.down") {
                    saver.save { [source, loader] in try await source.data(loader) }
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { inStrip = $0 }
        .task(id: pixels.map { "\(source.id)@\($0)" }) {
            guard let pixels else { image = nil; return }
            // Only embedded images are cached: a path names different files on different hosts.
            let embedded: TranscriptImage? = if case .embedded(let images, let index) = source { images[index] } else { nil }
            if let embedded, let cached = thumbnails.object(forKey: embedded), cached.covers >= pixels { image = cached.image; return }
            guard let data = try? await source.data(loader), !Task.isCancelled,
                  let decoded = await downsample(data, fill: CGFloat(pixels)), !Task.isCancelled else { return }
            let thumbnail = UIImage(cgImage: decoded)
            // Short of the tile only when the image itself is that small (or very long): no larger decode exists.
            let short = min(decoded.width, decoded.height)
            if let embedded { thumbnails.setObject(Thumbnail(thumbnail, covers: short >= pixels - 1 ? short : .max), forKey: embedded, cost: decoded.bytesPerRow * decoded.height) }
            image = thumbnail
        }
    }

    @ViewBuilder private var tile: some View {
        let fill = Rectangle().fill(.fill.secondary)
        if let side { fill.frame(width: side, height: side) } else { fill.aspectRatio(1, contentMode: .fit) }
    }
}

/// Images a message or tool result carries, or a reply embeds: thumbnails in Full detail,
/// otherwise one label that shows them in place, so nothing is fetched until asked for. A
/// thumbnail opens full screen.
struct TranscriptImages: View {
    let sources: [ImagePreviewSource]
    @Environment(\.inlineImages) private var inline
    @Environment(\.previewImage) private var previewImage
    /// On screen in the transcript's scroll view (the strip's own scroll view doesn't count).
    @State private var visible = false
    @State private var expanded = false

    init(images: [TranscriptImage]) { sources = images.indices.map { .embedded(images, index: $0) } }
    init(paths: [String]) { sources = paths.map(ImagePreviewSource.file) }

    var body: some View {
        if inline || expanded {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(sources.indices, id: \.self) {
                        TranscriptImageThumbnail(source: sources[$0], number: $0 + 1, visible: visible)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: sources.count < 3, vertical: true)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        } else {
            Button { expanded = true } label: {
                Label(sources.count == 1 ? "Image" : "\(sources.count) images", systemImage: "photo")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(previewImage == nil)
        }
    }
}

/// Every image the agent's tools returned, newest first, in square tiles filling the width; a
/// tap pages through them full screen from there, a hold saves one. With earlier history
/// unloaded, the loaded ones show at once and the host lists the rest (`whole`, oldest first);
/// fetched, as ever, only once on screen.
struct ImageGrid: View {
    let loaded: [TranscriptImage]
    let whole: (@MainActor () async throws -> [TranscriptImage])?
    let loader: ImageLoader
    @Environment(\.dismiss) private var dismiss
    @State private var previewing: ImagePreviewSource?
    @State private var all: [TranscriptImage]?
    @State private var partial = false
    @State private var saver = PhotoSaver()

    private var images: [TranscriptImage] { all ?? loaded }

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    if whole != nil, all == nil, !partial { ProgressView() } else { ContentUnavailableView("No Images", systemImage: "photo") }
                } else {
                    ScrollView {
                        // Three across on a phone held upright, more as the width allows.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                            ForEach(images.indices, id: \.self) { index in
                                TranscriptImageThumbnail(source: .embedded(images, index: index), number: index + 1, visible: true, side: nil)
                            }
                        }
                        .padding(4)
                        if partial { Text("Loaded messages only").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(images.count == 1 ? "1 Image" : "\(images.count) Images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Presented over the conversation, so it previews and saves by itself.
        .environment(\.imageLoader, loader)
        .environment(\.previewImage, EnvironmentAction { previewing = $0 })
        .modifier(SavesPhotos(saver: saver))
        .sheet(item: $previewing) { ImagePreview(source: $0, loader: loader) }
        .task { await listWhole() }
    }

    private func listWhole() async {
        guard let whole else { return }
        do {
            let listed = try await whole()
            // The whole file holds every loaded image (and abandoned branches' too); fewer
            // means the listing missed some, so the loaded ones stay.
            guard listed.count >= loaded.count else { partial = true; return }
            // Loaded blobs keep their objects, so their cached thumbnails stay.
            var kept: [String: TranscriptImage] = [:]
            for image in loaded { if case .blob(let hash) = image.source { kept[hash] = image } }
            all = listed.reversed().map { image in
                if case .blob(let hash) = image.source, let known = kept[hash] { known } else { image }
            }
        } catch {
            partial = true
        }
    }
}

/// Full-screen, zoomable preview of one image or a set of embedded ones. The one showing can be
/// shared or saved as its original bytes, never the preview's downsample.
struct ImagePreview: View {
    let source: ImagePreviewSource
    /// Reads transcript and host images; nil where only local ones are shown.
    let loader: ImageLoader?
    @Environment(\.dismiss) private var dismiss
    /// Starts on the tapped image, so the first page drawn is that one.
    @State private var page: Int
    /// Each loaded page's original, written out as a file named for it.
    @State private var originals: [Int: URL] = [:]
    @State private var saver = PhotoSaver()

    init(source: ImagePreviewSource, loader: ImageLoader?) {
        self.source = source
        self.loader = loader
        let start = if case .embedded(_, let index) = source { index } else { 0 }
        _page = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch source {
                case .embedded(let images, _):
                    TabView(selection: $page) {
                        ForEach(images.indices, id: \.self) { index in
                            pageView(index, .embedded(images, index: index)).tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                case .file, .local:
                    pageView(0, source)
                }
            }
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let file = originals[page] {
                        ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("Share", systemImage: "square.and.arrow.up") {}.disabled(true)
                    }
                    Spacer()
                    Button("Save to Photos", systemImage: "square.and.arrow.down") {
                        guard let file = originals[page] else { return }
                        saver.save { try await Task.detached { try Data(contentsOf: file) }.value }
                    }
                    .disabled(originals[page] == nil)
                }
            }
        }
        .modifier(SavesPhotos(saver: saver))
        .onDisappear { try? FileManager.default.removeItem(at: sharedImages) }
    }

    private func pageView(_ index: Int, _ source: ImagePreviewSource) -> some View {
        PreviewPage(source: source, loader: loader, name: name(index)) { originals[index] = $0 }
    }

    private var title: String {
        switch source {
        case .embedded(let images, _): images.count > 1 ? "Image \(page + 1) of \(images.count)" : "Image"
        case .file(let path): (path as NSString).lastPathComponent
        case .local(_, let name, _): name
        }
    }

    /// The shared or saved file's name, before its extension.
    private func name(_ index: Int) -> String {
        switch source {
        case .embedded(let images, _): images.count > 1 ? "Image \(index + 1)" : "Image"
        case .file(let path): ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .local(_, let name, _): (name as NSString).deletingPathExtension
        }
    }
}

/// Where previews write the originals they offer to share; cleared as the preview closes.
private let sharedImages = URL.temporaryDirectory.appending(path: "Shared Images", directoryHint: .isDirectory)

/// The image's bytes as `name` plus the extension of its actual format, in a folder of its own.
private func writeOriginal(_ data: Data, name: String) async -> URL? {
    await Task.detached(priority: .utility) {
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
        let folder = sharedImages.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let base = name.isEmpty ? "Image" : name.replacingOccurrences(of: "/", with: "-")
        let file = folder.appending(path: type?.preferredFilenameExtension.map { "\(base).\($0)" } ?? base)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }.value
}

private struct PreviewPage: View {
    let source: ImagePreviewSource
    let loader: ImageLoader?
    let name: String
    /// Called with the original written out, once it shows.
    let loaded: (URL) -> Void
    @State private var image: UIImage?
    @State private var failure: String?

    /// Sharp on any phone screen with room to zoom, but never the full bitmap of a huge image.
    private static let screenPixels: CGFloat = 3000

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
                let data = try await source.data(loader)
                guard let decoded = await downsample(data, maxPixel: Self.screenPixels) else {
                    failure = "Not an image this device can open."
                    return
                }
                image = UIImage(cgImage: decoded)
                if let file = await writeOriginal(data, name: name), !Task.isCancelled { loaded(file) }
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
