import HerdrAPI
import SwiftUI
import TipKit

/// The way to the next agent from inside a thread: a glass button that stands on the
/// composer's send button (or ends the terminal's keys row while typing) and opens a native
/// sheet of the other agents, zooming out of the button (a popover on iPad). The bar reserves
/// the button's place (`AgentDock.slot`); the dock's own layer (`agentDock`) draws it there.
/// By default what needs attention leads (needs you, then unread finishes, the longest waiting
/// first), then working, then idle agents. The sheet's order holds while it is open, so a row
/// never moves under a thumb. Picking a row replaces the open thread. A hold opens the quick
/// switch instead: a native menu of only the active agents, the most urgent nearest the button.
struct AgentDock: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var glass
    let current: PaneAddress
    /// A send in flight owns this conversation's composer and attachments; switching waits for it.
    let busy: Bool
    /// The place the bar keeps for the button.
    let slot: Anchor<CGRect>
    /// The thread's Next line is offering the next agent and its count: the badge would repeat it.
    var quiet = false

    /// The composer's round buttons are this size; the dock matches them.
    nonisolated static let size: CGFloat = 44

    /// Where the button stands; the bar that holds it reserves the room.
    struct Slot: PreferenceKey {
        static var defaultValue: Anchor<CGRect>? { nil }
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }

    /// The button's room in a bar.
    static var slot: some View {
        Color.clear
            .frame(width: size, height: size)
            .anchorPreference(key: Slot.self, value: .bounds) { $0 }
            .accessibilityHidden(true)
    }

    @State private var isOpen = false
    /// Each section's rows, in order, from when the sheet opened.
    @State private var held: [HeldLane]?
    /// The sheet's height as it opens (`setOpen`).
    @State private var detent: PresentationDetent = .medium
    /// The lanes' own height, measured as the sheet shows them (`fitted`).
    @State private var fit: CGFloat?
    /// Bumped as another agent starts waiting: the sheep's hop.
    @State private var lookUps = 0

    struct Lane: Identifiable {
        let id: String
        let title: String
        let threads: [Thread]
    }

    /// What the sheep's hop watches: who waits, under one thread.
    private struct WaitWatch: Equatable {
        let current: PaneAddress
        let waiting: Set<PaneAddress>
    }

    struct HeldLane {
        let id: String
        let title: String
        let addresses: [PaneAddress]
    }

    var body: some View {
        let sections = arranged
        let others = sections.flatMap(\.threads)
        // The same shown-status set drives the badge and the sheep.
        let waiting = others.count(where: scene.needsUser)
        let lead: AgentStatus? = waiting > 0 ? .blocked : nil
        // Every waiter on a host that's out of reach: the count is the last known one, said in
        // grey, as the thread says "Last known" (round 82: sb#3, a live orange 1 sat over an
        // offline thread).
        let stale = waiting > 0 && others.filter(scene.needsUser).allSatisfy { !$0.connection.isLive }
        // No "?" mood here: the count badge already says someone waits (round 23: a count and
        // a "?" on the 28 pt sheep said it twice, a fussy cluster). Every other agent read and
        // at rest, it dozes, the grey moon on its corner (round 80: opus#2, it looked the same
        // whatever the herd was doing).
        let statuses = others.map(scene.shownStatus)
        let mood: HerdMark.Mood = statuses.contains(.working) ? .working
            : !statuses.isEmpty && statuses.allSatisfy({ $0 == .idle }) ? .quiet : .idle
        GeometryReader { proxy in
            let place = proxy[slot]
            if !others.isEmpty || isOpen {
                button(waiting: waiting, stale: stale, mood: mood, sections: sections, next: Self.firstNeedsYou(in: others, scene: scene))
                    .overlay(alignment: .bottomTrailing) { badge(waiting: waiting, lead: stale ? nil : lead) }
                    // The sheep looks up when another agent starts waiting: one small hop, its
                    // badge with it, the inbox's all-clear hop at the dock's scale (round 78:
                    // opus#5, nothing reacted as the badge changed). Not under Reduce Motion.
                    .keyframeAnimator(initialValue: 0.0, trigger: lookUps) { view, lift in
                        view.offset(y: lift)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(-7, duration: 0.14)
                            SpringKeyframe(0, duration: 0.32, spring: .bouncy)
                        }
                    }
                    .padding(.trailing, max(0, proxy.size.width - place.maxX))
                    .padding(.bottom, max(0, proxy.size.height - place.maxY))
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
            }
        }
        .sensoryFeedback(.selection, trigger: isOpen) { _, _ in settings.haptics }
        // A swipe down, Escape or a pick closes it; the next opening takes a fresh order.
        .onChange(of: isOpen) { _, open in
            if !open { held = nil }
        }
        // Not as the thread changes: the one left behind joining isn't news. Who, not how many:
        // one answered as another asks is still news (round 80: sb#2). VoiceOver hears it too,
        // without focus moving, the sheet open or not (round 79: sb#2; round 80: sb#1).
        .onChange(of: WaitWatch(current: current, waiting: Set(others.filter(scene.needsUser).map(\.address)))) { old, new in
            guard new.current == old.current, !new.waiting.isSubset(of: old.waiting) else { return }
            if !reduceMotion, !isOpen { lookUps += 1 }
            // By name, where it runs and how many in all, so a VoiceOver user knows who without
            // opening the sheet (round 81: sb#3, "another agent" said nothing of which).
            let arrived = others.filter { new.waiting.contains($0.address) && !old.waiting.contains($0.address) }
            AccessibilityNotification.Announcement(arrival(arrived, waiting: new.waiting.count)).post()
        }
        // A thread new while the sheet is open keeps the place it first took, through whatever it
        // does next (round 81: sb#2, it re-sorted on its next status change).
        .onChange(of: model.dockThreads(in: scene).map(\.address)) { _, _ in admit() }
        // Every thread opened counts toward the sheep's first-use hint (`AgentsTip`).
        .task(id: current) { await AgentsTip.opened(current) }
    }

    // MARK: Pieces

    /// Tap opens the sheet; a hold opens the quick switch, a native menu of what's active.
    /// The sheet is the system's, with its detents, grabber, swipe and Escape (round 45: sa#2,
    /// sb#7, opus#3, the hand-drawn glass panel over a frosted thread wasn't one): on a phone it
    /// zooms out of the button, on iPad a popover points at it.
    private func button(waiting: Int, stale: Bool, mood: HerdMark.Mood, sections: [Lane], next: Thread?) -> some View {
        QuickSwitch(items: isOpen ? [] : quickItems, summary: summary(waiting: waiting) + (stale ? ", last known" : ""),
                    next: next.map { thread in
                        // Where too, as the dock's rows say it (round 51: sb#1, like-named agents).
                        let host = settings.allHosts && model.demo == nil ? thread.connection.profile.name : nil
                        return .init(address: thread.address, title: Self.accessibilityTitle(
                            title: thread.agent.conversationTitle, host: host, workspace: thread.workspace?.displayLabel))
                    },
                    mood: mood, toggle: { setOpen(true) }, pick: quickSelect)
            .equatable()
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityShowsLargeContentViewer()
            .matchedTransitionSource(id: "agents", in: glass)
            // Once, after a second thread has opened, until the dock is first used: what the sheep is for
            // (round 46: sa#2, sb#10, opus#5, nothing on screen said it opened other agents).
            .popoverTip(AgentsTip(), arrowEdge: .bottom)
            .tipBackground(Tokens.Surface.raised)
            .disabled(busy)
            .sheet(isPresented: presented(width != .regular)) {
                panel(sections).navigationTransition(.zoom(sourceID: "agents", in: glass))
            }
            .popover(isPresented: presented(width == .regular), arrowEdge: .bottom) {
                panel(sections).frame(idealWidth: 400, idealHeight: 560)
            }
    }

    /// The sheet's state under one size class, so the other's presentation never shows.
    private func presented(_ applies: Bool) -> Binding<Bool> {
        Binding { applies && isOpen } set: { setOpen($0) }
    }

    /// The sheet: the other agents under an inline title, the close button where iOS puts it.
    private func panel(_ sections: [Lane]) -> some View {
        NavigationStack {
            // Ages tick on the minute while it is open, as the inbox's do (round 45: sb#13).
            ScrollView {
                TimelineView(.everyMinute) { _ in stack(sections) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit = $0 }
            }
                // Every agent but this thread's (round 33: "Agents" over "Read 2" beside the
                // inbox's "Read 3" didn't say so). No tally beside it: the Needs You lane's
                // count says it (round 35).
                .navigationTitle("Other Agents")
                .navigationBarTitleDisplayMode(.inline)
                // Closed from the top trailing corner, as Panes and Settings are (round 81:
                // opus#8, three sheets put their close in three places).
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { setOpen(false) }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        // As tall as its rows, up to full height, so it neither opens ending inside a row nor
        // with a third of it blank (round 79: opus#2, sa#6, sb#5, a row-count rule did both);
        // full height at accessibility sizes (round 77: sb#6).
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [fitted, .large], selection: $detent)
        .onChange(of: fit) {
            if isOpen, !typeSize.isAccessibilitySize, detent != .large { detent = fitted }
        }
        .presentationDragIndicator(.visible)
        // Frosted thick rather than the half-height sheet's clear glass, so the thread's words
        // don't ghost through the names being scanned (round 73: sa#5).
        .presentationBackground(.thickMaterial)
    }

    /// How many want the user, on the button's corner.
    @ViewBuilder
    private func badge(waiting: Int, lead: AgentStatus?) -> some View {
        if !isOpen, !quiet, waiting > 0 {
            Text(waiting, format: .number)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                // Dark ink on the orange (round 75: sb#2, white on orange was the least legible
                // count on screen).
                .foregroundStyle(lead == .blocked ? Color.black : Color.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(lead?.tint ?? Color(.systemGray), in: .capsule)
                .frame(width: Self.size, height: Self.size, alignment: .topTrailing)
                .offset(x: 3, y: -3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func stack(_ sections: [Lane]) -> some View {
        // The first waiting row anywhere: a lane added while open may hold it (round 81: sb#9).
        let lead = sections.lazy.flatMap(\.threads).first(where: scene.needsUser)?.address
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    // With its count, as the inbox's headers have it (round 31), in the title's
                    // own grey (round 32: tertiary on the glass nearly vanished), the still ones
                    // among the working said as the inbox and Overview say them (round 76: sb#5).
                    Text(header(section))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.secondaryText)
                        .padding(.horizontal, 12)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.threads) { thread in
                        row(thread, leads: thread.address == lead, lane: section.id)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// "Needs You 0 (1 now working)": the rows under it still in the lane, then those held
    /// there after they left, by where they are now, so the header accounts for every row
    /// beneath it and no other (round 81: sb#1, it counted rows that had left; round 82: sb#2,
    /// a live total dropped rows whose new lane wasn't open; round 83: sa#5, sb#1, a live total
    /// described rows held elsewhere).
    private func header(_ section: Lane) -> String {
        let statuses = section.threads.map { ($0, scene.shownStatus($0)) }
        let kept = statuses.filter { Self.lane(of: $0.1) == section.id }
        let still = kept.count { $0.1 == .working && $0.0.connection.quiet($0.0.agent) != nil }
        var notes = still > 0 ? ["\(still) no update"] : []
        var left: [(AgentStatus, Int)] = []
        for (_, status) in statuses where Self.lane(of: status) != section.id {
            if let i = left.firstIndex(where: { $0.0 == status }) { left[i].1 += 1 } else { left.append((status, 1)) }
        }
        notes += left.map { "\($0.1) now \($0.0.label.lowercased())" }
        return "\(section.title) \(kept.count)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
    }

    /// One agent: its state, title and newest line. The first thing that wants the user is
    /// set apart so the next move reads at a glance. Held under a lane it has since left (the
    /// stack keeps its order while open), it says where it is now (round 7: a row stayed under
    /// Needs You after it went back to work).
    private func row(_ thread: Thread, leads: Bool, lane: String) -> some View {
        let status = scene.shownStatus(thread)
        // What it asks when it waits on the user, else its newest line; where it runs sits by the
        // title. A read result keeps one line of its verdict, as its inbox row does (round 25: the
        // dock's Read rows couldn't tell a pass from a failure), and a working one its step.
        let preview = thread.connection.rowLine(thread.agent, status: status, previews: settings.inboxPreviews)
        // A read result has one line: its verdict, without the first word of a bullet (round 28);
        // an unread one, two: its verdict over its first point (round 29: " · Move: …").
        let wait = status == .blocked ? thread.connection.wait(thread.agent) : nil
        // A question, not an approval (whose "Allow bash?" leads less well than its title).
        let asks = wait?.console != nil || wait?.prompt?.subject == nil ? wait?.summary : nil
        let detail = wait?.summary
            ?? (status == .idle ? preview.map(TranscriptActivity.verdict)
                : status == .done ? preview.map(TranscriptActivity.itemLines) : preview)
        // A finished result's closing warning, in place of its verdict, which is still spoken
        // (round 42: sb#2, the dock read safer than the inbox; round 43: sa#7, sb#2, a triangle
        // before the verdict didn't say what to do).
        let caution = thread.connection.caution(thread.agent, status: status, previews: settings.inboxPreviews)
        let host = settings.allHosts && model.demo == nil ? thread.connection.profile.name : nil
        let workspace = thread.workspace?.displayLabel
        let moved = Self.lane(of: status) != lane
        // A working agent gone still says so, as its inbox row does (round 20).
        let quiet = status == .working ? thread.connection.stillSince(thread.agent).flatMap { AgentRow.quiet(since: $0, at: .now) } : nil
        return Button { select(thread) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Mail's unread dot before the glyph, in the row's own leading inset, as the
                // inbox draws it (round 46: opus#10, the sheet's rows said unread by weight only),
                // a clear gap from the glyph (round 48: sa#12, two points read as one badge).
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(Tokens.Tint.unread)
                        .frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        .opacity(thread.connection.isUnread(thread.agent) ? 1 : 0)
                        .accessibilityHidden(true)
                    Image(systemName: quiet != nil ? AgentStatus.stillSymbol : status.symbol)
                        // Grey hourglass once gone still, as the inbox's (rounds 30, 33).
                        .foregroundStyle(quiet != nil ? Tokens.secondaryText : status.tint)
                        .font(leads ? .body : .subheadline)
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace, options: .speed(2)))
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // At work, how long for, as the inbox row's trailing "for 12m" (round 44).
                    let age = thread.connection.ageDate(thread.agent, status: status).map {
                        status == .blocked ? AgentRow.waiting(since: $0, at: .now) : AgentRow.ago(of: $0, at: .now)
                    } ?? quiet ?? thread.connection.workingSince(thread.agent, status: status).flatMap { AgentRow.working(since: $0, at: .now) }
                    // The age trails the first line, as in the inbox, short of accessibility
                    // sizes (round 72: opus#5, sa#3, sb#14, at the end of the place it wrapped
                    // to "waiting 5m" alone on a line); "no update 6m" stays in the place line,
                    // where the inbox keeps it (round 23: in the age slot it read as an age).
                    let stillOnly = quiet != nil && age == quiet
                    let trailingAge = typeSize.isAccessibilitySize || stillOnly ? nil : age
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // A question leads its row, whose it is under it, as the phone inbox's
                        // Needs You row sets it (round 71: sa#4, opus#8, the switcher led with
                        // "Deploy to staging" and set the question it asked a size down, third).
                        // An approval keeps its title first, "Allow bash?" saying less than it.
                        Text(asks ?? thread.agent.conversationTitle)
                            .font(leads ? .headline.weight(.semibold) : .subheadline.weight(thread.connection.isUnread(thread.agent) ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            // Whole at accessibility sizes: the stack scrolls past its cap instead.
                            .lineLimit(typeSize.isAccessibilitySize ? nil : asks != nil ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let trailingAge {
                            Spacer(minLength: 0)
                            Text(trailingAge).font(.footnote).monospacedDigit()
                                .foregroundStyle(Tokens.secondaryText)
                                .fixedSize()
                        }
                    }
                    // One "·"-joined line, as the inbox writes it ("api · OMP"); separate
                    // caption2 pieces read as loose words (round 14 capture). Footnote, as the
                    // inbox's age (round 17: at caption size it read as fine print).
                    let place = ([asks == nil ? nil : thread.agent.conversationTitle, host, workspace]
                                 + [thread.agent.agent.map(agentKindLabel), trailingAge == nil ? age : nil])
                        .compactMap { $0 }.joined(separator: " · ")
                    if moved || !place.isEmpty {
                        placeLine(moved ? status : nil, place)
                            .font(.footnote)
                            .foregroundStyle(Tokens.secondaryText)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : asks != nil ? 2 : 1)
                            .truncationMode(.middle)
                    }
                    if let caution {
                        Text("\(Text(Image(systemName: "exclamationmark.triangle")).foregroundStyle(Tokens.Tint.caution)) \(AgentRow.cautionText(caution))")
                            .font(.footnote)
                            // As the inbox sets it: the lead in primary, the rest in the app's
                            // grey (round 59: sb#9, all at 75 % the thing to do sank in the glass).
                            .foregroundStyle(Tokens.secondaryText)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if asks == nil, let detail {
                        // What a live agent is doing now at full strength, as the inbox sets
                        // it (round 53: sb#3, at 75 % it read as one more line of metadata).
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.primary.opacity(status == .working && quiet == nil ? 1 : 0.75))
                            // Whole at accessibility sizes, where the stack scrolls (round 25: a
                            // working agent's command was cut to one line there); two lines once
                            // still, so "Last reported:" leaves room for the command (round 26),
                            // and for a read verdict (round 33: "Fixed. The test now runs on the
                            // fake cloc…" couldn't be judged from the stack).
                            .lineLimit(typeSize.isAccessibilitySize ? nil : leads ? 3 : status == .working && quiet == nil ? 1 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 12)
            .padding(.vertical, leads ? 10 : 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        // Read state toggles both ways here, so a slip is undone in the same menu. No Hide: a row
        // gone from this passing panel has no Undo, as the inbox's has (round 38: sa#7, sb#1).
        .contextMenu { rowActions(thread) }
        // VoiceOver hears only what applies (round 38: both read states on every row, one a no-op).
        .accessibilityActions { rowActions(thread) }
        // A question heard first, as it's shown (`asks`), then whose it is.
        .accessibilityLabel([asks, Self.accessibilityTitle(title: thread.agent.conversationTitle, host: host, workspace: workspace)].compactMap { $0 }.joined(separator: ", "))
        // Unread said, as the inbox's rows say it (round 27: the filled check alone carried it);
        // and a command that may have been cut says so, as the inbox's card does (round 28). The
        // caution before the verdict, as the quick switch speaks it (round 48: sb#4).
        .accessibilityValue(([thread.connection.isUnread(thread.agent) ? "Unread" : nil, status.label, caution.map(AgentRow.spokenCaution), asks == nil ? detail : nil,
                             status == .blocked && thread.connection.wait(thread.agent)?.prompt?.contextMayBeTruncated == true ? "Command read from the screen, may be incomplete" : nil,
                             thread.agent.agent.map(agentKindLabel),
                             thread.connection.spokenAge(thread.agent, status: status)]
            .compactMap { $0 }).joined(separator: ", "))
    }

    /// "Now working · studio", the status in its tint, when the row's lane no longer says it.
    private func placeLine(_ now: AgentStatus?, _ place: String) -> Text {
        guard let now else { return Text(place) }
        let word = Text("Now \(now.label.lowercased())").foregroundStyle(now.tint)
        return place.isEmpty ? word : Text("\(word) · \(place)")
    }

    /// The lane a status belongs in (`live`).
    private static func lane(of status: AgentStatus) -> String {
        switch status {
        case .blocked: "needs-you"
        case .done: "done"
        case .working: "working"
        case .idle, .unknown: "idle"
        }
    }

    /// A row's menu and VoiceOver actions alike: only the read state it can change to.
    @ViewBuilder private func rowActions(_ thread: Thread) -> some View {
        if thread.connection.isUnread(thread.agent) {
            Button("Mark as Read", systemImage: "envelope.open") { thread.connection.markSeen(thread.agent) }
        } else if thread.connection.presentedStatus(thread.agent) == .idle {
            Button("Mark as Unread", systemImage: "envelope.badge") { thread.connection.markUnread(thread.agent) }
        }
        Button("Open Terminal", systemImage: "apple.terminal") {
            isOpen = false
            scene.open(.terminal(thread.address))
        }
    }

    static func accessibilityTitle(title: String, host: String?, workspace: String?) -> String {
        ([title] + [host, workspace].compactMap { $0 }).joined(separator: ", ")
    }

    /// The hold menu: what wants the user (in the inbox's order), then what's working (the
    /// latest turn first). Results already read are left to the stack.
    private var quickItems: [QuickSwitch.Item] {
        let threads = model.dockThreads(in: scene).filter { $0.address != current }
        let attention = threads.filter { [.blocked, .done].contains(scene.shownStatus($0)) }
        let working = threads.filter { scene.shownStatus($0) == .working }
        let hosts = settings.allHosts && model.demo == nil
        let now = Date.now
        return (Self.byWait(attention) + Self.byLatest(working)).map { thread in
            let status = scene.shownStatus(thread)
            let blocked = status == .blocked
            // Where and how long, as the dock's rows say it (round 16: the hold menu had title
            // and status only, so like-named agents read alike), "no update 6m" for one gone
            // still, and the same said with Unread and the harness (round 31: the hold menu
            // showed less than the stack).
            let age = thread.connection.ageDate(thread.agent, status: status)
                .map { blocked ? AgentRow.waiting(since: $0, at: now) : AgentRow.ago(of: $0, at: now) }
                ?? thread.connection.quiet(thread.agent, now: now)
                // At work, for how long, as the stack's rows say it (round 45: sb#12).
                ?? thread.connection.workingSince(thread.agent, status: status).flatMap { AgentRow.working(since: $0, at: now) }
            let host = hosts ? thread.connection.profile.name : nil
            let harness = thread.agent.agent.map(agentKindLabel)
            // VoiceOver hears what the stack's row shows under the title: the question or the
            // verdict (round 32: the hold menu said where and when, not what), the result's
            // closing caution first, as the row shows it (round 46: sb#4, "No blocking findings"
            // without "apply 0042 first"). Not a working agent's step: it changes by the second,
            // and a menu rebuilt while open jumps.
            let verdict = status == .done ? thread.connection.rowLine(thread.agent, status: status, previews: settings.inboxPreviews).map(TranscriptActivity.verdict) : nil
            let caution = thread.connection.caution(thread.agent, status: status, previews: settings.inboxPreviews)
            let about = blocked ? thread.connection.wait(thread.agent)?.summary
                : [caution.map(AgentRow.spokenCaution), verdict].compactMap { $0 }.joined(separator: ", ").nonEmpty
            return QuickSwitch.Item(address: thread.address, title: thread.agent.conversationTitle,
                                    symbol: status == .working && thread.connection.quiet(thread.agent, now: now) != nil ? AgentStatus.stillSymbol : status.symbol,
                                    status: status.label, host: host,
                                    workspace: thread.workspace?.displayLabel, harness: harness,
                                    unread: thread.connection.isUnread(thread.agent),
                                    detail: [host, thread.workspace?.displayLabel, harness, age]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    spokenAge: thread.connection.spokenAge(thread.agent, status: status), about: about)
        }
    }

    // MARK: Order

    /// Sections in order, empty ones dropped, the open thread left out. While the stack is open
    /// the order it opened with holds: rows keep their section and place (status glyphs still
    /// update), rows that end drop out, and a thread new since it opened joins the end of its
    /// lane, a lane it alone fills after the rest (round 80: sb#1, an agent that started waiting
    /// while the sheet was open didn't show until the next opening), and keeps that place
    /// (`admit`) until the sheet closes.
    private var arranged: [Lane] {
        guard let held else { return live }
        let threads = model.dockThreads(in: scene).filter { $0.address != current }
        let byAddress = Dictionary(threads.map { ($0.address, $0) }) { first, _ in first }
        let shown = Set(held.flatMap(\.addresses))
        let newcomers = Dictionary(grouping: threads.filter { !shown.contains($0.address) }) { Self.lane(of: scene.shownStatus($0)) }
        let kept: [Lane] = held.compactMap { section in
            let threads = section.addresses.compactMap { byAddress[$0] } + (newcomers[section.id] ?? [])
            return threads.isEmpty ? nil : Lane(id: section.id, title: section.title, threads: threads)
        }
        let added = live.compactMap { lane -> Lane? in
            guard !held.contains(where: { $0.id == lane.id }), let threads = newcomers[lane.id] else { return nil }
            return Lane(id: lane.id, title: lane.title, threads: threads)
        }
        return kept + added
    }

    /// Holds the threads new since the sheet opened where `arranged` first showed them.
    private func admit() {
        guard var lanes = held else { return }
        let shown = Set(lanes.flatMap(\.addresses))
        let fresh = model.dockThreads(in: scene).filter { $0.address != current && !shown.contains($0.address) }
        guard !fresh.isEmpty else { return }
        let titles = Dictionary(live.map { ($0.id, $0.title) }) { first, _ in first }
        for thread in fresh {
            let id = Self.lane(of: scene.shownStatus(thread))
            if let i = lanes.firstIndex(where: { $0.id == id }) {
                lanes[i] = HeldLane(id: id, title: lanes[i].title, addresses: lanes[i].addresses + [thread.address])
            } else {
                lanes.append(HeldLane(id: id, title: titles[id] ?? id, addresses: [thread.address]))
            }
        }
        held = lanes
    }

    /// What VoiceOver hears as agents start waiting: who, where (on which computer, when the
    /// inbox spans several, as the rows say it; round 82: sb#6), and how many wait in all.
    private func arrival(_ threads: [Thread], waiting: Int) -> String {
        let besides = waiting > threads.count ? ", \(waiting) waiting besides this thread" : ""
        // Each named in full, several at once too (round 83: sb#7, a batch said titles alone).
        let names = threads.map { thread in
            let host = settings.allHosts && model.demo == nil ? " on \(thread.connection.profile.name)" : ""
            return thread.agent.conversationTitle + (thread.workspace.map { " in \($0.displayLabel)" } ?? "") + host
        }
        switch names.count {
        case 0: return "Another agent needs you\(besides)"
        case 1: return "\(names[0]) needs you\(besides)"
        default: return "\(names.count) agents need you: \(names.formatted(.list(type: .and)))\(besides)"
        }
    }

    private var live: [Lane] {
        let threads = model.dockThreads(in: scene).filter { $0.address != current }
        let groups = Dictionary(grouping: threads) { Self.lane(of: scene.shownStatus($0)) }
        // The inbox's words: "Needs You" for a question, the status's own name for the rest.
        return [
            Lane(id: "needs-you", title: "Needs You", threads: Self.byWait(groups["needs-you"] ?? [])),
            Lane(id: "done", title: "Done", threads: Self.byWait(groups["done"] ?? [])),
            Lane(id: "working", title: "Working", threads: Self.byLatest(groups["working"] ?? [])),
            Lane(id: "idle", title: AgentStatus.idle.section, threads: Self.byLatest(groups["idle"] ?? [])),
        ].filter { !$0.threads.isEmpty }
    }

    /// Needs you before unread finishes, in the inbox's order (`attentionPrecedes`).
    private static func byWait(_ threads: [Thread]) -> [Thread] {
        threads.sorted(by: attentionPrecedes)
    }
    /// The first thread still waiting on the user (`SceneState.needsUser`, so not one whose
    /// answer's receipt is showing) under the dock's Needs You ordering.
    static func firstNeedsYou(in threads: [Thread], scene: SceneState) -> Thread? {
        byWait(threads.filter(scene.needsUser)).first
    }

    /// Every agent in the stack's lane order (Needs You, Done, Working, Read), for stepping
    /// through them from the keyboard.
    static func keyboardOrder(_ threads: [Thread], scene: SceneState) -> [Thread] {
        let status = { (thread: Thread) in scene.shownStatus(thread) }
        return byWait(threads.filter { status($0) == .blocked })
            + byWait(threads.filter { status($0) == .done })
            + byLatest(threads.filter { status($0) == .working })
            + byLatest(threads.filter { [.idle, .unknown].contains(status($0)) })
    }

    /// Opens a picked row exactly as the dock does, replacing the current thread in place.
    static func open(_ thread: Thread, current: PaneAddress, busy: Bool,
                     width: UserInterfaceSizeClass?, scene: SceneState) {
        guard !busy, thread.address != current else { return }
        let route: Route = thread.agent.opensAsConversation ? .conversation(thread.address) : .terminal(thread.address)
        guard width != .regular else { return scene.open(route) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scene.open(route) }
    }

    /// The latest turn first; unknown times last.
    private static func byLatest(_ threads: [Thread]) -> [Thread] {
        threads.sorted(by: latestTurnPrecedes)
    }

    /// "1 needs you", "3 need you" (round 20: "1 need you").
    private func summary(waiting: Int) -> String {
        waiting == 1 ? "1 needs you" : "\(waiting) need you"
    }

    // MARK: Actions

    /// The title bar and the home indicator's margin, around the lanes.
    private static let sheetChrome: CGFloat = 96

    /// Tall enough for every lane, measured; half height until they first lay out.
    private var fitted: PresentationDetent {
        fit.map { .height($0 + Self.sheetChrome) } ?? .medium
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if open {
            held = live.map { HeldLane(id: $0.id, title: $0.title, addresses: $0.threads.map(\.address)) }
            // The lanes' last measured height, or before they've ever laid out a near guess from
            // their rows, refitted once they do (`fitted`).
            if fit == nil, let held {
                fit = CGFloat(held.count) * 40 + CGFloat(held.reduce(0) { $0 + $1.addresses.count }) * 70
            }
            detent = typeSize.isAccessibilitySize ? .large : fitted
            AgentsTip().invalidate(reason: .actionPerformed)
        }
        isOpen = open
    }

    /// A quick-switch pick, looked up again: the menu's row may have ended since it was built.
    private func quickSelect(_ address: PaneAddress) {
        guard let thread = model.dockThreads(in: scene).first(where: { $0.address == address }) else { return }
        AgentsTip().invalidate(reason: .actionPerformed)
        select(thread)
    }

    /// Replaces the open thread rather than stacking on it, at once on a phone: the sheet goes
    /// down over the conversation it picked.
    private func select(_ thread: Thread) {
        isOpen = false
        Self.open(thread, current: current, busy: busy, width: width, scene: scene)
    }
}

/// The dock's button: tap toggles the stack, hold opens a compact menu of the active agents,
/// the most urgent nearest the button. Compared by value: a menu rebuilt while open jumps, and
/// the thread re-renders with every streamed record.
private struct QuickSwitch: View, Equatable {
    struct Item: Equatable, Identifiable {
        let address: PaneAddress
        let title: String
        let symbol: String
        let status: String
        let host: String?
        let workspace: String?
        let harness: String?
        let unread: Bool
        /// "web-dashboard · OMP · waiting 4m", under the title.
        let detail: String
        let spokenAge: String?
        /// What it asks, or its verdict, for VoiceOver.
        let about: String?
        var id: PaneAddress { address }
        var spoken: String {
            ([AgentDock.accessibilityTitle(title: title, host: host, workspace: workspace), unread ? "Unread" : nil,
              status, harness, spokenAge, about]
                .compactMap { $0 }).joined(separator: ", ")
        }
    }

    /// The agent ⌘J would open, for VoiceOver's actions on the button.
    struct Next: Equatable {
        let address: PaneAddress
        let title: String
    }

    let items: [Item]
    let summary: String
    let next: Next?
    let mood: HerdMark.Mood
    let toggle: () -> Void
    let pick: (PaneAddress) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.summary == rhs.summary && lhs.next == rhs.next && lhs.mood == rhs.mood
    }

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button { pick(item.address) } label: {
                    Label(item.title, systemImage: item.symbol)
                    if !item.detail.isEmpty { Text(item.detail) }
                }
                .accessibilityLabel(item.spoken)
            }
            if items.isEmpty { Text("No active agents") }
        } label: {
            // The sheep's room: the sheep draws over the menu, since a menu label kept the mood
            // it first showed (round 22's capture: a cursor beside a count of 1 waiting).
            Color.clear
                .frame(width: AgentDock.size, height: AgentDock.size)
                .contentShape(.circle)
        } primaryAction: {
            toggle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // The first item nearest the button, wherever the menu opens.
        .menuOrder(.priority)
        // The herd itself, the app's sheep, whatever is waiting; the count badge carries the
        // urgency (round 7: the orange question bubble repeated the Next capsule's symbol;
        // round 16: two chat bubbles beside a chat composer read as messages, not agents).
        .overlay {
            HerdMark(size: 28, mood: mood)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Agents")
        .accessibilityValue(summary)
        .accessibilityHint("Shows agents that need you and other agents to switch to; hold for the active ones")
        // ⌘J's jump, one action away wherever VoiceOver is, rather than past the result to the
        // Next card at its end (round 50: sb#6).
        .accessibilityActions {
            if let next {
                Button("Next Needs You: \(next.title)") { pick(next.address) }
            }
        }
    }
}

/// The sheep's first-use hint: once a second thread has opened (by any route), what the button
/// is for, both gestures named; gone for good once the dock or its quick switch is used.
struct AgentsTip: Tip {
    static let threadOpened = Tips.Event(id: "threadOpened")
    /// The last thread counted, so a view's appearing twice isn't a second thread.
    @MainActor private static var counted: PaneAddress?

    var title: Text { Text("Your Other Agents") }
    /// Short, and in the app's secondary grey on an opaque card (round 48: sa#6, opus#2, the
    /// system's grey on glass read muddy, and its two sentences covered the result's text).
    var message: Text? {
        Text("Tap the sheep for every other agent. Hold it to jump to an active one.").foregroundStyle(Tokens.secondaryText)
    }
    var rules: [Rule] {
        #Rule(Self.threadOpened) { $0.donations.count >= 2 }
    }
    var options: [any TipOption] { MaxDisplayCount(1) }

    @MainActor static func opened(_ address: PaneAddress) async {
        guard counted != address else { return }
        counted = address
        await threadOpened.donate()
    }

    /// At launch. The demo starts afresh each time, so its walkthrough shows the hint too.
    static func configure(demo: Bool) {
        if demo { try? Tips.resetDatastore() }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

extension View {
    /// The dock's layer over a thread. It shows only while a bar inside keeps it a place
    /// (`AgentDock.slot`); its sheet opens from the button.
    func agentDock(current: PaneAddress, busy: Bool, quiet: Bool = false) -> some View {
        overlayPreferenceValue(AgentDock.Slot.self) { slot in
            if let slot { AgentDock(current: current, busy: busy, slot: slot, quiet: quiet) }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
