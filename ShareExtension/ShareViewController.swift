import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: close) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save", action: save).disabled({ if case .ready = phase { false } else { true } }())
                        }
                    }
                }
        }
        .task { await load() }
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
                                if let image = UIImage(data: package.images[index].data) {
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
        guard case .ready(var package) = phase else { return }
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
            phase = .ready(package)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private struct ImportLimit: LocalizedError {
        var errorDescription: String? { "Herdwick takes up to \(SharePackage.maximumImages) images and 20 MB at a time." }
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                else if let text = item as? String { continuation.resume(returning: text) }
                else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
