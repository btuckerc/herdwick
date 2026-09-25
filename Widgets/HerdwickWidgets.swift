import SwiftUI
import WidgetKit

@main
struct HerdwickWidgets: WidgetBundle {
    var body: some Widget {
        AttentionWidget()
    }
}

/// Agents that need you first, then finished work you haven't read, then what's running.
struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Attention", provider: Provider()) { entry in
            AttentionView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("What needs you, what finished and what's still working.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: AttentionSnapshot?
}

/// The app reloads widgets when what it shows changes; the timeline itself never guesses.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: Self.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: context.isPreview ? Self.preview : AttentionSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: AttentionSnapshot.load())], policy: .never))
    }

    private static let preview = AttentionSnapshot(items: [
        .init(id: "1", title: "Fix the login race", place: "studio · api", state: .blocked,
              since: .now.addingTimeInterval(-120), url: URL(string: "herdwick://")!),
        .init(id: "2", title: "Write release notes", place: "studio · docs", state: .done,
              since: .now.addingTimeInterval(-900), url: URL(string: "herdwick://")!),
        .init(id: "3", title: "Profile the sync loop", place: "mini · engine", state: .working,
              since: .now.addingTimeInterval(-300), url: URL(string: "herdwick://")!),
    ], complete: true, updated: .now)
}

extension AttentionSnapshot.Item.State {
    /// The app's colors; orange only ever means "needs you".
    var color: Color {
        switch self {
        case .blocked: .orange
        case .done: .green
        case .working: .blue
        case .idle: .secondary
        }
    }
}

struct AttentionView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: AttentionSnapshot?

    /// Older than this, or with a host missing, what's shown is only what was last seen.
    private var stale: Bool {
        guard let snapshot else { return true }
        return !snapshot.complete || snapshot.updated < .now.addingTimeInterval(-30 * 60)
    }

    private var items: [AttentionSnapshot.Item] { snapshot?.items ?? [] }
    private func count(_ state: AttentionSnapshot.Item.State) -> Int { snapshot?.count(state) ?? 0 }
    private var top: AttentionSnapshot.Item? { items.first }

    var body: some View {
        content
            .widgetURL(top?.url ?? URL(string: "herdwick://")!)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text(summary)
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(summary)
                    .font(.headline)
                    .widgetAccentable()
                if let top, top.state != .idle {
                    Text(top.title).privacySensitive()
                    Text(top.place).foregroundStyle(.secondary).privacySensitive()
                } else {
                    Text(footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: Lock Screen

    /// The most pressing count: needs you, then unread, then running.
    private var circular: some View {
        let state: AttentionSnapshot.Item.State = count(.blocked) > 0 ? .blocked : count(.done) > 0 ? .done : .working
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: state.symbol)
                    .font(.caption)
                Text("\(count(state))")
                    .font(.title3.weight(.semibold))
            }
        }
        .accessibilityLabel(summary)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Three counts at a large size overflow a small widget once any has two digits.
            ViewThatFits(in: .horizontal) {
                counts(font: .title3, spacing: 12)
                counts(font: .headline, spacing: 8)
                counts(font: .footnote, spacing: 6)
            }
            Spacer(minLength: 0)
            if let top {
                VStack(alignment: .leading, spacing: 2) {
                    Label(top.state.label, systemImage: top.state.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(top.state.color)
                    Text(top.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(top.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .privacySensitive()
            } else {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if stale, let snapshot {
                Text("As of \(snapshot.updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Two rows at most: in priority order, so idle agents only fill space nothing else wants.
    /// ViewThatFits takes the first layout whose natural height fits, so nothing clips on a small
    /// phone or at a large text size; the chosen one then spreads over the widget's height.
    private var medium: some View {
        let rows = items.prefix(2)
        return ViewThatFits(in: .vertical) {
            mediumLayout(rows, titleLines: 1)
            mediumLayout(rows.prefix(1), titleLines: 2)
            mediumLayout(rows.prefix(1), titleLines: 1)
            mediumLayout([], titleLines: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumLayout(_ rows: ArraySlice<AttentionSnapshot.Item>, titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                counts(font: .subheadline, spacing: 12)
                    .fixedSize()
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    Text(footnote)
                    Text(shortFootnote)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if items.isEmpty {
                Spacer(minLength: 10)
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(rows) { item in
                    Spacer(minLength: 10)
                    Link(destination: item.url) { row(item, titleLines: titleLines) }
                }
                if rows.count < 2 { Spacer(minLength: 0) }
            }
        }
    }

    /// Icon for the state, then title over "host · session · 2m ago", the age ticking without a reload.
    private func row(_ item: AttentionSnapshot.Item, titleLines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.state.symbol)
                .font(.subheadline)
                .foregroundStyle(item.state.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(item.state == .idle ? .regular : .semibold))
                    .lineLimit(titleLines)
                Group {
                    if let since = item.since {
                        let age = Text(.currentDate, format: Date.AnchoredRelativeFormatStyle(
                            anchor: since, allowedFields: [.minute, .hour, .day],
                            presentation: .numeric, unitsStyle: .narrow))
                        Text("\(item.place) · \(age)")
                    } else {
                        Text(item.place)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.state.label), \(item.title), \(item.place)")
        .privacySensitive()
    }

    /// Needs you, done and working as symbol and number; zero reads secondary.
    private func counts(font: Font.TextStyle, spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            ForEach([AttentionSnapshot.Item.State.blocked, .done, .working], id: \.self) { state in
                let value = count(state)
                Label {
                    Text("\(value)").font(.system(font, design: .rounded).weight(.semibold))
                } icon: {
                    Image(systemName: state.symbol)
                        .font(.system(font))
                        .foregroundStyle(value > 0 ? state.color : .secondary)
                }
                .labelStyle(CountLabelStyle())
                .foregroundStyle(value > 0 ? .primary : .secondary)
                .accessibilityLabel("\(value) \(state.label)")
            }
        }
    }

    // MARK: Text

    private var emptyText: String {
        snapshot == nil ? "Open Herdwick to connect" : stale ? "Nothing seen lately" : "No agents running"
    }

    private var summary: String {
        guard snapshot != nil else { return "Open Herdwick" }
        let blocked = count(.blocked), done = count(.done), working = count(.working)
        let parts = [
            blocked > 0 ? "\(blocked) need\(blocked == 1 ? "s" : "") you" : nil,
            done > 0 ? "\(done) done" : nil,
            working > 0 ? "\(working) working" : nil,
        ].compactMap { $0 }
        if parts.isEmpty { return stale ? "Nothing new seen" : "Nothing needs you" }
        return parts.joined(separator: " · ")
    }

    /// When this was seen, and whether it may be out of date.
    private var footnote: String {
        guard let snapshot else { return "Open Herdwick to connect" }
        let time = snapshot.updated.formatted(date: .omitted, time: .shortened)
        if !snapshot.complete { return "Some hosts offline · \(time)" }
        return stale ? "As of \(time)" : time
    }

    /// The footnote where width is short: the warning kept, the wording cut.
    private var shortFootnote: String {
        guard let snapshot else { return "Open Herdwick" }
        let time = snapshot.updated.formatted(date: .omitted, time: .shortened)
        return snapshot.complete ? time : "Offline · \(time)"
    }
}

/// Icon and number close together, so three counts fit a small widget's width.
private struct CountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
