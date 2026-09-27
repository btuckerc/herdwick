import HerdrAPI
import SwiftUI

/// Everything shared into Herdwick that hasn't been sent yet, newest first. Opening one only
/// stages it in a conversation's composer for review; nothing here sends.
struct SharedShelfView: View {
    /// Stage the package in this agent's conversation.
    let choose: (UUID, Thread) -> Void
    /// Start an agent for the package.
    let newAgent: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    private var inbox: SharedInbox { .shared }
    @State private var removeError: String?

    var body: some View {
        NavigationStack {
            List {
                if let error = inbox.error {
                    Section { Label(error, systemImage: "lock").foregroundStyle(.secondary) }
                }
                ForEach(inbox.packages) { package in
                    NavigationLink(value: package.id) { SharedPackageRow(package: package) }
                }
                .onDelete { offsets in
                    for id in offsets.map({ inbox.packages[$0].id }) {
                        do { try inbox.remove(id) } catch { removeError = error.localizedDescription }
                    }
                }
            }
            .overlay {
                if inbox.packages.isEmpty, inbox.error == nil {
                    ContentUnavailableView("Nothing Shared", systemImage: "square.and.arrow.down",
                                           description: Text("Share text, links or images to Herdwick from any app."))
                }
            }
            .navigationTitle("Shared")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let package = inbox.package(id) {
                    SharedPackageReview(package: package, choose: choose, newAgent: newAgent)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Couldn't Remove", isPresented: .init(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
                Button("OK", role: .cancel) { removeError = nil }
            } message: { Text(removeError ?? "") }
        }
        .onAppear { inbox.refresh() }
    }
}

private struct SharedPackageRow: View {
    let package: SharePackage.Metadata
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(package.text.isEmpty ? "\(package.images.count) image\(package.images.count == 1 ? "" : "s")" : package.text)
                .lineLimit(2)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if !package.text.isEmpty, !package.images.isEmpty {
            parts.append("\(package.images.count) image\(package.images.count == 1 ? "" : "s")")
        }
        parts.append(package.destination.map { "For \($0.title)" } ?? "Choose an agent")
        if package.saved != .distantPast { parts.append(package.saved.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

private struct SharedPackageReview: View {
    let package: SharePackage.Metadata
    let choose: (UUID, Thread) -> Void
    let newAgent: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var thumbnails: [Int: UIImage] = [:]

    /// Conversations that can take it: live, with a transcript to review the draft against.
    private var threads: [Thread] {
        model.threads.filter { $0.connection.isLive && $0.agent.agentSession != nil }
    }

    private func draftID(_ thread: Thread) -> String? {
        DraftStore.id(host: thread.connection.identity, agent: thread.agent)
    }

    var body: some View {
        let suggested = package.destination.flatMap { destination in threads.first { draftID($0) == destination.draftID } }
        List {
            Section {
                if !package.text.isEmpty { Text(package.text).lineLimit(12).textSelection(.enabled) }
                if !package.images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(package.images.indices, id: \.self) { index in
                                if let image = thumbnails[index] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Opens in the agent's message field for review. Nothing is sent until you send it.")
            }
            if let destination = package.destination {
                Section("Chosen When Shared") {
                    if let suggested {
                        Button { choose(package.id, suggested) } label: { ThreadLabel(thread: suggested) }
                    } else {
                        VStack(alignment: .leading) {
                            Text(destination.title)
                            Text("\(destination.place) · not available now").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Agents") {
                ForEach(threads.filter { $0.id != suggested?.id }) { thread in
                    Button { choose(package.id, thread) } label: { ThreadLabel(thread: thread) }
                }
                Button("New Agent…", systemImage: "plus") { newAgent(package.id) }
            }
        }
        .navigationTitle("Review Share")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: package.id) {
            thumbnails = [:]
            guard !package.images.isEmpty,
                  let loaded = try? await SharedInbox.shared.load(package.id), !Task.isCancelled else { return }
            for (index, image) in loaded.images.enumerated() {
                guard !Task.isCancelled else { return }
                if let decoded = await downsample(image.data, maxPixel: 216), !Task.isCancelled {
                    thumbnails[index] = UIImage(cgImage: decoded)
                }
            }
        }
    }
}

private struct ThreadLabel: View {
    let thread: Thread
    var body: some View {
        VStack(alignment: .leading) {
            Text(thread.agent.conversationTitle).foregroundStyle(Color.primary)
            Text([thread.connection.profile.name, thread.workspace?.label].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Color.secondary)
        }
    }
}
