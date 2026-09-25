import SwiftUI
import WidgetKit

@main
struct HerdwickWidgets: WidgetBundle {
    var body: some Widget {
        AttentionWidget()
    }
}

/// Agents that need you, then finished work you haven't read, as Herdwick last saw them.
struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Attention", provider: Provider()) { entry in
            AttentionView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Agents that need you and finished work you haven't read.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: AttentionSnapshot?
}

/// The app reloads widgets when what needs you changes; the timeline itself never guesses.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: AttentionSnapshot(items: [], complete: true, updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: context.isPreview ? Self.preview : AttentionSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: AttentionSnapshot.load())], policy: .never))
    }

    private static let preview = AttentionSnapshot(items: [
        .init(id: "1", title: "Fix the login race", place: "studio · api", state: .blocked, url: URL(string: "herdwick://")!),
        .init(id: "2", title: "Write release notes", place: "studio · docs", state: .done, url: URL(string: "herdwick://")!),
    ], complete: true, updated: .now)
}

struct AttentionView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: AttentionSnapshot?

    /// Older than this, or with a host missing, the counts are only what was last seen.
    private var stale: Bool {
        guard let snapshot else { return true }
        return !snapshot.complete || snapshot.updated < .now.addingTimeInterval(-30 * 60)
    }

    private var blocked: Int { snapshot?.blocked ?? 0 }
    private var done: Int { snapshot?.done ?? 0 }
    private var top: AttentionSnapshot.Item? { snapshot?.items.first }

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
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: blocked > 0 ? "exclamationmark.bubble.fill" : "checkmark.circle")
                        .font(.caption)
                    Text("\(blocked > 0 ? blocked : done)")
                        .font(.title3.weight(.semibold))
                }
            }
            .accessibilityLabel(summary)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(summary)
                    .font(.headline)
                    .widgetAccentable()
                if let top {
                    Text(top.title).privacySensitive()
                    Text(top.place).foregroundStyle(.secondary).privacySensitive()
                } else {
                    Text(footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                count(blocked, "Need you", .orange)
                count(done, "Done", .green)
            }
            Spacer(minLength: 0)
            if let top {
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(top.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .privacySensitive()
            }
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundStyle(value > 0 ? color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if snapshot == nil { return "Open Herdwick" }
        if blocked == 0 && done == 0 { return stale ? "Nothing new seen" : "Nothing needs you" }
        return [blocked > 0 ? "\(blocked) need\(blocked == 1 ? "s" : "") you" : nil, done > 0 ? "\(done) done" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// When the counts were seen, whenever they may be out of date.
    private var footnote: String {
        guard let snapshot else { return "Open Herdwick to connect" }
        let time = snapshot.updated.formatted(date: .omitted, time: .shortened)
        if !snapshot.complete { return "Some hosts offline · \(time)" }
        return stale ? "As of \(time)" : (blocked == 0 && done == 0 ? "All clear · \(time)" : time)
    }
}
