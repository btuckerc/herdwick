import HerdrAPI
import SwiftUI

extension EnvironmentValues {
    /// Pushes a subagent's read-only transcript; nil where drill-in isn't available.
    @Entry var openSubagent: (@MainActor (SubagentActivity) -> Void)? = nil
}

/// A compact, material tray for workers that have not reached a terminal state.
struct WorkingSubagentsTray: View {
    let activities: [SubagentActivity]
    let onSelect: (SubagentActivity) -> Void

    var body: some View {
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Working now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                ForEach(activities) { activity in
                    Button { onSelect(activity) } label: {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(activity.name).lineLimit(1)
                            if let type = activity.agentType, !type.isEmpty { Text("· \(type)").foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(minLength: 4)
                            if let date = activity.spawnedAt {
                                Text(date, style: .relative).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)
            .background(.regularMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct SubagentResultRow: View {
    let activity: SubagentActivity
    @Environment(\.openSubagent) private var openSubagent
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(color)
                        Text(activity.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let type = activity.agentType, !type.isEmpty { Text("· \(type)").foregroundStyle(.secondary).lineLimit(1) }
                        if let duration = activity.duration { Text("· \(duration)").foregroundStyle(.secondary).font(.caption.monospaced()) }
                    }
                    if let summary = activity.summary, !summary.isEmpty {
                        Text(expanded ? summary : String(summary.prefix { $0 != "\n" }.prefix(120)))
                            .font(.caption)
                            .lineLimit(expanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let openSubagent {
                Button { openSubagent(activity) } label: {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(activity.name)")
            }
        }
        .padding(.vertical, 7)
        .foregroundStyle(isCancelled ? .secondary : .primary)
    }

    private var isCancelled: Bool { if case .cancelled = activity.state { true } else { false } }
    private var symbol: String {
        switch activity.state {
        case .working: "progress.indicator"
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        }
    }
    private var color: Color {
        switch activity.state {
        case .working: .secondary
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

struct SubagentGroupRow: View {
    let activities: [SubagentActivity]
    @Environment(\.openSubagent) private var openSubagent
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(activities) { activity in
                    Button { openSubagent?(activity) } label: {
                        HStack {
                            Image(systemName: statusSymbol(activity.state))
                            Text(activity.name).foregroundStyle(.primary)
                            if let type = activity.agentType { Text("· \(type)").foregroundStyle(.secondary) }
                            Spacer()
                            Text(status(activity.state)).foregroundStyle(.secondary)
                        }.font(.caption)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 5)
        } label: {
            Label(summary, systemImage: "person.2")
                .font(.footnote).foregroundStyle(.secondary)
        }.tint(.secondary)
    }

    private var summary: String { "\(activities.count) subagents · " + (workingCount == 0 ? "all done" : "\(workingCount) working") }

    private var workingCount: Int { activities.filter { if case .working = $0.state { true } else { false } }.count }
    private func status(_ state: SubagentActivity.State) -> String {
        switch state { case .working: "working"; case .completed: "done"; case .failed: "failed"; case .cancelled: "cancelled" }
    }
    private func statusSymbol(_ state: SubagentActivity.State) -> String {
        switch state { case .working: "circle.dotted"; case .completed: "checkmark.circle"; case .failed: "xmark.octagon"; case .cancelled: "stop.circle" }
    }
}

struct SubagentConversationView: View {
    let connection: HostConnection
    let path: String
    let format: TranscriptFormat
    let title: String
    @State private var feed = ConversationFeed()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(ConversationRow.rows(feed.conversation.items,
                                             subagents: { feed.conversation.subagents(spawnedBy: $0) })) { row in row.view }
            }.padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            switch feed.state {
            case .loading: ProgressView()
            // A finished child's file can stop streaming after it loaded; keep what we have.
            case .unavailable where feed.conversation.items.isEmpty:
                ContentUnavailableView("Transcript Not Available", systemImage: "text.document",
                                       description: Text("The subagent finished or was stopped, and its transcript is gone."))
            case .unavailable, .live: EmptyView()
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            guard let client = connection.client else { return }
            await feed.follow(TranscriptLocation(path: path, format: format), client: client)
        }
    }
}
