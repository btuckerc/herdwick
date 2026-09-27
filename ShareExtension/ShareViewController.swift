import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

/// Import only: never dials a host, sends a message, or opens the containing app. The agent
/// picked here is a suggestion the app shows on its Shared shelf; the user reviews and sends there.
@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareSheet(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct ShareSheet: View {
    let providers: [NSItemProvider]
    let close: () -> Void

    private enum Phase { case loading, ready(SharePackage), saved, failed(String) }
    @State private var phase = Phase.loading
    @State private var destination: String?
    @State private var thumbnails: [UIImage?] = []
    @State private var dismissed = false
    /// Conversations the app last saw with a transcript, from the App Group; may be out of date.
    private let snapshot = AttentionSnapshot.load()
    private var agents: [AttentionSnapshot.Item] { snapshot?.items.filter { $0.draftID != nil } ?? [] }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Herdwick")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    switch phase {
                    case .saved, .failed:
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                    case .loading, .ready:
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", role: .cancel) { dismissed = true; close() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save", action: save).disabled({ if case .ready = phase { false } else { true } }())
                        }
                    }
                }
        }
        .task(id: dismissed) { if !dismissed { await load() } }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("Couldn't Import", systemImage: "exclamationmark.triangle", description: Text(message))
        case .saved:
            ContentUnavailableView("Saved to Shared", systemImage: "checkmark.circle",
                                   description: Text("Open Herdwick to review and send it."))
        case .ready(let package):
            List {
                Section {
                    if !package.text.isEmpty { Text(package.text).lineLimit(6) }
                    if !package.images.isEmpty {
                        HStack {
                            ForEach(package.images.indices, id: \.self) { index in
                                if thumbnails.indices.contains(index), let image = thumbnails[index] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
                Section {
                    row("Decide in Herdwick", detail: nil, id: nil)
                    ForEach(agents) { agent in
                        row(agent.title, detail: agent.place, id: agent.draftID)
                    }
                } header: {
                    Text("For")
                } footer: {
                    if let snapshot, !agents.isEmpty {
                        Text("Agents as Herdwick last saw them, \(snapshot.updated.formatted(.relative(presentation: .named))). Nothing is sent until you send it in the app.")
                    } else {
                        Text("Nothing is sent until you send it in the app.")
                    }
                }
            }
        }
    }

    private func row(_ title: String, detail: String?, id: String?) -> some View {
        Button { destination = id } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(Color.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Color.secondary) }
                }
                Spacer()
                if destination == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func save() {
        guard !dismissed, case .ready(var package) = phase else { return }
        if let item = agents.first(where: { $0.draftID == destination }), let draftID = item.draftID {
            package.destination = .init(draftID: draftID, title: item.title, place: item.place)
        }
        package.saved = .now
        do {
            try package.save()
            phase = .saved
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func load() async {
        do {
            guard !providers.isEmpty else { throw CocoaError(.fileReadUnknown) }
            var package = SharePackage(id: UUID(), text: "", images: [])
            var texts: [String] = []
            for provider in providers {
                try Task.checkCancellation()
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    package.images.append(.init(filename: "Shared image", data: try await load(provider, type: UTType.image.identifier)))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    texts.append(try await loadText(provider, type: UTType.url.identifier))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    texts.append(try await loadText(provider, type: UTType.text.identifier))
                } else { throw CocoaError(.fileReadUnknown) }
                package.text = texts.joined(separator: "\n")
                guard package.images.count <= SharePackage.maximumImages,
                      package.text.utf8.count + package.images.reduce(0, { $0 + $1.data.count }) <= SharePackage.maximumBytes else {
                    throw ImportLimit()
                }
            }
            let images = package.images
            let previews = await Task.detached {
                images.map { image -> UIImage? in
                    guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 168,
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: thumbnail)
                }
            }.value
            try Task.checkCancellation()
            guard !dismissed else { return }
            thumbnails = previews
            phase = .ready(package)
        } catch {
            guard !Task.isCancelled, !dismissed else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private struct ImportLimit: LocalizedError {
        var errorDescription: String? { "Herdwick takes up to \(SharePackage.maximumImages) images and 20 MB at a time." }
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await providerValue { gate in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { gate.finish(.success(data)) }
                else { gate.finish(.failure(error ?? CocoaError(.fileReadUnknown))) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider, type: String) async throws -> String {
        try await providerValue { gate in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let url = item as? URL { gate.finish(.success(url.absoluteString)) }
                else if let text = item as? String { gate.finish(.success(text)) }
                else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    gate.finish(.success(text))
                } else { gate.finish(.failure(error ?? CocoaError(.fileReadUnknown))) }
            }
            return nil
        }
    }

    private func providerValue<Value: Sendable>(
        _ start: (ProviderLoad<Value>) -> Progress?
    ) async throws -> Value {
        let gate = ProviderLoad<Value>()
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(30))
                gate.finish(.failure(CocoaError(.fileReadUnknown)))
            } catch {}
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if gate.wait(continuation) { gate.attach(start(gate)) }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

/// Callback, cancellation and deadline race to settle once; late provider results are discarded.
private final class ProviderLoad<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var progress: Progress?

    func wait(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ progress: Progress?) {
        lock.lock()
        let finished = result != nil
        if !finished { self.progress = progress }
        lock.unlock()
        if finished { progress?.cancel() }
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let progress = self.progress
        self.progress = nil
        lock.unlock()
        if case .failure = result { progress?.cancel() }
        continuation?.resume(with: result)
    }
}
