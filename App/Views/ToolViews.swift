import SwiftUI
import HerdrAPI

struct ToolStepView: View {
    let tool: ToolActivity
    @State private var expanded: Bool
    @Environment(\.previewImage) private var previewImage
    @Environment(\.inlineImages) private var inlineImages

    init(tool: ToolActivity, expanded: Bool = false) {
        self.tool = tool
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        // Parsed once per update: it decodes the call's JSON and, for edits, builds the diff.
        let detail = tool.detail
        VStack(alignment: .leading, spacing: 6) {
            QuietHeader(isExpanded: expanded, action: opens(detail) ? { expanded.toggle() } : nil) { title(detail) }
                .accessibilityHint(tool.images.isEmpty || inlineImages || expanded ? "" : "Shows the images")
            // The row is the images' disclosure, so no separate "Image" label; Full shows them as is.
            if !tool.images.isEmpty, inlineImages || expanded {
                TranscriptImages(images: tool.images).environment(\.inlineImages, true)
            }
            if expanded { detailView(detail) }
        }
    }

    /// A call with nothing behind its line yet (a wait still waiting) gets no chevron.
    private func opens(_ detail: ToolDetail) -> Bool {
        if !tool.images.isEmpty { return true }
        if case .generic(let output) = detail { return output != nil }
        return true
    }

    /// What the call did, in words; commands read as themselves. A failure says so in red.
    private func title(_ detail: ToolDetail) -> Text {
        if tool.state == .running { return Text("\(tool.runningTitle)…") }
        let text: Text = switch detail {
        case .shell(let command, _, _): Text(command)
        case .read(let path, let range): Text(["Read \(lastComponent(path))", range].compactMap { $0 }.joined(separator: " · "))
        case .edit(let files): Text(Self.edited(files))
        case .write(let path, let content):
            Text("Wrote \(lastComponent(path)) · \(Self.lines(content))")
        case .search(let pattern, _, _): Text("Searched \(pattern)")
        case .web(let target, _): Text(target)
        case .todo(let items): Text("Updated plan · \(items.filter { $0.state == .done }.count)/\(items.count) done")
        case .task(let title, _): Text(title)
        case .plan: Text("Plan")
        case .generic: Text(tool.title)
        }
        return tool.state == .failed ? Text("Failed: \(text)").foregroundStyle(.red) : text
    }

    @ViewBuilder private func detailView(_ detail: ToolDetail) -> some View {
        switch detail {
        case .shell(let command, let output, let exitCode):
            // The line cuts a long command; opened, it reads whole.
            if command.contains("\n") || command.count > 40 {
                Text(command).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let output { OutputBlock(text: output) }
            if let exitCode, exitCode != 0 { Text("Exit \(exitCode)").font(.subheadline).foregroundStyle(.red) }
        case .read(let path, _):
            if tool.images.isEmpty, isImagePath(path), let previewImage {
                Button(path) { previewImage(.file(path)) }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            } else if isTextPath(path), let url = fileLink(path) {
                Link(path, destination: url).font(.subheadline)
            } else {
                Text(path).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .edit(let files): DiffView(files: files)
        case .write(let path, let content):
            Text(path).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            OutputBlock(text: content)
        case .search(_, _, let output), .web(_, let output), .task(_, let output), .generic(let output):
            if let output { OutputBlock(text: output) }
        case .todo(let items): TodoList(items: items)
        case .plan(let text):
            MarkdownText(text: text)
        }
    }

    private static func lines(_ text: String) -> String {
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return count == 1 ? "1 line" : "\(count) lines"
    }

    private static func edited(_ files: [FileDiff]) -> String {
        let name = files.count == 1 ? lastComponent(files[0].path) : "\(files.count) files"
        return "Edited \(name) · +\(files.reduce(0) { $0 + $1.added }) −\(files.reduce(0) { $0 + $1.removed })"
    }
}

struct DiffView: View {
    let files: [FileDiff]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One file's counts are already on the step's line.
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in FileDiffView(file: file, counts: files.count > 1) }
        }
    }
}

/// Every recorded edit and file write, by file, newest first. Only what the tools recorded in
/// the loaded history: never a net diff, and a shell's own changes aren't here.
struct ChangesSheet: View {
    let edits: [RecordedEdit]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(edits) { edit in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(edit.tools, id: \.id) { tool in RecordedChange(tool: tool, path: edit.path) }
                            }
                            .padding(.bottom, 10)
                        } label: {
                            Text("\(lastComponent(edit.path)) · \(edit.tools.count == 1 ? "1 edit" : "\(edit.tools.count) edits")")
                        }
                        .disclosureGroupStyle(QuietDisclosure())
                    }
                }
                .padding(16)
            }
            .navigationTitle("Recorded Edits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// One call's change to one file: its diff, or what it wrote.
private struct RecordedChange: View {
    let tool: ToolActivity
    let path: String

    var body: some View {
        switch tool.detail {
        case .edit(let files):
            ForEach(Array(files.filter { $0.path == path }.enumerated()), id: \.offset) { _, file in FileDiffView(file: file, counts: true) }
        case .write(_, let content):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(path) · Written").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                OutputBlock(text: content)
            }
        default:
            Text(tool.title).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Literal output: monospaced, unboxed, in a box that scrolls by itself past a few dozen
/// lines. Only a huge output is cut, until asked.
private struct OutputBlock: View {
    let text: String
    @State private var showingAll = false
    private static let rendered = 500

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            CappedScroll {
                Text(showingAll || lines.count <= Self.rendered ? text : lines.prefix(Self.rendered).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if lines.count > Self.rendered && !showingAll {
                Button("Show all \(lines.count) lines") { showingAll = true }.font(.subheadline).buttonStyle(.borderless)
            }
        }
    }
}

/// Content at its own height up to `maxHeight`, then scrolling inside that box: a long diff or
/// output stays visible without pushing the step's and run's headers out of reach. Its bottom
/// fades while more is below, so a cut at a line's edge doesn't read as the end.
struct CappedScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    var maxHeight: CGFloat = 320
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0
    @State private var more = false

    var body: some View {
        ScrollView(axes) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(.hidden, axes: .horizontal)
        .scrollIndicatorsFlash(trigger: height > maxHeight)
        .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY < $0.contentSize.height - 1 } action: { more = $1 }
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: more ? 36 : 0)
            }
        }
    }
}

private struct FileDiffView: View {
    let file: FileDiff
    let counts: Bool
    @State private var width: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let change = file.change == .modified ? "" : file.change == .added ? " · New" : " · Deleted"
            Text(file.path + change + (counts ? " · +\(file.added) −\(file.removed)" : ""))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            let numbered = file.lines.contains { $0.line != nil }
            CappedScroll(axes: [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines.indices, id: \.self) { DiffLineView(line: file.lines[$0], numbered: numbered).frame(minWidth: width, alignment: .leading) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let numbered: Bool
    var body: some View {
        if line.kind == .gap { Text("⋯").font(.caption.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 2) }
        else {
            let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
            HStack(spacing: 5) {
                if numbered { Text(line.line.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(.tertiary) }
                Text(marker); Text(line.text)
            }
            .font(.caption.monospaced()).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .added ? Color.green.opacity(0.12) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
        }
    }
}

struct TodoList: View {
    let items: [TodoItem]
    var body: some View { VStack(alignment: .leading, spacing: 7) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: symbol(item.state)).foregroundStyle(color(item.state)); Text(item.text).font(item.state == .active ? .body.weight(.semibold) : .body).foregroundStyle(item.state == .done ? .secondary : .primary).strikethrough(item.state == .done) } } } }
    private func symbol(_ state: TodoItem.State) -> String { switch state { case .pending: "circle"; case .active: "circle.inset.filled"; case .done: "checkmark.circle.fill" } }
    private func color(_ state: TodoItem.State) -> Color { switch state { case .pending, .done: .secondary; case .active: .accentColor } }
}

struct TodoCard: View {
    let tool: ToolActivity
    @ViewBuilder var body: some View {
        if case .todo(let items) = tool.detail {
            VStack(alignment: .leading, spacing: 9) { Text("Plan · \(items.filter { $0.state == .done }.count) of \(items.count) done").font(.caption.weight(.semibold)).foregroundStyle(.secondary); TodoList(items: items) }.padding(14).background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
        } else { EmptyView() }
    }
}

extension ToolActivity { var isTodo: Bool { if case .todo = detail { true } else { false } } }

private func lastComponent(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
