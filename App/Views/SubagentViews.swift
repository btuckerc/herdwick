import HerdrAPI
import SwiftUI

extension EnvironmentValues {
    /// Pushes a subagent's read-only transcript; nil where drill-in isn't available.
    @Entry var openSubagent: EnvironmentAction<SubagentActivity, Void>? = nil
    /// This conversation's subagent with the given id (an `agent://` peer), if any.
    @Entry var subagentNamed: EnvironmentAction<String, SubagentActivity?>? = nil
}

/// A subagent's result: "BenchCouncil finished · 2m05s" over two lines of what it said.
/// `brief`: what this agent last asked it, shown when the result is opened.
struct SubagentResultRow: View {
    let activity: SubagentActivity
    var brief: String? = nil

    var body: some View {
        AgentMessage(title: [activity.name + " " + state, activity.duration].compactMap { $0 }.joined(separator: " · "),
                     peer: activity.name, failed: failed, text: activity.summary ?? "", brief: brief, activity: activity)
    }

    private var failed: Bool { if case .failed = activity.state { true } else { false } }
    private var state: String {
        switch activity.state {
        case .working: "working"
        case .completed: "finished"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}

/// The call that spawned subagents: how many and how many still work; open it for each one.
struct SubagentGroupRow: View {
    let activities: [SubagentActivity]
    @Environment(\.openSubagent) private var openSubagent
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(activities) { activity in
                    QuietHeader(action: openSubagent.map { open in { open(activity) } }) {
                        Text([activity.name, activity.agentType, status(activity.state)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
            }
        } label: {
            Text(summary)
        }
        .disclosureGroupStyle(QuietDisclosure())
    }

    private var summary: String { "\(activities.count) subagents · " + (workingCount == 0 ? "all done" : "\(workingCount) working") }

    private var workingCount: Int { activities.filter { if case .working = $0.state { true } else { false } }.count }
    private func status(_ state: SubagentActivity.State) -> String {
        switch state { case .working: "working"; case .completed: "done"; case .failed: "failed"; case .cancelled: "cancelled" }
    }
}

struct SubagentConversationView: View {
    let connection: HostConnection
    let path: String
    let format: TranscriptFormat
    let title: String
    @State private var feed = ConversationFeed()
    @State private var previewing: ImagePreviewSource?
    @State private var photoSaver = PhotoSaver()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(ConversationRow.rows(feed.conversation.items, answered: feed.conversation.items.answeredBriefs(),
                                             subagents: { feed.conversation.subagents(spawnedBy: $0) })) { row in row.view }
            }.padding(16)
        }
        .environment(\.previewImage, EnvironmentAction { previewing = $0 })
        .modifier(SavesPhotos(saver: photoSaver))
        .environment(\.imageLoader, ImageLoader(connection: connection, transcript: path))
        .sheet(item: $previewing) { ImagePreview(source: $0, loader: ImageLoader(connection: connection, transcript: path)) }
        .modifier(FileLinks(loader: ImageLoader(connection: connection, transcript: path)) { [feed] name in
            feed.conversation.touchedFile(name)
        })
        .defaultScrollAnchor(.bottom)
        .overlay {
            switch feed.state {
            case .loading: if !connection.isConnecting { ProgressView() }
            // A finished child's file can stop streaming after it loaded; keep what we have.
            case .unavailable where feed.conversation.items.isEmpty:
                ContentUnavailableView("Transcript Not Available", systemImage: "text.document",
                                       description: Text("The agent finished or was stopped, and its transcript is gone."))
            case .unavailable, .live: EmptyView()
            }
        }
        .connectingBadge(connection)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: ChildFeedKey(liveID: connection.liveID, path: path, format: format)) {
            while !Task.isCancelled, connection.isLive, let client = connection.client {
                await feed.follow(TranscriptLocation(path: path, format: format), client: client)
                guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            }
        }
    }
}

private struct ChildFeedKey: Hashable {
    let liveID: Int
    let path: String
    let format: TranscriptFormat
}
