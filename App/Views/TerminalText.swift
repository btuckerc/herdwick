import HerdrAPI
import SwiftUI

/// The pane's loaded output as wrapped plain text: Dynamic Type sized, selectable, readable
/// by VoiceOver, searchable, with web links and image paths tappable. A read-only copy: the
/// host's pane is never scrolled or resized, and nothing typed here reaches it.
struct TerminalText: View {
    let connection: HostConnection
    let paneID: String
    let cwd: String?

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String]?
    @State private var failure: String?
    @State private var query = ""
    @State private var previewing: ImagePreviewSource?

    /// Lines of output read from the host, oldest first; the screen is the last of them.
    private static let limit = 2000

    var body: some View {
        NavigationStack {
            Group {
                if let lines {
                    content(lines)
                } else if let failure {
                    ContentUnavailableView("Couldn't Read the Pane", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .searchable(text: $query, prompt: "Find in loaded output")
        .environment(\.openURL, OpenURLAction { url in
            guard let path = imageLinkPath(url) else { return .systemAction }
            previewing = .file(path)
            return .handled
        })
        .sheet(item: $previewing) {
            ImagePreview(source: $0, loader: ImageLoader(connection: connection, transcript: nil), cwd: cwd)
        }
        .task { await load() }
    }

    private func content(_ lines: [String]) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let shown = Array(lines.enumerated()).filter { needle.isEmpty || $0.element.localizedStandardContains(needle) }
        return ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(shown, id: \.offset) { index, line in
                        Text(Self.linked(line))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                            .onTapGesture {
                                // A match opens its place in the whole output.
                                guard !needle.isEmpty else { return }
                                query = ""
                                Task { @MainActor in proxy.scrollTo(index, anchor: .center) }
                            }
                    }
                } footer: {
                    Text(needle.isEmpty
                         ? "The last \(lines.count) lines the host keeps for this pane."
                         : "\(shown.count) of \(lines.count) loaded lines match. Tap one to see it in place.")
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
        }
    }

    private func load() async {
        guard let client = connection.client, let session = connection.activeSession else {
            failure = "Not connected."
            return
        }
        do {
            let text = try await client.readPane(paneID, session: session, source: .recent, lines: Self.limit).text
            var all = text.components(separatedBy: "\n")
            while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
            lines = all
        } catch {
            failure = error.localizedDescription
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Web links open in the browser; image paths open the host-file preview. Other paths stay
    /// text: a remote path is never opened as a local file or run.
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
            let path = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()[]<>,;:"))
            guard isImagePath(path), !path.contains("://"), let url = imageLink(path),
                  let pathSpan = line.range(of: path, range: span), let target = Range(pathSpan, in: result),
                  result[target].link == nil else { continue }
            result[target].link = url
        }
        return result
    }
}
