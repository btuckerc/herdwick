import HerdrAPI
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

extension AgentStatus {
    var label: String {
        switch self {
        case .blocked: "Needs you"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: .orange
        case .done: .green
        case .working: .blue
        case .idle: .secondary
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .working: "circle.dotted"
        case .idle: "moon.zzz.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct HostTitle: View {
    let name: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(name).font(.headline)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(subtitle)")
    }
}

struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: status.symbol)
            .foregroundStyle(status.tint)
            .symbolEffect(.rotate, isActive: status == .working)
            .font(.body)
            .frame(width: 24)
            .accessibilityLabel(status.label)
    }
}

/// A failure only the user can fix, shown where they are looking, with the fix.
struct FailureCard: View {
    let connection: HostConnection
    let failure: ConnectionFailure
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Can't connect to \(connection.profile.name)", systemImage: "bolt.horizontal.circle")
                .font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GlassEffectContainer {
                HStack {
                    Button("Retry") { connection.handle(.userRetry) }
                        .buttonStyle(.glassProminent)
                    if connection.rejectedHostKey != nil {
                        Button("Trust New Key") { connection.trustPresentedHostKey() }
                            .buttonStyle(.glass)
                    }
                    if let onEdit {
                        Button("Edit Host", action: onEdit).buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 24))
        .padding()
    }
}

extension Agent {
    /// The conversation's name as a person would say it. Agents put a glyph before their
    /// terminal title ("π: Fix the build", "✳ Claude Code"); the name starts after it.
    var conversationTitle: String {
        var text = Substring(title)
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 2 {
            text = text[text.index(after: colon)...]
        }
        text = text.drop { !$0.isLetter && !$0.isNumber }
        return text.isEmpty ? title : String(text)
    }

    /// Whether the agent's own transcript can be shown as a conversation: omp reports a path,
    /// Claude and Codex an id the host resolves to a file.
    var hasTranscript: Bool {
        guard let ref = agentSession, TranscriptFormat(agent: ref.agent) != nil else { return false }
        return ref.transcriptPath?.hasSuffix(".jsonl") == true || (ref.kind == "id" && !ref.value.isEmpty)
    }
}

/// `/Users/alex/src/app` or `/home/alex/src/app` as `~/src/app`: the host's home, not this device's.
func homeRelative(_ path: String) -> String {
    guard let match = path.firstMatch(of: /^\/(?:Users|home)\/[^\/]+/) else { return path }
    return "~" + path[match.range.upperBound...]
}

/// The message field and send button shared by the conversation and the terminal.
struct MessageComposer: View {
    @Environment(Settings.self) private var settings
    @Binding var draft: String
    @Binding var attachments: [DraftAttachment]
    var sending: Bool
    var focus: FocusState<Bool>.Binding
    var placeholder = "Message"
    let onSend: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                if let thumbnail = attachment.thumbnail {
                                    Image(uiImage: thumbnail).resizable().scaledToFill()
                                        .frame(width: 32, height: 32).clipped()
                                }
                                VStack(alignment: .leading) {
                                    Text(attachment.filename).lineLimit(1)
                                    Text(attachment.state).font(.caption2).foregroundStyle(.secondary)
                                }
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Remove \(attachment.filename)")
                            }
                            .font(.caption)
                            .padding(8)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        }
                    }
                }
            }
            GlassEffectContainer {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
                        Button("Files", systemImage: "folder") { showFiles = true }
                    } label: {
                        Image(systemName: "plus").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Attach")
                    ComposerTextView(text: $draft, focus: focus, placeholder: placeholder,
                                     autocorrect: settings.composerAutocorrect,
                                     returnKeySends: settings.returnKeySends) {
                        if !sending && !importing { onSend() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 22))
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .accessibilityLabel("Send")
                }
            }
        }
        .disabled(sending || importing)
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            importing = true
            Task {
                defer { photos = []; importing = false }
                for item in selection {
                    do {
                        guard attachments.count < 4 else { throw AttachmentError.tooMany }
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw AttachmentError.invalidImage
                        }
                        attachments.append(try DraftAttachment.prepare(data, filename: "Photo", imageRequired: true))
                    } catch { importError = error.localizedDescription }
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    guard attachments.count < 4 else { throw AttachmentError.tooMany }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    attachments.append(try DraftAttachment.prepare(Data(contentsOf: url, options: .mappedIfSafe), filename: url.lastPathComponent))
                }
            } catch { importError = error.localizedDescription }
        }
        .alert("Couldn't attach", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }
}
