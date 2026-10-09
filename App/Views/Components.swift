import HerdrAPI
import HerdwickSSH
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

    /// Filled silhouettes of a like weight, each its own shape: a question waiting, a check, a
    /// dotted ring (at work, still: a spinner in every row is motion for its own sake), asleep.
    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .working: "circle.dotted.circle.fill"
        case .idle: "moon.zzz.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

extension View {
    /// A small badge in the middle of a thread while its host reconnects, so a stale transcript
    /// doesn't pass for a live one. Brief blips never show it.
    func connectingBadge(_ connection: HostConnection) -> some View {
        overlay {
            Group {
                if connection.isConnecting, let status = connection.statusText {
                    Label { Text(status) } icon: { ProgressView().controlSize(.small) }
                        .font(.subheadline)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // Material, not glass: the transcript behind would read through it.
                        .background(.regularMaterial, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15).delay(connection.isConnecting ? 0.5 : 0), value: connection.isConnecting)
            .allowsHitTesting(false)
        }
    }
}

/// The host name over its address as one control. Tap opens the host list; swipe moves to the
/// neighbouring host, whose name peeks dimmed at each edge, like Weather's locations.
struct HostTitle: View {
    let title: String
    let subtitle: String
    var previous: String?
    var next: String?
    let open: () -> Void
    /// Nil when swiping is off (one host, or All Hosts).
    var switchHost: ((Int) -> Void)?

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stride: CGFloat = 170

    var body: some View {
        ZStack {
            if let previous { peek(previous, edge: .trailing).offset(x: drag - stride) }
            VStack(spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).minimumScaleFactor(0.8)
            }
            .lineLimit(1)
            .frame(width: stride - 12)
            .offset(x: drag)
            .opacity(1 - min(abs(drag) / stride, 1) * 0.6)
            if let next { peek(next, edge: .leading).offset(x: drag + stride) }
        }
        .frame(width: stride + 70, height: 44)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .gesture(swipe, including: switchHost == nil ? .none : .all)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityHint("Shows hosts and sessions")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment where next != nil: switchHost?(1)
            case .decrement where previous != nil: switchHost?(-1)
            default: break
            }
        }
    }

    /// A neighbour's name, aligned toward the centre so its nearest end shows.
    private func peek(_ name: String, edge: HorizontalAlignment) -> some View {
        Text(name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(edge == .trailing ? .head : .tail)
            .frame(width: stride - 12, alignment: Alignment(horizontal: edge, vertical: .center))
            .accessibilityHidden(true)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dx = value.translation.width
                // Rubber-band past the first and last host.
                drag = (dx < 0 ? next : previous) != nil ? dx : dx / 4
            }
            .onEnded { value in
                let dx = value.predictedEndTranslation.width
                let direction = dx < -stride / 2 ? 1 : dx > stride / 2 ? -1 : 0
                if direction != 0, (direction > 0 ? next : previous) != nil {
                    switchHost?(direction)
                    // The neighbour is now the title: keep it where the finger left it, then settle.
                    drag += CGFloat(direction) * stride
                }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { drag = 0 }
            }
    }
}

struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        // Still: the symbol says working; a spinning one in every row was motion for its own sake.
        Image(systemName: status.symbol)
            .foregroundStyle(status.tint)
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
    @State private var confirmingKey = false
    @State private var starting = false
    @State private var startError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Can't connect to \(connection.profile.name)", systemImage: "bolt.horizontal.circle")
                .font(.headline)
            Text(startError ?? failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // One row while every title fits on one line; otherwise full-width rows, never wrapped titles.
            ViewThatFits(in: .horizontal) {
                actions(stacked: false)
                actions(stacked: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 24))
        .confirmationDialog("Trust the new host key?", isPresented: $confirmingKey, titleVisibility: .visible) {
            Button("Trust New Key", role: .destructive) { connection.trustPresentedHostKey() }
        } message: {
            if let presented = connection.rejectedHostKey {
                Text("Pinned: \(pinnedFingerprint)\nPresented: \(presented.fingerprint)\n\nOnly trust it if you changed the server's key or reinstalled it.")
            }
        }
        .onChange(of: failure) { startError = nil }
    }

    private func actions(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        func title(_ text: String) -> some View {
            Text(text).lineLimit(1).frame(maxWidth: stacked ? .infinity : nil)
        }
        return GlassEffectContainer(spacing: 8) {
            layout {
                if failure.herdrStopped {
                    Button {
                        starting = true
                        Task {
                            startError = await connection.startHerdr()
                            starting = false
                        }
                    } label: {
                        if starting { ProgressView().frame(maxWidth: stacked ? .infinity : nil) } else { title("Start herdr") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(starting)
                    Button { connection.handle(.userRetry) } label: { title("Retry") }
                        .buttonStyle(.glass)
                } else {
                    Button { connection.handle(.userRetry) } label: { title("Retry") }
                        .buttonStyle(.glassProminent)
                }
                if connection.rejectedHostKey != nil {
                    Button { confirmingKey = true } label: { title("Trust New Key…") }
                        .buttonStyle(.glass)
                }
                if let onEdit {
                    Button(action: onEdit) { title("Edit Host") }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var pinnedFingerprint: String {
        Keychain.string(for: connection.profile.hostKeyAccount).flatMap(SSHKeys.fingerprint(ofPublicKeyLine:)) ?? "none (tailnet-advertised keys)"
    }
}

extension Agent {
    /// The conversation's name as a person would say it: the name given in herdr, else the
    /// terminal title past the glyph agents put before it ("π: Fix the build", "✳ Claude
    /// Code").
    var conversationTitle: String {
        if let label, !label.isEmpty { return label }
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
    @Environment(DictationController.self) private var dictation
    @Environment(\.openURL) private var openURL
    @Binding var draft: String
    @Binding var attachments: [DraftAttachment]
    var sending: Bool
    var focus: FocusState<Bool>.Binding
    var placeholder = "Message"
    /// Extra sends offered in the + menu (omp's "Send After This Run").
    var actions: [ComposerAction] = []
    /// Bumped to put the keyboard away (an ask card arriving); the field's own focus is UIKit's.
    var dismissals = 0
    /// The agent dock stands over the send button, as the mic does over +; a field taller
    /// than the pair carries both up to its top corners.
    var docksAgents = false
    /// The line over the field, beside the dock (the conversation's pinned Now line).
    var pinned: AnyView?
    /// Off line or without an agent: the field, attachments and send are off; the pinned line stays live.
    var locked = false
    /// Names the fallback speech model is told to expect, read when dictation starts.
    var vocabulary: () -> [String] = { [] }
    let onSend: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var importing = false
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?
    @State private var importID = UUID()
    @State private var previewing: ImagePreviewSource?
    @State private var dictationOwner = UUID()
    @State private var field = ComposerHandle()
    /// The dictionary as it stood when this dictation started: the preview and the draft agree.
    @State private var dictionary: (terms: [String], rules: [WordReplacement]) = ([], [])
    @ScaledMetric(relativeTo: .callout) private var transcriptHeight = 86.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card is up (opening, open or closing) and how far it has grown out of the mic.
    @State private var cardShown = false
    @State private var cardProgress: CGFloat = 0
    /// The field's height and the bar's, which place the mic and dock (and the card's stem).
    @State private var fieldHeight = AgentDock.size
    @State private var barHeight = AgentDock.size * 2 + 8

    private var busy: Bool { sending || importing }
    /// This composer's dictation is under way: nothing sends until its words are in the draft.
    private var dictating: Bool { dictation.owner == dictationOwner && dictation.state.blocksSending }

    var body: some View {
        // Listening, the card's stem stands in the bar where the mic was, running down to it
        // past the pinned line when the field is tall.
        VStack(alignment: .leading, spacing: -(AgentDock.size + micDrop)) {
            if cardShown { dictationCard.zIndex(1) }
            bar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
        // The card grows out of the mic on appearing; closing, it shrinks back in, still in the
        // layout so the thread settles with it, then goes. Reduce Motion just swaps them.
        .onChange(of: dictating) { _, now in
            if !now {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.24)) { cardProgress = 0 } completion: {
                    if !dictating { cardShown = false }
                }
            } else if cardShown {
                withAnimation(openCard) { cardProgress = 1 }
            } else {
                cardShown = true
            }
        }
        // The field stays enabled while sending: disabling it would drop the keyboard.
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 4, matching: .images)
        .sheet(item: $previewing) { ImagePreview(source: $0, loader: nil) }
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            importTask?.cancel()
            let id = UUID()
            importID = id
            importing = true
            importTask = Task {
                defer { if importID == id { photos = []; importing = false; importTask = nil } }
                for item in selection {
                    do {
                        try Task.checkCancellation()
                        guard attachments.count < 4 else { throw AttachmentError.tooMany }
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw AttachmentError.invalidImage
                        }
                        let attachment = try await DraftAttachment.prepareOffMain(data, filename: "Photo", imageRequired: true)
                        guard attachments.count < 4 else { throw AttachmentError.tooMany }
                        attachments.append(attachment)
                    } catch {
                        guard !Task.isCancelled else { return }
                        importError = error.localizedDescription
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importTask?.cancel()
            let id = UUID()
            importID = id
            importing = true
            importTask = Task {
                defer { if importID == id { importing = false; importTask = nil } }
                do {
                    for url in try result.get() {
                        try Task.checkCancellation()
                        guard attachments.count < 4 else { throw AttachmentError.tooMany }
                        let attachment = try await DraftAttachment.prepareFile(url)
                        guard attachments.count < 4 else { throw AttachmentError.tooMany }
                        attachments.append(attachment)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    importError = error.localizedDescription
                }
            }
        }
        .onDisappear {
            importID = UUID()
            importTask?.cancel()
            importTask = nil
            importing = false
            photos = []
            dictation.cancel(owner: dictationOwner)
        }
        .alert("Couldn't attach", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .alert("Dictation unavailable", isPresented: Binding(get: { dictationFailure != nil }, set: { if !$0 { dictation.clearError() } })) {
            if dictation.permissionDenied {
                Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(dictationFailure ?? "") }
    }

    /// The mic over +, the dock over send: a short field leaves them stacked on those buttons,
    /// a taller one carries them up to its top corners.
    private var sideHeight: CGFloat { max(AgentDock.size * 2 + 8, fieldHeight) }
    /// How far below the bar's top the mic stands (under the pinned line beside a tall field).
    private var micDrop: CGFloat { max(0, barHeight - sideHeight) }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Listening, the card's stem holds the mic's place.
            VStack(spacing: 0) {
                if cardShown {
                    Color.clear.frame(width: AgentDock.size, height: AgentDock.size)
                } else {
                    dictationButton
                }
                Spacer(minLength: 8)
                attachMenu
            }
            .frame(height: sideHeight)
            VStack(alignment: .leading, spacing: 8) {
                // A button tall, so it rides the mic's and the dock's center line.
                if let pinned { pinned.frame(maxWidth: .infinity, minHeight: AgentDock.size, alignment: .leading) }
                if !attachments.isEmpty { attachmentStrip.disabled(locked) }
                ComposerTextView(text: $draft, focus: focus, placeholder: placeholder,
                                 autocorrect: settings.composerAutocorrect,
                                 returnKeySends: settings.returnKeySends, dismissals: dismissals,
                                 sendsBlocked: dictating, onDictate: toggleDictation,
                                 onCancelDictation: { dictation.cancel(owner: dictationOwner) }, handle: field) {
                    if !busy && !dictating { onSend() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                // Not `.interactive()`: its touch handling takes taps from the + menu's
                // items where they overlap the field, all but their leading glyph.
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .disabled(locked)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            }
            // Outside any glass container: the dock's slot preference doesn't come out of one.
            VStack(spacing: 0) {
                if docksAgents { AgentDock.slot }
                Spacer(minLength: 8)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(locked || busy || dictating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .accessibilityLabel("Send")
            }
            .frame(height: sideHeight)
        }
    }

    private var dictationFailure: String? {
        guard dictation.owner == dictationOwner, case .failed(let message) = dictation.state else { return nil }
        return message
    }

    /// The mic, opened: one piece of glass, an L. Its stem is Stop, where the mic stood; its top
    /// runs across the bar with what's been heard (the model's open guess dimmed) and Cancel.
    /// The words reach the draft at Stop, rewritten by the dictionary as shown; with the live
    /// transcript off it is one status line. Nothing pulses: the words, or "Hearing you…", are
    /// the sign it hears you.
    @ViewBuilder private var dictationCard: some View {
        let recording = dictation.state == .recording
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                let words = cardWords.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                // Hugs the words up to about four lines; past that it scrolls, held at the newest.
                ScrollView { words }
                    .defaultScrollAnchor(.bottom)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: transcriptHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    // The first line on Cancel's center.
                    .padding(.vertical, 4)
                Button("Cancel Dictation", systemImage: "xmark.circle.fill") { dictation.cancel(owner: dictationOwner) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            Button(dictating ? "Stop Dictation" : "Dictate", systemImage: dictating ? "stop.fill" : "mic.fill", action: toggleDictation)
                .labelStyle(.iconOnly)
                .font(dictating ? .footnote : .callout)
                .foregroundStyle(recording ? Color.red : Color.secondary)
                .frame(width: AgentDock.size, height: AgentDock.size)
                .contentShape(.circle)
                .buttonStyle(.plain)
                // Outside `locked`, so a lost connection can't disable it.
                .disabled(!recording)
                .padding(.top, cardStem - AgentDock.size)
        }
        .modifier(DictationUnfold(progress: cardProgress, stem: cardStem))
        .onAppear { withAnimation(openCard) { cardProgress = 1 } }
    }

    /// The stem's length under the card: down to the mic, wherever it stands.
    private var cardStem: CGFloat { DictationShape.stem + micDrop }

    /// Out of the mic with no overshoot, already moving on its first frame (one from rest adds
    /// to the beat between the tap and the growth). Critically damped, so it never grows past
    /// full and back: with the keyboard going down under it, any bounce reads as a wobble.
    private var openCard: Animation? { reduceMotion ? nil : .interpolatingSpring(duration: 0.28, bounce: 0, initialVelocity: 4) }

    /// Closing, the card empties: its words are in the draft, or dropped.
    private var cardWords: Text {
        guard dictating else { return Text(verbatim: " ") }
        return (settings.showsLiveTranscript ? heard : nil) ?? Text(dictationStatus).foregroundStyle(.secondary)
    }

    private var heard: Text? {
        let finalized = Self.rewrite(dictation.finalizedText, with: dictionary)
        // The guess is rewritten too, so a term looks the same before and after it settles.
        let guess = Self.rewrite(dictation.volatileText, with: dictionary)
        guard !finalized.isEmpty || !guess.isEmpty else { return nil }
        return Text("\(finalized)\(Text(guess).foregroundStyle(.secondary))")
    }

    /// Shown until the first words, or throughout with the live transcript off.
    private var dictationStatus: String {
        switch dictation.state {
        case .preparing: dictation.downloading ? "Downloading speech model…" : "Preparing…"
        case .finishing: "Finishing…"
        default: dictation.finalizedText.isEmpty && dictation.volatileText.isEmpty ? "Listening…" : "Hearing you…"
        }
    }

    /// Tap to listen; it opens into the card, whose stem is Stop. It never sends. It puts the
    /// keyboard away for the room (a tap in the field brings it back); ⌘⇧D leaves it up.
    private var dictationButton: some View {
        Button {
            // A turn later, not inside the tap's action: resigned there, the keyboard's going
            // drops the bar to the screen's edge and springs it back.
            Task { @MainActor [field] in field.input?.resignFirstResponder() }
            toggleDictation()
        } label: {
            // Filled and a size down: the outline mic's strokes outweighed the +.
            Image(systemName: "mic.fill").font(.callout).frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        // One session app-wide.
        .disabled(locked || dictation.state.blocksSending)
        .accessibilityLabel("Dictate")
    }

    private func toggleDictation() {
        if dictating {
            if dictation.state == .recording { dictation.stop(owner: dictationOwner) }
        } else if !locked {
            let dictionary = (terms: settings.knownTerms, rules: settings.dictationReplacements)
            self.dictionary = dictionary
            dictation.start(owner: dictationOwner, terms: dictionary.terms, names: vocabulary()) { [field] in
                field.input?.insertDictation(Self.rewrite($0, with: dictionary))
            }
        }
    }

    /// Replacements first, on the words as heard (their left side is what the recognizer
    /// wrote), then known terms.
    private static func rewrite(_ text: String, with dictionary: (terms: [String], rules: [WordReplacement])) -> String {
        KnownTerms.apply(dictionary.terms, to: WordReplacement.apply(dictionary.rules, to: text))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        // The picture and name open the preview; Remove stays its own button.
                        Button {
                            previewing = .local(attachment.data, name: attachment.filename, id: attachment.id)
                        } label: {
                            HStack(spacing: 6) {
                                if let thumbnail = attachment.thumbnail {
                                    Image(uiImage: thumbnail).resizable().scaledToFill()
                                        .frame(width: 32, height: 32).clipped()
                                }
                                VStack(alignment: .leading) {
                                    Text(attachment.filename).lineLimit(1)
                                    Text(attachment.state).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(!attachment.isImage)
                        .accessibilityHint(attachment.isImage ? "Shows the image" : "")
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: { Image(systemName: "xmark") }
                        .disabled(busy)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("Files", systemImage: "folder") { showFiles = true }
            if !settings.snippets.isEmpty {
                Menu("Insert Snippet", systemImage: "text.badge.plus") {
                    ForEach(settings.snippets) { snippet in
                        Button(snippet.title) { insert(snippet.text) }
                    }
                }
            }
            ForEach(actions) { action in
                Button(action.title, systemImage: action.systemImage, action: action.perform)
                    .disabled(busy || dictating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } label: {
            Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(locked || busy)
        .accessibilityLabel("Attach")
    }

    /// Adds a snippet at the end of the draft on its own line; the draft is never sent here.
    private func insert(_ text: String) {
        draft = draft.isEmpty || draft.hasSuffix("\n") ? draft + text : draft + "\n" + text
        focus.wrappedValue = true
    }
}

struct ComposerAction: Identifiable {
    let title: String
    let systemImage: String
    let perform: () -> Void
    var id: String { title }
}

/// The dictation card's outline: a rounded card with a stem down its leading edge, as wide as the
/// mic and ending round like it, joined by a small inside curve. Below `progress` 1 it is the
/// part grown so far out of the mic, from the bottom leading corner: at 0, the mic's circle.
struct DictationShape: Shape {
    /// The stem's length under the card at the least: the gap over the bar, then the mic's place.
    static let stem = AgentDock.size + 8
    var progress: CGFloat = 1
    /// Its length here: longer when the mic stands lower in the bar.
    var stemLength = stem

    /// The height shown of a card `height` tall.
    static func grown(_ height: CGFloat, _ progress: CGFloat) -> CGFloat {
        AgentDock.size + (height - AgentDock.size) * progress
    }

    func path(in full: CGRect) -> Path {
        let stemWidth = AgentDock.size
        let height = Self.grown(full.height, progress)
        let rect = CGRect(x: full.minX, y: full.maxY - height,
                          width: stemWidth + (full.width - stemWidth) * min(progress, 1), height: height)
        let bottom = rect.maxY - stemLength
        guard bottom > rect.minY else { return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: stemWidth, height: height), cornerRadius: stemWidth / 2) }
        let radius = min(stemWidth / 2, (bottom - rect.minY) / 2, rect.width / 2)
        // Narrower than fully open, the corners give way rather than cross the stem.
        let inner = max(0, min(radius, rect.width - stemWidth))
        let fillet = max(0, min(8, rect.width - stemWidth - inner))
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: inner)
        path.addArc(tangent1End: CGPoint(x: rect.minX + stemWidth, y: bottom), tangent2End: CGPoint(x: rect.minX + stemWidth, y: rect.maxY), radius: fillet)
        path.addArc(tangent1End: CGPoint(x: rect.minX + stemWidth, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: stemWidth / 2)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: stemWidth / 2)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// The dictation card's glass, grown out of the mic as `progress` goes from 0 to 1, and back
/// in on close: it rises and widens from the stem, its words revealed rather than faded (faded
/// glass pops in late), and takes its room in the bar as it grows, so the thread above moves
/// with it rather than jumping first.
struct DictationUnfold: ViewModifier, Animatable {
    var progress: CGFloat
    var stem = DictationShape.stem

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let shape = DictationShape(progress: progress, stemLength: stem)
        // Its room starts at what the stem covers of the bar, so the bar doesn't shift as it comes.
        Grown(progress: progress, base: stem - DictationShape.stem + AgentDock.size) {
            content.clipShape(shape).contentShape(shape).glassEffect(.regular, in: shape)
        }
    }

    /// Takes the height grown so far; the card stands full size on its bottom edge.
    private struct Grown: Layout {
        var progress: CGFloat
        var base: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews.first?.sizeThatFits(proposal) ?? .zero
            return CGSize(width: size.width, height: base + (size.height - base) * progress)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let card = subviews.first else { return }
            let size = card.sizeThatFits(ProposedViewSize(width: bounds.width, height: proposal.height))
            card.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: size.height))
        }
    }
}
