import HerdrAPI
import SwiftUI

/// The way to the next agent from inside a thread: a glass button that stands on the
/// composer's send button (or ends the terminal's keys row while typing) and opens into a short
/// stack. The bar reserves its place (`AgentDock.slot`); the dock's own layer (`agentDock`)
/// draws it there, so the stack can open over the whole thread and morph out of the button.
/// By default what needs attention leads (needs you, then unread finishes, the longest waiting
/// first) so the next turn can go out as soon as one ends, then working, then idle agents;
/// Settings can switch it to the Agents list's own order. The stack's order holds while it is
/// open, so a row never moves under a thumb. Picking a row replaces the open thread. A hold
/// opens the quick switch instead: a native menu of only the active agents, the most urgent
/// nearest the button, whatever Dock Order says.
struct AgentDock: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    let current: PaneAddress
    /// A send in flight owns this conversation's composer and attachments; switching waits for it.
    let busy: Bool
    /// The place the bar keeps for the button.
    let slot: Anchor<CGRect>

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
    /// Each section's rows, in order, from when the stack opened.
    @State private var held: [HeldLane]?
    /// The stack's natural height, which sizes it up to its cap.
    @State private var stackHeight: CGFloat = 0

    struct Lane: Identifiable {
        let id: String
        let title: String
        let threads: [Thread]
    }

    struct HeldLane {
        let id: String
        let title: String
        let addresses: [PaneAddress]
    }

    var body: some View {
        let sections = arranged
        let others = sections.flatMap(\.threads)
        let statuses = others.map { $0.connection.presentedStatus($0.agent) }
        let waiting = statuses.filter { $0 == .blocked || $0 == .done }.count
        let lead: AgentStatus? = statuses.contains(.blocked) ? .blocked : statuses.contains(.done) ? .done : nil
        GeometryReader { proxy in
            let place = proxy[slot]
            // The reader starts under the top bars, so the slot's top is the room above the button
            // (less its gap and a margin): the keyboard can leave far less than the cap.
            let room = place.minY - 10 - 12
            ZStack(alignment: .bottomTrailing) {
                if isOpen {
                    // Tapping anywhere off the stack puts it away.
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { setOpen(false) }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if !others.isEmpty || isOpen {
                    GlassEffectContainer(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 10) {
                            if isOpen {
                                stack(sections, room: room)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                                    .glassEffectID("stack", in: glass)
                                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                                    .transition(.opacity)
                            }
                            button(waiting: waiting, lead: lead, quick: isOpen ? [] : quickItems)
                        }
                    }
                    // Outside the container: it draws its glass over anything inside it.
                    .overlay(alignment: .bottomTrailing) { badge(waiting: waiting, lead: lead) }
                    .padding(.trailing, max(0, proxy.size.width - place.maxX))
                    .padding(.bottom, max(0, proxy.size.height - place.maxY))
                    // Open, it is modal to VoiceOver (the conversation behind is out of reach) and
                    // the escape gesture closes it from anywhere inside.
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(isOpen ? .isModal : [])
                    .accessibilityAction(.escape) { setOpen(false) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
        }
        .sensoryFeedback(.selection, trigger: isOpen) { _, _ in settings.haptics }
        .onChange(of: busy) { _, busy in if busy { setOpen(false) } }
    }

    // MARK: Pieces

    /// Tap opens the stack; a hold opens the quick switch, a native menu of what's active.
    private func button(waiting: Int, lead: AgentStatus?, quick: [QuickSwitch.Item]) -> some View {
        QuickSwitch(items: quick, isOpen: isOpen, lead: lead, summary: isOpen ? "" : summary(waiting: waiting),
                    toggle: { setOpen(!isOpen) }, pick: quickSelect)
            .equatable()
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("button", in: glass)
            .disabled(busy)
    }

    /// How many want the user, on the button's corner.
    @ViewBuilder
    private func badge(waiting: Int, lead: AgentStatus?) -> some View {
        if !isOpen, waiting > 0 {
            Text(waiting, format: .number)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(lead?.tint ?? .accentColor, in: .capsule)
                .frame(width: Self.size, height: Self.size, alignment: .topTrailing)
                .offset(x: 3, y: -3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func stack(_ sections: [Lane], room: CGFloat) -> some View {
        let lead = sections.first?.threads.first.flatMap { thread -> PaneAddress? in
            let status = thread.connection.presentedStatus(thread.agent)
            return status == .blocked || status == .done ? thread.address : nil
        }
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.threads) { thread in
                        row(thread, leads: thread.address == lead)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { stackHeight = $0 }
        // As tall as its rows up to a cap, scrolling past it; a bare ScrollView would take the
        // whole cap even for two rows.
        return ScrollView { content }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 340)
            .frame(height: stackHeight > 0 ? min(stackHeight, 460, max(room, 120)) : nil)
    }

    /// One agent: its state, title and newest line. The first thing that wants the user is
    /// set apart so the next move reads at a glance.
    private func row(_ thread: Thread, leads: Bool) -> some View {
        let status = thread.connection.presentedStatus(thread.agent)
        let detail = settings.inboxPreviews ? thread.connection.preview(thread.agent) : thread.workspace?.label
        let host = settings.allHosts && model.demo == nil ? thread.connection.profile.name : nil
        return Button { select(thread) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .font(leads ? .body : .subheadline)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.agent.conversationTitle)
                        .font(leads ? .headline : .subheadline.weight(thread.connection.isUnread(thread.agent) ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let line = [host, detail].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(leads ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, leads ? 10 : 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                if leads { RoundedRectangle(cornerRadius: 16).fill(status.tint.opacity(0.14)) }
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(thread.agent.conversationTitle)
        .accessibilityValue([status.label, host].compactMap { $0 }.joined(separator: ", "))
    }

    /// The quick switch: needs you, then unread finishes (the longest waiting first), then
    /// working (the latest turn first). Idle is left to the stack, and so is Dock Order: a hold
    /// is for what wants a turn now.
    private var quickItems: [QuickSwitch.Item] {
        let threads = model.dockThreads(in: scene).filter { $0.address != current }
        let attention = threads.filter { [.blocked, .done].contains($0.connection.presentedStatus($0.agent)) }
        let working = threads.filter { $0.connection.presentedStatus($0.agent) == .working }
        let hosts = settings.allHosts && model.demo == nil
        return (Self.byWait(attention) + Self.byLatest(working)).map { thread in
            let status = thread.connection.presentedStatus(thread.agent)
            return QuickSwitch.Item(address: thread.address, title: thread.agent.conversationTitle,
                                    symbol: status.symbol, status: status.label,
                                    host: hosts ? thread.connection.profile.name : nil)
        }
    }

    // MARK: Order

    /// Sections in order, empty ones dropped, the open thread left out. While the stack is open
    /// the order it opened with holds: rows keep their section and place (status glyphs still
    /// update), rows that end drop out, and new threads wait for the next opening.
    private var arranged: [Lane] {
        guard let held else { return live }
        let byAddress = Dictionary(model.dockThreads(in: scene).map { ($0.address, $0) }) { first, _ in first }
        return held.compactMap { section in
            let threads = section.addresses.compactMap { byAddress[$0] }
            return threads.isEmpty ? nil : Lane(id: section.id, title: section.title, threads: threads)
        }
    }

    private var live: [Lane] {
        let threads = model.dockThreads(in: scene).filter { $0.address != current }
        let sections: [Lane]
        switch settings.dockOrder {
        case .status:
            let groups = Dictionary(grouping: threads) { thread -> Int in
                switch thread.connection.presentedStatus(thread.agent) {
                case .blocked, .done: 0
                case .working: 1
                case .idle, .unknown: 2
                }
            }
            sections = [
                Lane(id: "attention", title: "Needs attention", threads: Self.byWait(groups[0] ?? [])),
                Lane(id: "working", title: "Working", threads: Self.byLatest(groups[1] ?? [])),
                Lane(id: "idle", title: "Idle", threads: Self.byLatest(groups[2] ?? [])),
            ]
        case .inbox:
            let shown = inboxSections(threads, grouping: settings.inboxGrouping, sort: settings.inboxSort,
                                      collapseIdle: false, allHosts: settings.allHosts && model.demo == nil,
                                      rank: inboxRank) { _ in false }
            sections = [Lane(id: "needs-you", title: "Needs You", threads: shown.needsYou)]
                + shown.sections.map { Lane(id: $0.id, title: $0.title, threads: $0.threads) }
        }
        return sections.filter { !$0.threads.isEmpty }
    }

    /// Needs you before unread finishes; within each, the one waiting longest first, by herdr's
    /// session-wide state-change sequence (comparable within one session; hosts interleave by it
    /// as a best effort). Ties fall back to the address, never the title.
    private static func byWait(_ threads: [Thread]) -> [Thread] {
        threads.sorted { lhs, rhs in
            let left = lhs.connection.presentedStatus(lhs.agent) == .blocked ? 0 : 1
            let right = rhs.connection.presentedStatus(rhs.agent) == .blocked ? 0 : 1
            if left != right { return left < right }
            let leftSeq = lhs.agent.stateChangeSeq ?? 0, rightSeq = rhs.agent.stateChangeSeq ?? 0
            if leftSeq != rightSeq { return leftSeq < rightSeq }
            return addressPrecedes(lhs.address, rhs.address)
        }
    }

    /// The latest turn first; unknown times last.
    private static func byLatest(_ threads: [Thread]) -> [Thread] {
        threads.sorted { lhs, rhs in
            switch (lhs.connection.lastTurnAt(lhs.agent), rhs.connection.lastTurnAt(rhs.agent)) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return addressPrecedes(lhs.address, rhs.address)
            }
        }
    }

    private static func addressPrecedes(_ lhs: PaneAddress, _ rhs: PaneAddress) -> Bool {
        if lhs.hostID != rhs.hostID { return lhs.hostID.uuidString < rhs.hostID.uuidString }
        if lhs.session != rhs.session { return lhs.session < rhs.session }
        return lhs.paneID < rhs.paneID
    }

    private func summary(waiting: Int) -> String {
        let count = arranged.reduce(0) { $0 + $1.threads.count }
        return waiting > 0 ? "\(waiting) need attention" : "\(count) other agents"
    }

    // MARK: Actions

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if open { held = live.map { HeldLane(id: $0.id, title: $0.title, addresses: $0.threads.map(\.address)) } }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.2)) {
            isOpen = open
        } completion: {
            // Reopened before the close finished: that opening's order stands.
            if !isOpen { held = nil }
        }
    }

    /// A quick-switch pick, looked up again: the menu's row may have ended since it was built.
    private func quickSelect(_ address: PaneAddress) {
        guard let thread = model.dockThreads(in: scene).first(where: { $0.address == address }) else { return }
        select(thread)
    }

    /// Replaces the open thread rather than stacking on it, at once on a phone: only the
    /// conversation under the button changes.
    private func select(_ thread: Thread) {
        guard !busy, thread.address != current else { return }
        let route: Route = thread.agent.hasTranscript ? .conversation(thread.address) : .terminal(thread.address)
        isOpen = false
        held = nil
        guard width != .regular else { return scene.open(route) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scene.open(route) }
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
        var id: PaneAddress { address }
    }

    let items: [Item]
    let isOpen: Bool
    let lead: AgentStatus?
    let summary: String
    let toggle: () -> Void
    let pick: (PaneAddress) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.isOpen == rhs.isOpen && lhs.lead == rhs.lead && lhs.summary == rhs.summary
    }

    var body: some View {
        Menu {
            // Open, the button is Close: a hold has nothing to offer over the stack.
            if !isOpen {
                ForEach(items) { item in
                    Button { pick(item.address) } label: {
                        Label(item.title, systemImage: item.symbol)
                        if let host = item.host { Text(host) }
                    }
                    .accessibilityLabel("\(item.title), \(item.status)")
                }
                if items.isEmpty { Text("No active agents") }
            }
        } label: {
            Image(systemName: isOpen ? "xmark" : lead?.symbol ?? "bubble.left.and.bubble.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(isOpen ? Color.primary : lead?.tint ?? Color.primary)
                // The replace effect's own pace trails the 200 ms open; doubled, it lands with the stack.
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
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
        .accessibilityLabel(isOpen ? "Close agents" : "Agents")
        .accessibilityValue(summary)
        .accessibilityHint(isOpen ? "" : "Shows the agents to switch to; hold for the active ones")
    }
}

extension View {
    /// The dock's layer over a thread. It shows only while a bar inside keeps it a place
    /// (`AgentDock.slot`), and its stack opens over everything.
    func agentDock(current: PaneAddress, busy: Bool) -> some View {
        overlayPreferenceValue(AgentDock.Slot.self) { slot in
            if let slot { AgentDock(current: current, busy: busy, slot: slot) }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
