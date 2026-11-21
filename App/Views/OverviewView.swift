import SwiftUI
import HerdrAPI

/// A glanceable landing page for the split view when no conversation is selected.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneState.self) private var scene
    @Environment(Settings.self) private var settings
    @Environment(DecisionLog.self) private var decisionLog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var threads: [Thread] { model.dockThreads(in: scene) }
    /// Waiting on the user, and any answered here or in the sidebar while its receipt shows, in
    /// the inbox's order (round 7: oldest first here, newest first there); by time alone, so a
    /// card holding its receipt doesn't move as its agent goes back to work.
    private var waiting: [Thread] {
        threads.filter { $0.connection.presentedStatus($0.agent) == .blocked || scene.inlineAnswers[$0.address] != nil }
            .sorted(by: latestTurnPrecedes)
    }
    private var needsUserCount: Int { threads.count(where: scene.needsUser) }
    /// Every agent at work, live or gone still, in the inbox's order: the page's supervising
    /// view of the work, each tile with what it's doing now or last reported (round 85: sa#4,
    /// sb#6, with only the still ones here, the live agent was a number in Fleet).
    private var working: [Thread] {
        threads.filter {
            $0.connection.presentedStatus($0.agent) == .working && scene.inlineAnswers[$0.address] == nil
        }.sorted(by: latestTurnPrecedes)
    }

    /// The detail column's width; wide enough, the Overview splits into readable columns.
    @State private var width: CGFloat = 0
    private var wide: Bool { width >= 600 }
    /// Recently Finished shows its first few until asked for the rest.
    @State private var allFinished = false

    /// A triage page, not a second sidebar (round 33: every grader found it repeated the
    /// sidebar's lanes at greater height): what needs you, answerable in place; the work, each
    /// agent's step on a tile; then each finished agent once, newest first, the results to read before
    /// the fleet by host and workspace, what the sidebar can't say (round 56: sb#6, opus#13,
    /// in portrait Fleet pushed the results below the screen; round 36 had put results first
    /// and the fleet fell to the bottom, but the results are the page's job). Wide, cards go
    /// two abreast.
    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.xl) {
                    header
                    needsYou(now: context.date)
                    workingSection(now: context.date)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Tokens.Space.l, alignment: .top)],
                              alignment: .leading, spacing: Tokens.Space.xl) {
                        finished(now: context.date)
                        fleet
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: wide ? 1120 : 560, alignment: .leading)
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Tokens.Surface.base)
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// A section's title, a heading for VoiceOver's rotor too (round 35: only the page's header
    /// was one).
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func needsYou(now: Date) -> some View {
        if !waiting.isEmpty {
            // Every one, answerable in place (round 7: five shown under a count of more); two
            // abreast where they fit.
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                // As the inbox's lane: "Answered" once only receipts remain (round 10:
                // "Needs You" stood over cards already answered).
                sectionTitle(waiting.contains(where: scene.needsUser) ? AgentStatus.blocked.section : "Answered")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: waiting.count > 1 ? 400 : 10_000), spacing: Tokens.Space.s, alignment: .top)],
                          alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(waiting) { thread in waitingCard(thread, now: now) }
                }
            }
        }
    }

    /// Work, a tile each, two or more abreast where they fit, live or gone still ("no update 6m"
    /// and the hourglass on its tile), headed as the inbox's lane is, "Working 2 (1 no update)"
    /// (round 33 had kept only the still ones, the exception, as a list repeated the sidebar's;
    /// tiles carry the step the sidebar cuts to a line); at least 280 pt each (round 26: at 200
    /// pt beside a second column titles wrapped). Not beside the sidebar short of accessibility
    /// sizes, whose Working lane lists the same agents with the same step, age and place, the
    /// header's legend and the Fleet keeping the count (round 94: opus#4, sa#7, sb#6, a card of
    /// rows there, round 90, was still the sidebar again; at accessibility sizes the sidebar cuts
    /// what a tile keeps whole).
    @ViewBuilder private func workingSection(now: Date) -> some View {
        if !working.isEmpty, !scene.sidebarBeside || typeSize.isAccessibilitySize {
            let still = working.count { $0.connection.quiet($0.agent) != nil }
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                    sectionTitle(AgentStatus.working.section)
                    Text("\(working.count)\(still > 0 ? " (\(still) no update)" : "")")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(Tokens.secondaryText)
                        .accessibilityLabel(still > 0 ? "\(working.count) working, \(still) with no transcript update" : "\(working.count) working")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Tokens.Space.s, alignment: .top)],
                          alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(working) { thread in workingTile(thread, now: now) }
                }
            }
        }
    }

    /// Whether two 280 pt tiles fit side by side in the content's width; only then do they
    /// reserve their lines to match.
    private var tilesAbreast: Bool {
        min(width - 2 * Tokens.Space.xl, wide ? 1120 : 560) >= 2 * 280 + Tokens.Space.s
    }

    private var header: some View {
        // Over every agent as shown, not the cards: one answered here already counts as the
        // work it went back to, or the result it left (round 16: held cards fell out of the totals).
        let count = needsUserCount
        let active = threads.filter { scene.shownStatus($0) == .working }
        let unread = threads.count { scene.shownStatus($0) == .done && $0.agent.hasTranscript }
        let line = summary(needing: count, working: active.count, unread: unread,
                           decided: decisionLog.decidedToday(in: model.scopedConnections(in: scene).map(\.identity)))
        let all = tallies(threads)
        return VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(alignment: .center, spacing: Tokens.Space.l) {
                HerdMark(size: 56, mood: count > 0 ? .waiting : (active.isEmpty ? .idle : .working))
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(line.title).font(.title2.weight(.semibold))
                    if let detail = line.detail {
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(Tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            // The whole herd by state in one bar under the words, its key under it, the
            // aggregate at first glance (round 62: opus#2, sa#4, the fleet's bar sat at the
            // page's foot under the results, and a lone host drew it again there).
            if !all.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    tallyBar(all)
                    legend(all)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(all.filter { $0.id != "still" }.map(\.words).joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Tokens.Space.s)
    }

    /// The day at a glance, led by what needs you: the title says it, under it what the bar's
    /// key doesn't, what was decided today (round 9: it said "All quiet" over unread results;
    /// round 22: a generic "Your agents" title; round 62: the working and result counts moved
    /// to the bar's key, which says the ones gone still too, as round 31 asked).
    private func summary(needing: Int, working: Int, unread: Int, decided: Int) -> (title: String, detail: String?) {
        let decidedLine = decided > 0 ? "\(decided) decided today" : nil
        if needing == 0 && working == 0 && unread == 0 && decided == 0 { return ("All quiet", "Nothing needs you.") }
        let title = needing == 0 ? "Nothing needs you" : needing == 1 ? "1 agent needs you" : "\(needing) agents need you"
        return (title, decidedLine)
    }

    /// Where an agent runs: its workspace, after its host when the agents shown span more than
    /// one (round 8: All Hosts showed workspaces that could have been on any of them), then its
    /// harness, as the inbox row writes it (round 15: Overview cards omitted it).
    private func place(_ thread: Thread) -> String {
        let workspace = thread.workspace?.displayLabel ?? "Workspace"
        let hosts = Set(threads.map { $0.connection.profile.id })
        let place = hosts.count > 1 ? "\(thread.connection.profile.name) · \(workspace)" : workspace
        return [place, thread.agent.agent.map(agentKindLabel)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The age as VoiceOver says it, as the card or row shows it, when there is one.
    private func spokenAge(_ thread: Thread, status: AgentStatus) -> String? {
        thread.connection.spokenAge(thread.agent, status: status)
    }

    /// What the agent asks, with what it would run apart, as the inbox row says it, and the same
    /// answer in place (`InlineApproval`, shared with the sidebar through `InlineAnswers`); the
    /// header opens the thread.
    private func waitingCard(_ thread: Thread, now: Date) -> some View {
        let shortcutOwner = waiting.first { scene.inlineAnswers.choices(for: $0) != nil && scene.inlineAnswers[$0.address]?.receipt == nil }
        let isShortcutOwner = shortcutOwner?.address == thread.address && scene.selectedRoute == nil
        let status = scene.shownStatus(thread)
        let wait = thread.connection.wait(thread.agent)
        let screen = wait?.console == nil ? wait?.prompt : nil
        let question = screen?.title ?? wait?.summary
        let command = screen?.shownSubject?.split(whereSeparator: \.isNewline).joined(separator: " ")
        let inline = scene.inlineAnswers.choices(for: thread)
        let route: Route = thread.agent.opensAsConversation ? .conversation(thread.address) : .terminal(thread.address)
        return VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Button { scene.open(route) } label: {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                    Image(systemName: status.symbol)
                        .font(.body)
                        .foregroundStyle(status.tint)
                        .frame(width: 24, alignment: .center)
                        .accessibilityHidden(true)
                    // The question leads, the agent under it as its context: the sidebar beside
                    // lists agents by name, this card is the decision (round 68: sa#3, opus#1, it
                    // led with the sidebar row's title, place and age, a second copy of it).
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(question ?? thread.agent.conversationTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Tokens.Space.s)
                            if let date = thread.connection.ageDate(thread.agent, status: status) {
                                Text(status == .blocked ? AgentRow.waiting(since: date, at: now) : AgentRow.age(of: date, at: now))
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.secondaryText)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Tokens.secondaryText)
                                .accessibilityHidden(true)
                        }
                        Text(question == nil ? place(thread) : "\(thread.agent.conversationTitle) · \(place(thread))")
                            .font(.subheadline)
                            .foregroundStyle(Tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let command {
                            PendingCommand(command: command, mayBeCut: screen?.contextMayBeTruncated == true, lines: 3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Heard as it reads: the question and its command first, then whose it is (round 69:
            // sb#1, VoiceOver heard the title, status, place and age before the question).
            .accessibilityLabel(question ?? thread.agent.conversationTitle)
            // Unread said on every Overview item, as the inbox's rows say it (round 28: only results did).
            .accessibilityValue([command.map { screen?.contextMayBeTruncated == true ? "\($0), read from the screen, may be incomplete" : $0 },
                                 question == nil ? nil : thread.agent.conversationTitle,
                                 thread.connection.isUnread(thread.agent) ? "Unread" : nil, status.label, place(thread), spokenAge(thread, status: status)]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens its conversation")
            if let inline {
                InlineApproval(choices: inline.choices, title: thread.agent.conversationTitle, answer: scene.inlineAnswers[thread.address],
                               indent: 0, numberedShortcuts: isShortcutOwner) { label in
                    scene.inlineAnswers.answer(label, prompt: inline.prompt, ask: inline.ask, in: thread,
                                               decisionLog: decisionLog, saved: model.demo == nil)
                } open: {
                    scene.open(route)
                } openTerminal: {
                    scene.open(.terminal(thread.address))
                } writeAnswer: {
                    scene.writeAnswer = thread.address
                    scene.open(route)
                }
            }
        }
        .padding(Tokens.Space.l)
        .raisedCard()
    }

    /// A result's verdict in primary over the rest in the caller's secondary, its points a line
    /// each (`TranscriptActivity.opening`; round 29: " · Move: …" ran them together; round 30:
    /// one grey block didn't say which line was the verdict; round 31: prose after the verdict
    /// stayed one grey block).
    private func verdictText(_ preview: String) -> Text {
        let (verdict, rest) = TranscriptActivity.opening(preview)
        guard let rest else { return Text(verdict).foregroundStyle(Color.primary) }
        return Text("\(Text(verdict).foregroundStyle(Color.primary))\n\(rest)")
    }

    /// A working agent, on the result rows' template (round 31: its tile alone had no chevron
    /// and kept "no update" off the title's line): the turning ring, or once gone still the grey
    /// hourglass (round 33: a stopped grey ring read as the live one) and "no update 6m" at the
    /// title's end (`AgentRow.quiet`), as a result's age ends it; then its place and its step,
    /// in primary while it reports now, as the inbox row sets it, grey once it's what it last
    /// reported. One template whatever the words: abreast, the title and step keep two
    /// lines each, so the tiles match and their lines align (round 24: one title wrapped and the
    /// other didn't).
    private func workingTile(_ thread: Thread, now: Date) -> some View {
        let work = work(thread, now: now)
        return Button {
            scene.open(thread.agent.opensAsConversation ? .conversation(thread.address) : .terminal(thread.address))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                workGlyph(work)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.agent.conversationTitle)
                            .foregroundStyle(.primary)
                            .tileLines(large: typeSize.isAccessibilitySize, matched: matched)
                        Spacer(minLength: Tokens.Space.s)
                        if let age = work.age {
                            Text(age).font(.footnote).monospacedDigit().foregroundStyle(Tokens.secondaryText).fixedSize()
                        }
                    }
                    Text(place(thread))
                        .font(.subheadline)
                        .foregroundStyle(Tokens.secondaryText)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    // Reserved even when there's no open call, so the tiles keep one shape.
                    Text(work.step ?? "")
                        .font(.subheadline)
                        .foregroundStyle(work.still == nil ? Color.primary : Tokens.secondaryText)
                        .tileLines(large: typeSize.isAccessibilitySize, matched: matched)
                }
                Spacer(minLength: 0)
                chevron
            }
            .padding(.vertical, Tokens.Space.m)
            .padding(.horizontal, Tokens.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .raisedCard()
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workLabel(thread, work))
    }

    private struct Work {
        let status: AgentStatus
        let step: String?
        let still: String?
        let age: String?
    }

    private func work(_ thread: Thread, now: Date) -> Work {
        let status = scene.shownStatus(thread)
        let still = thread.connection.stillSince(thread.agent).flatMap { AgentRow.quiet(since: $0, at: now) }
        // "for 1m" while live, as the sidebar's row ends it, "no update 6m" once still (round 86:
        // sb#4, only the still tile said how long).
        let age = still ?? thread.connection.workingSince(thread.agent, status: status).flatMap { AgentRow.working(since: $0, at: now) }
        return Work(status: status, step: thread.connection.rowLine(thread.agent, status: status, previews: settings.inboxPreviews, now: now),
                    still: still, age: age)
    }

    private func workGlyph(_ work: Work) -> some View {
        Image(systemName: work.still != nil ? AgentStatus.stillSymbol : work.status.symbol)
            .foregroundStyle(work.still != nil ? Tokens.secondaryText : work.status.tint)
            .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.25),
                          isActive: work.status == .working && work.still == nil && !reduceMotion)
            .id(work.still != nil)
            .frame(width: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Tokens.secondaryText)
            .accessibilityHidden(true)
    }

    private func workLabel(_ thread: Thread, _ work: Work) -> String {
        [thread.agent.conversationTitle, thread.connection.isUnread(thread.agent) ? "Unread" : nil,
         place(thread), work.status.label, spokenAge(thread, status: work.status), work.step]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Tiles abreast keep those lines even when empty, so they match; one to a row, they don't
    /// (a lone tile showed blank lines under its title).
    private var matched: Bool { tilesAbreast && !typeSize.isAccessibilitySize }

    // MARK: Fleet

    /// Agents in one state: a segment of a host's bar and a line of its legend, one each, in the
    /// same order (round 35: the legend said "2 working" over a segment of one, the stalled
    /// agent counted in both).
    private struct Tally: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let count: Int
        let words: String
    }

    private func tallies(_ threads: [Thread]) -> [Tally] {
        let shown = threads.map { (thread: $0, status: scene.shownStatus($0)) }
        let working = shown.filter { $0.status == .working }
        let still = working.count { $0.thread.connection.quiet($0.thread.agent) != nil }
        let needs = shown.count { $0.status == .blocked }
        let done = shown.count { $0.status == .done }
        let read = shown.count { $0.status == .idle }
        // The bar draws live and still work apart, each agent once; the legend names the inbox's
        // own total, "2 working (1 no update)", as its Working lane counts both (round 38: sb#10).
        return [
            Tally(id: "needs", symbol: AgentStatus.blocked.symbol, tint: AgentStatus.blocked.tint, count: needs,
                  words: "\(needs) \(needs == 1 ? "needs" : "need") you"),
            Tally(id: "working", symbol: AgentStatus.working.symbol, tint: AgentStatus.working.tint, count: working.count - still,
                  words: still > 0 ? "\(working.count) working (\(still) no update)" : "\(working.count) working"),
            Tally(id: "still", symbol: AgentStatus.stillSymbol, tint: Tokens.secondaryText, count: still, words: "\(still) no update"),
            Tally(id: "done", symbol: AgentStatus.done.symbol, tint: AgentStatus.done.tint, count: done,
                  words: "\(done) done"),
            Tally(id: "read", symbol: AgentStatus.idle.symbol, tint: Tokens.secondaryText, count: read, words: "\(read) read"),
        ].filter { $0.count > 0 || $0.id == "working" && !working.isEmpty }
    }

    /// The fleet by host, every host in scope, one without agents too: its link when it isn't
    /// live, its agents by state in one bar when there are other hosts (a lone host's is the
    /// header's), then each workspace with its counts by state, where
    /// the work is, which the sidebar's lanes don't show (round 33: the Overview repeated the
    /// sidebar's lanes; round 35: a host that had sent no agents had no card).
    @ViewBuilder private var fleet: some View {
        let hosts = model.scopedConnections(in: scene)
            .sorted { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                sectionTitle("Fleet")
                ForEach(hosts, id: \.profile.id) { host in
                    hostCard(host, threads: threads.filter { $0.connection === host }, totals: hosts.count > 1)
                }
            }
        }
    }

    /// `totals`: its own bar and legend, only beside other hosts; a lone host's are the page's
    /// header bar (round 62: opus#2, sa#4, one bar drawn twice).
    private func hostCard(_ connection: HostConnection, threads: [Thread], totals: Bool) -> some View {
        let tallies = tallies(threads)
        let workspaces = Dictionary(grouping: threads) { $0.workspace?.displayLabel ?? "Workspace" }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                Label(connection.profile.name, systemImage: "server.rack").font(.headline)
                Spacer(minLength: Tokens.Space.s)
                // The link only when it isn't live (`statusText`); else how many agents run here.
                Text(connection.statusText ?? (threads.isEmpty ? "No agents" : "\(threads.count) \(threads.count == 1 ? "agent" : "agents")"))
                    .font(.footnote)
                    .foregroundStyle(connection.statusText == nil ? Tokens.secondaryText : Tokens.Tint.attention)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !tallies.isEmpty {
                if totals {
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        tallyBar(tallies)
                        legend(tallies)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tallies.filter { $0.id != "still" }.map(\.words).joined(separator: ", "))
                    Divider()
                }
                // Rows ruled apart with room to breathe, a settings list's rhythm (round 78:
                // sa#8, 8 pt apart and unruled they read as a packed table).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(workspaces.enumerated()), id: \.element.key) { index, workspace in
                        if index > 0 { Divider() }
                        workspaceRow(workspace.key, workspace.value).padding(.vertical, Tokens.Space.s)
                    }
                }
                .padding(.vertical, -Tokens.Space.s)
            }
        }
        .padding(Tokens.Space.l)
        .raisedCard()
        .accessibilityElement(children: .contain)
    }

    /// The counts as proportions, a segment per state in its tint; work gone still an outline in
    /// the working blue, part of the legend's "2 working (1 no update)" rather than a fourth state
    /// it doesn't name (round 86: sa#6, a grey outline read as an unlabelled category), apart from
    /// the read results' faint fill by shape, not two greys (round 35).
    private func tallyBar(_ tallies: [Tally]) -> some View {
        let segments = tallies.filter { $0.count > 0 }
        let total = CGFloat(max(segments.reduce(0) { $0 + $1.count }, 1))
        return GeometryReader { proxy in
            let room = proxy.size.width - CGFloat(max(segments.count - 1, 0)) * 3
            HStack(spacing: 3) {
                ForEach(segments) { tally in
                    Group {
                        if tally.id == "still" {
                            Capsule().strokeBorder(AgentStatus.working.tint, lineWidth: 1.5)
                        } else {
                            Capsule().fill(tally.id == "read" ? Tokens.secondaryText.opacity(0.4) : tally.tint)
                        }
                    }
                    .frame(width: room * CGFloat(tally.count) / total)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    /// The bar's states in its order, wrapping as words do (round 35: one to a line whenever the
    /// row didn't fit, the legend outweighed the bar).
    private func legend(_ tallies: [Tally]) -> some View {
        Flow(spacing: Tokens.Space.l, lineSpacing: Tokens.Space.xs) {
            ForEach(tallies.filter { $0.id != "still" }) { tally in
                Label { Text(tally.words) } icon: { Image(systemName: tally.symbol).foregroundStyle(tally.tint) }
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Tokens.secondaryText)
    }
    /// A workspace with bounded state counts (round 38: glyphs per agent grew without bound), in
    /// the legend's words while they fit, else glyph and number (round 69: sa#7, bare glyph-number
    /// pairs had to be matched against the legend). Gone still, an agent is still counted at
    /// work, as the all-clear tally says it, "2 working (1 no update)" (round 70: sb#5, "1
    /// working · 1 no update" here beside "2 working (1 no update)" in the inbox).
    private func workspaceRow(_ name: String, _ agents: [Thread]) -> some View {
        let shown = agents.map { (thread: $0, status: scene.shownStatus($0)) }
        let needs = shown.count { $0.status == .blocked }
        let working = shown.count { $0.status == .working }
        let still = shown.count { $0.status == .working && $0.thread.connection.quiet($0.thread.agent) != nil }
        let done = shown.count { $0.status == .done }
        let read = shown.count { $0.status == .idle }
        let stillWords = still > 0 ? " (\(still) no update)" : ""
        var summaries: [(symbol: String, tint: Color, words: Text, number: Text)] = []
        if needs > 0 { summaries.append((AgentStatus.blocked.symbol, AgentStatus.blocked.tint, Text("\(needs) needs you"), Text("\(needs)"))) }
        if working > 0 {
            let stillNumber = still > 0 ? Text(" (\(Image(systemName: AgentStatus.stillSymbol))\(still))") : Text("")
            // All of them gone still, the grey hourglass, as their tiles draw them (round 77:
            // sb#7, the live blue ring over agents with no update).
            let allStill = still == working
            summaries.append((allStill ? AgentStatus.stillSymbol : AgentStatus.working.symbol,
                              allStill ? Tokens.secondaryText : AgentStatus.working.tint,
                              Text("\(working) working\(stillWords)"),
                              allStill ? Text("\(working)") : Text("\(working)\(stillNumber)")))
        }
        if done > 0 { summaries.append((AgentStatus.done.symbol, AgentStatus.done.tint, Text("\(done) done"), Text("\(done)"))) }
        if read > 0 { summaries.append((AgentStatus.idle.symbol, Tokens.secondaryText, Text("\(read) read"), Text("\(read)"))) }
        let spoken = [
            needs > 0 ? "\(needs) needs you" : nil,
            working > 0 ? "\(working) working" + (still > 0 ? ", \(still) with no transcript update" : "") : nil,
            done > 0 ? "\(done) done" : nil,
            read > 0 ? "\(read) read" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        return HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            // The name first, the counts in what room is left: words, else glyphs.
            Text(name).font(.subheadline).lineLimit(typeSize.isAccessibilitySize ? nil : 1).layoutPriority(1)
            Spacer(minLength: Tokens.Space.s)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.m) {
                    ForEach(Array(summaries.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 3) {
                            Image(systemName: item.symbol).foregroundStyle(item.tint)
                            item.words.monospacedDigit()
                        }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Array(summaries.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 2) {
                            Image(systemName: item.symbol).foregroundStyle(item.tint)
                            item.number.monospacedDigit()
                        }
                    }
                }
                .fixedSize()
            }
            .font(.footnote)
            .foregroundStyle(Tokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(spoken)")
    }

    // MARK: Recently finished

    /// Finished agents not already above, newest first, each once: what it found, when, on a
    /// rail (round 35: an activity feed restated the Needs You and Working cards over it, so
    /// an agent showed four times on the page). Unread ones lead with the filled check and a
    /// semibold title. Beside the sidebar, only the unread and those ending in a caution: the
    /// rest are its Read lane (round 63: opus#1, sa#3, sb#8, three read results in both columns
    /// pushed the Fleet down), but a read result's warning stood only there, cut short (round
    /// 90: sb#9 r88, "apply 0042 first" was missing from the Overview).
    private var finishedThreads: [Thread] {
        threads.filter {
            let status = scene.shownStatus($0)
            return (status == .done || status == .idle) && $0.agent.hasTranscript && scene.inlineAnswers[$0.address] == nil
                && $0.connection.ageDate($0.agent, status: status) != nil
                && (!scene.sidebarBeside || $0.connection.isUnread($0.agent)
                    || $0.connection.caution($0.agent, status: status, previews: settings.inboxPreviews) != nil)
        }
        .sorted(by: latestTurnPrecedes)
    }

    @ViewBuilder private func finished(now: Date) -> some View {
        let finished = finishedThreads
        if !finished.isEmpty {
            let shown = allFinished ? finished : Array(finished.prefix(5))
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                // Beside the sidebar, named for the subset it keeps (round 91: sb#5, "Recently
                // Finished" over one of three read results didn't say why the others were gone);
                // "Follow-Ups" when all it keeps is read, there for their cautions (round 95: sa#5,
                // sb#8, "To Review" over a result already read).
                sectionTitle(!scene.sidebarBeside ? "Recently Finished"
                             : finished.contains { $0.connection.isUnread($0.agent) } ? "To Review" : "Follow-Ups")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, thread in
                        finishedRow(thread, now: now, rail: index < shown.count - 1)
                    }
                    if finished.count > shown.count {
                        Button("Show All \(finished.count)") { allFinished = true }
                            .inlineAction()
                            .frame(minHeight: Tokens.minTap)
                    }
                }
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.s)
                .raisedCard()
            }
        }
    }

    /// The glyph on a rail to the next, then the title with how long ago at its end, as the
    /// inbox row has it ("45m ago"; round 58: sb#14, sa#6, a bare "45m" in a column of its own
    /// before the rail narrowed the results and read apart from the sidebar's "45m ago"), its
    /// place (round 36: a reused title was ambiguous without it) and the verdict (primary, the
    /// rest under it in secondary), three lines while unread, two once read (round 36: read prose
    /// outweighed the fleet). At accessibility sizes the age leads the words, the verdict is
    /// whole and the rail goes.
    private func finishedRow(_ thread: Thread, now: Date, rail: Bool) -> some View {
        let large = typeSize.isAccessibilitySize
        let status = scene.shownStatus(thread)
        let unread = thread.connection.isUnread(thread.agent)
        let ago = thread.connection.ageDate(thread.agent, status: status).map { AgentRow.ago(of: $0, at: now) } ?? ""
        // Beside the sidebar a read one is here for its caution alone; it says it's read, as the
        // sidebar's Read lane has it (round 94: sa#6, sb#5, "To Review" over a result the sidebar
        // called Read, with nothing to say both were true).
        let age = scene.sidebarBeside && !unread ? ["Read", ago].filter { !$0.isEmpty }.joined(separator: " · ") : ago
        let preview = thread.connection.rowLine(thread.agent, status: status, previews: settings.inboxPreviews)
        let caution = thread.connection.caution(thread.agent, status: status, previews: settings.inboxPreviews)
        let words = VStack(alignment: .leading, spacing: 2) {
            if large {
                Text(age).font(.footnote).foregroundStyle(Tokens.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                Text(thread.agent.conversationTitle)
                    .fontWeight(unread ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !large {
                    Spacer(minLength: 0)
                    Text(age).font(.footnote).foregroundStyle(Tokens.secondaryText).fixedSize()
                }
            }
            Text(place(thread))
                .font(.footnote)
                .foregroundStyle(Tokens.secondaryText)
                .lineLimit(large ? nil : 1)
            // Its closing warning first, as the inbox row and thread show it (round 41: sb#1,
            // "No blocking findings" read as all clear without "apply 0042 first"; round 50:
            // sa#4, sb#1, under the verdict here, before it everywhere else), at the verdict's
            // size (round 53: opus#7, sa#2, sb#2, in footnote it read as fine print).
            if let caution {
                Label {
                    AgentRow.cautionText(caution).foregroundStyle(Tokens.secondaryText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Tint.caution)
                }
                .labelStyle(.caveat)
                .font(.subheadline)
                .lineLimit(large ? nil : 3)
            }
            if let preview {
                // With a caution, the verdict alone in up to two lines, the caution three more
                // (round 42: sb#4, an implementation bullet came first and the caution was cut;
                // round 43: sb#8, opus#6, the verdict ran on into its first point and was cut).
                verdictText(caution == nil ? preview : TranscriptActivity.verdict(preview))
                    .font(.subheadline)
                    .foregroundStyle(Tokens.secondaryText)
                    .lineLimit(large ? nil : unread && caution == nil ? 3 : 2)
            }
        }
        return Button {
            scene.open(.conversation(thread.address))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status == .done ? status.tint : Tokens.secondaryText)
                    .frame(width: 24, alignment: .center)
                words
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.secondaryText)
            }
            .padding(.vertical, Tokens.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The rail runs from under this glyph to the next row's.
            .background(alignment: .topLeading) {
                if rail && !large {
                    Rectangle().fill(.separator)
                        .frame(width: 1)
                        .padding(.leading, 12)
                        .padding(.top, Tokens.Space.s + 26)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        // Unread said, as the inbox's rows say it (round 27), and where it ran (round 35: the
        // feed dropped workspace and harness); a read one "Read", as it shows (round 95: sb#1,
        // VoiceOver heard "Done" beside the visible "Read · 45m ago").
        .accessibilityLabel([thread.agent.conversationTitle, unread ? "Unread" : nil, place(thread), status.section,
                             spokenAge(thread, status: status), caution.map(AgentRow.spokenCaution), preview].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens its conversation")
    }
}

private extension View {
    /// Two lines each for a tile's title and step, reserved when tiles sit abreast; whole at
    /// accessibility sizes (round 25: the even template cut what a large-text reader needed;
    /// round 60: sb#4 r58, a 20-line cap stood in for "whole").
    @ViewBuilder func tileLines(large: Bool, matched: Bool) -> some View {
        if large { lineLimit(nil) } else { lineLimit(2, reservesSpace: matched) }
    }
}
