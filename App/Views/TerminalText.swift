import HerdrAPI
import SwiftUI

/// The pane's loaded output as wrapped plain text: Dynamic Type sized, selectable, readable
/// by VoiceOver, searchable, with web links and image paths tappable. A read-only copy: the
/// host's pane is never scrolled or resized, and nothing typed here reaches it.
struct TerminalText: View {
    let connection: HostConnection
    let paneID: String
    let cwd: String?
    let snapshot: String?
    /// The agent or pane it's from, as its terminal's bar names it (round 63: sb#5, "Output"
    /// alone didn't say whose).
    let title: String
    let receivedAt: Date?

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String]?
    @State private var failure: String?
    @State private var query = ""
    /// When the live copy on screen was read: it's a copy, not a live view (round 62: sb#1, the
    /// footer said what the host keeps, never how old this copy was, and only reopening renewed it).
    @State private var loadedAt: Date?
    @State private var refreshing = false
    /// Why the last Read Again failed, while the older copy stays on screen (round 63: sb#1,
    /// sa#9, a failed reread looked like one that found nothing new).
    @State private var rereadFailure: String?

    /// Lines of output read from the host, oldest first; the screen is the last of them.
    private static let limit = 2000

    var body: some View {
        NavigationStack {
            Group {
                if let lines {
                    content(lines)
                } else if let failure {
                    // Try Again in place: a transient SSH failure needn't mean closing and
                    // reopening (round 41: sb#12).
                    ContentUnavailableView {
                        Label("Couldn't Read the Pane", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") { Task { await retryLoad() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(title)
            .navigationSubtitle("Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if connection.isLive, lines != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Read Again", systemImage: "arrow.clockwise") { Task { await reload() } }
                            .keyboardShortcut("r")
                            .disabled(refreshing)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find in loaded output")
        .modifier(FileLinks(loader: ImageLoader(connection: connection, transcript: nil, cwd: cwd)))
        .task { await load() }
    }

    private func content(_ lines: [String]) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let shown = Array(lines.enumerated()).filter { needle.isEmpty || $0.element.localizedStandardContains(needle) }
        return ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(shown, id: \.offset) { index, line in
                        row(line, match: needle.isEmpty ? nil : { query = ""; Task { @MainActor in proxy.scrollTo(index, anchor: .center) } })
                            .id(index)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                    }
                } footer: {
                    Text(footer(lines.count, matching: shown.count, query: needle))
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
            .refreshable { if connection.isLive { await reload() } }
        }
    }

    /// A line; while searching, a match is a button that opens its place in the whole output
    /// (round 41: sb#11, a tap gesture on text had no button role for VoiceOver or the keyboard).
    /// Otherwise plain selectable text.
    @ViewBuilder private func row(_ line: String, match: (() -> Void)?) -> some View {
        let text = Text(Self.linked(line)).font(.system(.callout, design: .monospaced))
        if let match {
            // A full-size target however short the line (round 65: sb#4, a one-line match was a
            // sliver among the app's 44 pt controls).
            Button(action: match) { text.frame(maxWidth: .infinity, minHeight: Tokens.minTap, alignment: .leading).contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows it in the output")
        } else {
            text.textSelection(.enabled)
        }
    }

    private func retryLoad() async {
        lines = nil
        failure = nil
        await load()
    }

    /// Reads the pane again over the copy on screen, which stays until the new one is in.
    private func reload() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await load()
    }

    private func load() async {
        guard connection.isLive else {
            // A live copy already on screen stays, with its read time, and the reread is said to
            // have failed (round 65: sb#2, the terminal's older frame replaced it, under the newer
            // copy's read time).
            if lines != nil {
                rereadFailed("not connected")
                return
            }
            // No frame kept is said as such, never as an empty "last received" screen (round 38: sb#13).
            var all = (snapshot ?? "").components(separatedBy: "\n")
            while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
            if all.isEmpty { failure = "No output was kept for this pane. It loads when the host is reachable again." }
            else { lines = all }
            return
        }
        guard let client = connection.client, let session = connection.activeSession else {
            if lines == nil { failure = "Not connected." } else { rereadFailed("not connected") }
            return
        }
        do {
            let text = try await client.readPane(paneID, session: session, source: .recent, lines: Self.limit).text
            var all = text.components(separatedBy: "\n")
            while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
            lines = all
            failure = nil
            rereadFailure = nil
            loadedAt = .now
        } catch {
            // A failed reread keeps the copy on screen and says so; a first read shows the failure.
            if lines == nil { failure = error.localizedDescription } else { rereadFailed(error.localizedDescription) }
        }
    }

    /// The copy stays; the footer and VoiceOver say the reread failed, whatever the cause (round
    /// 66: sb#4, a link gone before the read was said only in the footer).
    private func rereadFailed(_ reason: String) {
        rereadFailure = reason
        AccessibilityNotification.Announcement("Couldn't read again. \(reason)").post()
    }

    /// Whose copy it is and how old: a copy read live keeps its read time once the link drops
    /// (round 64: sb#4, it took the terminal's last-received time instead), and a failed reread
    /// is said after the match count while searching too (round 64: sb#3, the count hid it).
    private func footer(_ count: Int, matching matches: Int, query: String) -> String {
        let readAt = loadedAt.map { $0.formatted(date: .omitted, time: .shortened) }
        let state: String
        if let rereadFailure {
            state = "Couldn't read again (\(rereadFailure)). Showing the copy" + (readAt.map { ", read at \($0)" } ?? "") + "."
        } else if !connection.isLive {
            let age = receivedAt.map { AgentRow.age(of: $0, at: .now) }
            let words = readAt.map { "Output read at \($0)" }
                ?? age.map { $0 == "now" ? "Output as of just now" : "Output as of \($0) ago" } ?? "Output as last received"
            state = "\(words). Not connected."
        } else {
            state = "The last \(count) lines the host keeps for this pane" + (readAt.map { ", read at \($0)" } ?? "")
                + ". Pull down or tap Read Again for newer output."
        }
        guard query.isEmpty else { return "\(matches) of \(count) loaded lines match. Tap one to see it in place. \(state)" }
        return state
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Web links open in the browser; image paths, and text paths with a `/`, open the host-file
    /// preview. Other paths stay text: a remote path is never opened as a local file or run.
    static func linked(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        let range = NSRange(line.startIndex..., in: line)
        for match in detector?.matches(in: line, range: range) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
                  let span = Range(match.range, in: line), let target = Range(span, in: result) else { continue }
            result[target].link = url
        }
        var searchStart = line.startIndex
        for word in line.split(whereSeparator: \.isWhitespace) {
            guard let span = line.range(of: word, range: searchStart..<line.endIndex) else { continue }
            searchStart = span.upperBound
            let named = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()[]<>,;:"))
            guard let path = namedFile(named), isImagePath(path) || path.contains("/"), let url = fileLink(path),
                  let pathSpan = line.range(of: named, range: span), let target = Range(pathSpan, in: result),
                  result[target].link == nil else { continue }
            result[target].link = url
        }
        return result
    }
}
