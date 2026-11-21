import HerdrAPI
import HerdwickSSH
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Run state, not read state: a finished turn reads "Done" with a check whether or not it has
/// been read; unread is the dot, and the green, filled check (round 11: reading a result turned
/// it Idle with a moon, as if the agent's work had changed).
extension AgentStatus {
    var label: String {
        switch self {
        case .blocked: "Needs you"
        case .done, .idle: "Done"
        case .working: "Working"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: Tokens.Tint.attention
        case .done: Tokens.Tint.settled
        case .working: .blue
        case .idle: .secondary
        case .unknown: .gray
        }
    }

    /// Silhouettes, each its own shape: a question waiting, a check (filled until read), a
    /// dotted ring (at work; the inbox turns it slowly, still under Reduce Motion). Filled but
    /// for work and a read finish, whose outlines stay quieter than the one that wants the user
    /// (round 6: the filled blue disc out-shouted Needs You).
    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .working: "circle.dotted.circle"
        case .idle: "checkmark.circle"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// A working agent whose transcript has gone still ("no update 6m"), in grey: an hourglass,
    /// not the ring stopped, so it reads apart from live work without colour (round 33: the
    /// grey ring beside the blue one differed by colour alone).
    static let stillSymbol = "hourglass"

    /// The inbox's and the dock's group for it: unread results apart from read ones, so what
    /// waits to be read sits above the work in progress. Read results are "Read", the state they
    /// are in (round 12: "Earlier" read as a time range, and the Overview called them "Done").
    /// Titled as the inbox's header and capsule are (round 28: the Overview's "Needs you" beside
    /// the sidebar's "Needs You").
    var section: String {
        switch self {
        case .blocked: "Needs You"
        case .idle: "Read"
        default: label
        }
    }
}

extension View {
    /// Content scrolling under the bars fades into the page instead of showing through them as
    /// a second, dimmed layer of words. Replaces the system's scroll edge effect on that edge;
    /// off where the page isn't `color` (the iPad sidebar keeps the system's). `within`: open
    /// space at the inner end of the safe area (the inbox's room above its bottom bar), where
    /// the fade happens instead of past the inset, so no word fades where it could be read
    /// (round 24: the next row faded out in space above the controls). The reconnect pill's
    /// inset is solid like the bar's, fading just past it: faded through any of it, the row
    /// behind showed its ends either side of the glass (round 89: opus#3, sa#8).
    func edgeFade(_ edge: VerticalEdge, color: Color = Tokens.Surface.base, within: CGFloat = 0,
                  enabled: Bool = true) -> some View {
        let set: Edge.Set = edge == .top ? .top : .bottom
        return scrollEdgeEffectHidden(enabled, for: set)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if enabled {
                    // The reader stays in the safe area to measure the bar (inside an
                    // `ignoresSafeArea` view the insets read as zero); only the gradient
                    // reaches under it.
                    GeometryReader { proxy in
                        let inset = edge == .top ? proxy.safeAreaInsets.top : proxy.safeAreaInsets.bottom
                        // Short (round 16: lines resting in a 24 pt band read half-erased).
                        let height = within > 0 ? inset : inset + Tokens.Space.l
                        let solid = within > 0 ? max(inset - within, 0) : inset
                        // Solid under the bar itself, fading out just past it.
                        LinearGradient(stops: [.init(color: color, location: 0),
                                               .init(color: color, location: solid / max(height, 1)),
                                               .init(color: color.opacity(0), location: 1)],
                                       startPoint: edge == .top ? .top : .bottom,
                                       endPoint: edge == .top ? .bottom : .top)
                            .frame(height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
                            .ignoresSafeArea(edges: set)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }

    /// While the host reconnects, a status pill above the transcript, in the layout rather than
    /// over it, so a stale transcript stays readable and doesn't pass for a live one. Brief blips
    /// never show it. Between attempts it also offers to try now. `lastKnown`: the agent's status
    /// when the link went ("Done"), said with the time.
    func connectingBadge(_ connection: HostConnection, lastKnown: String? = nil) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ConnectingBadge(connection: connection, lastKnown: lastKnown)
        }
    }
}

/// A compact inline label whose symbol sits close to its wording (round 8: the default label
/// drew the scissors about twice the caption with a wide gap, so it read as a stray icon).
struct CaveatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension LabelStyle where Self == CaveatLabelStyle {
    static var caveat: CaveatLabelStyle { CaveatLabelStyle() }
}

/// The warning under a command read off the terminal screen: what Approve would authorize may
/// run past what was read. Primary words (round 76: sb#9) behind the caution triangle in the
/// caution yellow, the app's warning, not its grey metadata (round 81: sa#4, with the viewfinder
/// glyph it read as explanatory small print beside the mint Approve).
struct ScreenReadCaveat: View {
    var body: some View {
        Label {
            Text("Read from the screen; may be incomplete")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Tint.caution)
        }
        .labelStyle(.caveat)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
    }
}

private struct ConnectingBadge: View {
    let connection: HostConnection
    let lastKnown: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if connection.isConnecting, let status = connection.statusText {
                HStack(spacing: 10) {
                    Label {
                        // What's on screen is as of the link going (round 7: a reconnecting
                        // transcript didn't say how old it was), with the agent's status then
                        // (round 43: sa#4, sb#4, opus#5, in the thread's subtitle it cut the
                        // workspace to "web-das…").
                        VStack(alignment: .leading, spacing: 0) {
                            Text(status).monospacedDigit()
                            if let lostAt = connection.lostAt {
                                // As the transcript dates its times (round 95: sb#2, a link lost
                                // yesterday said "synced 11:29 PM" as if today).
                                let time = lostAt.transcriptStamp
                                // "synced": the time of the last word from the host, not of the
                                // status (round 44: sb#14, opus#2, "Done at 1:14 AM" over a result
                                // done at 12:29 read as its finish).
                                Text(lastKnown.map { "Last known: \($0) · synced \(time)" } ?? "Last updated \(time)")
                                    .font(.caption)
                            } else if let lastKnown {
                                Text("Last known: \(lastKnown)").font(.caption)
                            }
                        }
                    } icon: { ProgressView().controlSize(.small) }
                        .foregroundStyle(Tokens.secondaryText)
                        .accessibilityElement(children: .combine)
                    if case .waiting = connection.phase {
                        Button("Retry Now") { connection.handle(.userRetry) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                            // The pill stays slim; the button answers taps across 44 pt.
                            .contentShape(Rectangle().inset(by: -14))
                    }
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: .capsule)
                .padding(.vertical, Tokens.Space.s)
                .frame(maxWidth: .infinity)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25).delay(connection.isConnecting ? 0.5 : 0), value: connection.isConnecting)
    }
}

/// The phone's inbox title: "Inbox" over the host it shows. Tap opens host management.
struct HostTitle: View {
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                VStack(spacing: 1) {
                    Text("Inbox").font(.headline)
                    Text(title).font(.caption).foregroundStyle(.secondary).minimumScaleFactor(0.8)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140, maxWidth: 220, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inbox, \(title)")
        .accessibilityHint("Shows hosts and sessions")
    }
}

/// A pushed screen's title and status, always at the leading edge after Back. The system's
/// inline title centres when it fits and moves to the leading edge when it doesn't, so a
/// status change ("Needs you" → "Idle") made the title jump across the bar; a principal item
/// still centred whenever the bar's items left it room (the terminal, every iPad detail).
/// A leading item without the shared glass sits right after Back on both. The bar proposes a
/// leading item almost no width, so the title takes its own and truncates only past `room`
/// (what the bar leaves between Back and the trailing items).
/// `since`: when the state the subtitle leads with began ("Working for 4m · studio"), counted
/// on the minute. `waiting`: that state is a wait on the user, said as the inbox row says it
/// ("Waiting 3m · web-dashboard", from the same formatter and clock minutes; round 20: "Needs
/// you for 3m" cut the workspace to "web-dash…" and counted minutes apart from the inbox's
/// "waiting 4m"). `tint`: that state's colour, for its word only (round 8: an untinted status
/// was the faintest thing on the screen, where the inbox, dock and Panes tint it). `still`: when
/// a working agent's transcript last moved; once five clock minutes old the subtitle says "no
/// update 6m" after the status, which goes grey, counted on the minute as the sidebar counts it
/// (round 92: sb#1, worked out once on opening, the terminal said 6m beside the sidebar's 7m).
/// The subtitle at footnote with a medium-weight status word (round 36: the status a supervisor
/// checked was smaller than the body).
struct BarTitle: ToolbarContent {
    let title: String
    let subtitle: String
    let room: CGFloat
    var since: Date? = nil
    var still: Date? = nil
    /// The quiet takes the place of what follows the status (the terminal's directory) rather
    /// than going before it (round 32: with both, the subtitle pushed Type and Read off the bar).
    var stillReplacesPlace = false
    var waiting = false
    var tint: Color? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            CappedWidth(cap: room) {
                // The system's own sizes for an inline title, smaller over a subtitle; headline
                // over subheadline cut titles the system title had fitted.
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(subtitle.isEmpty ? .headline : .subheadline.weight(.semibold))
                    if !subtitle.isEmpty {
                        Group {
                            if since != nil || still != nil {
                                TimelineView(.everyMinute) { context in
                                    let quiet = still.flatMap { AgentRow.quiet(since: $0, at: context.date) }
                                    styled(Self.subtitle(subtitle, since: since, quiet: quiet, replacingPlace: stillReplacesPlace,
                                                         waiting: waiting, now: context.date),
                                           tint: quiet == nil ? tint : Tokens.secondaryText)
                                }
                            } else {
                                styled(subtitle, tint: tint)
                            }
                        }
                        .font(.footnote).foregroundStyle(Tokens.secondaryText)
                        .contentTransition(.opacity)
                    }
                }
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The bar holds its words near the standard size at accessibility sizes, as the
            // system's bars do; a long press shows them enlarged, as theirs (round 95: sb#3, the
            // recipient read smaller than the message being written to it).
            .accessibilityShowsLargeContentViewer()
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func styled(_ text: String, tint: Color?) -> Text {
        let spoken = Self.spoken(text)
        guard let split = text.range(of: " · ") else {
            return Text(text).fontWeight(.medium).foregroundStyle(tint ?? Tokens.secondaryText).accessibilityLabel(spoken)
        }
        let status = Text(text[..<split.lowerBound]).fontWeight(.medium).foregroundStyle(tint ?? Tokens.secondaryText)
        return (status + Text(String(text[split.lowerBound...]))).accessibilityLabel(spoken)
    }

    /// The subtitle in words, its compact ages spelled out, "Waiting 3 minutes", "Working for 1
    /// hour 5 minutes", "no update 6 minutes" (round 50: sb#4: VoiceOver read "3m" as three
    /// metres, where every row already speaks its age), and the dots as pauses.
    static func spoken(_ text: String) -> String {
        func unit(_ count: Substring, _ name: String) -> String { "\(count) \(name)\(count == "1" ? "" : "s")" }
        return text
            .replacing(/\b(\d+)h\b/) { unit($0.output.1, "hour") }
            .replacing(/\b(\d+)m\b/) { unit($0.output.1, "minute") }
            .replacing(/\b(\d+)d\b/) { unit($0.output.1, "day") }
            .replacingOccurrences(of: " · ", with: ", ")
    }

    /// "for 4m" after the subtitle's first part, once there's a whole clock minute of it
    /// (round 18: "Working · 1m" read as an age beside the inbox's), or in its place the quiet,
    /// "Working · no update 6m"; a wait becomes the inbox row's own words, capitalised
    /// ("Waiting 3m", "Waiting since Tue").
    static func subtitle(_ subtitle: String, since: Date?, quiet: String? = nil, replacingPlace: Bool = false,
                         waiting: Bool = false, now: Date) -> String {
        var parts = subtitle.components(separatedBy: " · ")
        if let quiet {
            parts.replaceSubrange(1..<(replacingPlace ? parts.count : 1), with: [quiet])
            return parts.joined(separator: " · ")
        }
        func minute(_ date: Date) -> Double { (date.timeIntervalSinceReferenceDate / 60).rounded(.down) }
        guard let since else { return subtitle }
        let minutes = Int(max(0, minute(now) - minute(since)))
        guard minutes >= 1 else { return subtitle }
        if waiting {
            let words = AgentRow.waiting(since: since, at: now)
            parts[0] = words.prefix(1).uppercased() + words.dropFirst()
        } else {
            parts[0] += " for " + (minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m")
        }
        return parts.joined(separator: " · ")
    }
}

/// Lays its content out at its ideal width, at most `cap`, whatever width it's offered.
private struct CappedWidth: Layout {
    let cap: CGFloat

    private func proposal(_ subview: LayoutSubview) -> ProposedViewSize {
        ProposedViewSize(width: min(subview.sizeThatFits(.unspecified).width, max(cap, 0)), height: nil)
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(proposal(subview))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, proposal: proposal(subview))
    }
}

/// Its subviews in rows, left to right, wrapping as words do.
struct Flow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func arrange(_ width: CGFloat?, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        let limit = width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > limit {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (points, CGSize(width: widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}


struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.raised, in: .rect(cornerRadius: Tokens.Radius.card))
        .alert("Trust the new host key?", isPresented: $confirmingKey) {
            Button("Trust New Key", role: .destructive) { connection.trustPresentedHostKey() }
            Button("Cancel", role: .cancel) {}
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
                    .primaryAction()
                    .controlSize(.large)
                    .disabled(starting)
                    Button { connection.handle(.userRetry) } label: { title("Retry") }
                        .floatingControl()
                        .controlSize(.large)
                } else {
                    Button { connection.handle(.userRetry) } label: { title("Retry") }
                        .primaryAction()
                        .controlSize(.large)
                }
                if connection.rejectedHostKey != nil {
                    Button { confirmingKey = true } label: { title("Trust New Key…") }
                        .floatingControl()
                        .controlSize(.large)
                }
                if let onEdit {
                    Button(action: onEdit) { title("Edit Host") }
                        .floatingControl()
                        .controlSize(.large)
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
    /// Code"). A name Herdwick made up to start the agent ("omp-e03b45") ranks below the
    /// terminal title: it names nothing (round 20: a new thread was titled "omp-e03b45").
    var conversationTitle: String {
        if let label, !label.isEmpty { return label }
        if hasGeneratedName, let terminalTitle, let own = Self.stripped(terminalTitle),
           own != agent, own != displayAgent { return own }
        return Self.stripped(title) ?? title
    }

    /// `name` is one `HostConnection.startAgent` generated: the kind, "-", six hex digits.
    var hasGeneratedName: Bool {
        guard let name, let agent else { return false }
        let suffix = name.dropFirst(agent.count + 1)
        return name.hasPrefix(agent + "-") && suffix.count == 6 && suffix.allSatisfy(\.isHexDigit)
    }

    private static func stripped(_ title: String) -> String? {
        var text = Substring(title)
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 2 {
            text = text[text.index(after: colon)...]
        }
        text = text.drop { !$0.isLetter && !$0.isNumber }
        return text.isEmpty ? nil : String(text)
    }

    /// Whether the agent's own transcript can be shown as a conversation: omp reports a path,
    /// Claude, Codex and agy an id the host resolves to a file.
    var hasTranscript: Bool {
        guard let ref = agentSession, TranscriptFormat(agent: ref.agent) != nil else { return false }
        return ref.transcriptPath?.hasSuffix(".jsonl") == true || (ref.kind == "id" && !ref.value.isEmpty)
    }

    /// agy (Neon) has a conversation only once its first prompt reaches the model: herdr's hook
    /// reports it then (PreInvocation), not at start. Until that, a Neon is a chat waiting for
    /// its first message, not a terminal.
    var awaitsFirstPrompt: Bool { agent == "agy" && agentSession == nil }

    /// Opens as a conversation rather than in the terminal.
    var opensAsConversation: Bool { hasTranscript || awaitsFirstPrompt }
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
    /// Who a send goes to (the conversation's title), for VoiceOver's field and Send (round 71:
    /// sb#6, switching among like-named agents, "Message" and "Send" didn't confirm whose).
    var recipient: String? = nil
    /// Extra sends offered in the + menu (omp's "Send After This Run").
    var actions: [ComposerAction] = []
    /// Bumped to put the keyboard away (an ask card arriving); the field's own focus is UIKit's.
    var dismissals = 0
    /// The agent dock stands over Send, as the mic does over +; a field taller than the pair
    /// carries both up to its top corners.
    var docksAgents = false
    /// The line over the field, between the mic and the dock (the conversation's pinned Now line).
    var pinned: AnyView?
    /// Without an agent: the field, attachments and send are off; the pinned line stays live.
    var locked = false
    /// The host is away: the field and dictation stay open for drafting (the draft is saved),
    /// but nothing sends or attaches until it's back.
    var offline = false
    /// Names the fallback speech model is told to expect, read when dictation starts.
    var vocabulary: () -> [String] = { [] }
    /// Just before the field takes focus, ahead of the keyboard (`ComposerTextView.onWillFocus`).
    var onWillFocus: () -> Void = {}
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The field's height, which places the mic and the dock.
    @State private var fieldHeight = AgentDock.size

    private var busy: Bool { sending || importing }
    /// This composer's dictation is under way: nothing sends until its words are in the draft.
    private var dictating: Bool { dictation.owner == dictationOwner && dictation.state.blocksSending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dictating { dictationCard }
            if dynamicTypeSize.isAccessibilitySize { accessibleBar } else { bar }
        }
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

    /// The mic over +, the dock over Send, so the field has the row's whole middle: beside a
    /// short field they stand two high (by the pinned line, or the room for it); a taller field
    /// carries the mic and the dock up to its top corners. `Space.s` between them every way, the
    /// gap the app's other glass buttons keep (the user: 4 pt read as cramped beside the rest).
    private var sideHeight: CGFloat { max(AgentDock.size * 2 + gap, fieldHeight) }
    private let gap = Tokens.Space.s

    private var bar: some View {
        HStack(alignment: .bottom, spacing: gap) {
            VStack(spacing: 0) {
                dictationButton
                Spacer(minLength: gap)
                attachMenu
            }
            .frame(height: sideHeight)
            VStack(alignment: .leading, spacing: gap) {
                // A button tall, so it rides the mic's and the dock's center line.
                if let pinned { pinned.frame(maxWidth: .infinity, minHeight: AgentDock.size, alignment: .leading) }
                else if offline, !draft.isEmpty { offlineNote.frame(maxWidth: .infinity, minHeight: AgentDock.size, alignment: .leading) }
                if !attachments.isEmpty { attachmentStrip.disabled(locked) }
                textField.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            }
            // Outside any glass container: the dock's slot preference doesn't come out of one.
            VStack(spacing: 0) {
                if docksAgents { AgentDock.slot }
                Spacer(minLength: gap)
                sendButton
            }
            .frame(height: sideHeight)
        }
    }

    /// At accessibility text sizes the field takes the full width, its buttons in a row under it.
    private var accessibleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pinned { pinned.frame(maxWidth: .infinity, minHeight: AgentDock.size, alignment: .leading) }
            else if offline, !draft.isEmpty { offlineNote }
            if !attachments.isEmpty { attachmentStrip.disabled(locked) }
            textField
            HStack(spacing: 8) {
                dictationButton
                attachMenu
                Spacer(minLength: 0)
                sendButton
                if docksAgents { AgentDock.slot }
            }
        }
    }

    /// Offline with a draft: it is kept, and why Send waits. An empty draft needs no note: the
    /// thread's reconnect pill says the link is down and the field says "Write a Draft" (round
    /// 38: "Offline · You can write a draft" under "Reconnecting in 4s" said it twice).
    private var offlineNote: some View {
        // "Tap Send", not "Send once": nothing goes on its own when the link is back (round 89:
        // sb#10, it read as a promise of automatic delivery).
        Label("Draft saved · Tap Send once reconnected", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            // Whole at accessibility sizes (round 88: sb#7, two lines could cut it there).
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
    }

    /// What the Send button and VoiceOver's Send action both wait on.
    private var canSend: Bool {
        !(locked || offline || busy || dictating)
            && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private var textField: some View {
        ComposerTextView(text: $draft, focus: focus, placeholder: placeholder,
                         spokenLabel: recipient.map { "\(placeholder) to \($0)" },
                         autocorrect: settings.composerAutocorrect,
                         returnKeySends: settings.returnKeySends, dismissals: dismissals,
                         sendsBlocked: dictating, canSend: canSend, onDictate: toggleDictation,
                         onCancelDictation: { dictation.cancel(owner: dictationOwner) }, handle: field,
                         onWillFocus: onWillFocus) {
            if !busy && !dictating && !offline { onSend() }
        }
        .disabled(locked)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // A rounded rect, not a capsule: a capsule's ends swell with each line and run the text
        // and the caret off the glass. Not `.interactive()`: its touch handling takes taps from
        // the + menu's items.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
                // The glass style pads a 30-pt label to the row's 44 pt.
                .frame(width: 30, height: 30)
        }
        .primaryAction(.circle)
        .disabled(!canSend)
        .accessibilityLabel(recipient.map { "Send to \($0)" } ?? "Send")
        // The composer's controls keep their size at accessibility sizes; a long press shows them
        // large, as the system's bars do (round 84: opus#8).
        .accessibilityShowsLargeContentViewer()
    }

    private var dictationFailure: String? {
        guard dictation.owner == dictationOwner, case .failed(let message) = dictation.state else { return nil }
        return message
    }

    /// Dictation is a preview above the composer row, never a second send surface.
    private var dictationCard: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                cardWords.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: transcriptHeight)
            .fixedSize(horizontal: false, vertical: true)
            Button("Cancel Dictation", systemImage: "xmark.circle.fill") {
                dictation.cancel(owner: dictationOwner)
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .frame(width: Tokens.minTap, height: Tokens.minTap)
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }
    /// The live dictation preview, or a brief status until words arrive.
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

    /// Over +; dictating, it is Stop (still live when the connection is lost). It never sends,
    /// and it puts the keyboard away for the card (a tap in the field brings it back).
    private var dictationButton: some View {
        Button {
            if !dictating {
                Task { @MainActor [field] in field.input?.resignFirstResponder() }
            }
            toggleDictation()
        } label: {
            // Filled and a size down: the outline mic's strokes outweighed the +. The glyph is
            // footnote, quieter than Send's (round 14: equally assertive circles), on the same
            // 44 pt circle, so the target stays whole.
            Image(systemName: dictating ? "stop.fill" : "mic.fill")
                .font(.footnote)
                .frame(width: 30, height: 30)
        }
        .floatingControl(.circle)
        // Red while it hears you; otherwise the + menu's look.
        .tint(dictating && dictation.state == .recording ? .red : nil)
        .disabled(dictating ? dictation.state != .recording : locked || dictation.state.blocksSending)
        .accessibilityLabel(dictating ? "Stop Dictation" : "Dictate")
        .accessibilityShowsLargeContentViewer()
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
            Image(systemName: "plus").font(.footnote.weight(.medium)).frame(width: 30, height: 30)
        }
        .floatingControl(.circle)
        .disabled(locked || offline || busy)
        .accessibilityLabel("Attach")
        .accessibilityShowsLargeContentViewer()
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

