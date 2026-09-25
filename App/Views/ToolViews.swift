import SwiftUI
import HerdrAPI

struct ToolStepView: View {
    let tool: ToolActivity
    @State private var expanded: Bool

    init(tool: ToolActivity, expanded: Bool = false) {
        self.tool = tool
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon).frame(width: 18)
                    titleView
                    Spacer(minLength: 4)
                    stateView
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { detailView }
        }
    }

    private var detail: ToolDetail { tool.detail }

    private var icon: String {
        switch detail {
        case .shell: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .write: "doc.badge.plus"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .todo: "checklist"
        case .task: "person.2"
        case .plan: "list.bullet.clipboard"
        case .generic: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private var titleView: some View {
        switch detail {
        case .shell(let command, _, _): Text(command).font(.caption.monospaced()).lineLimit(1)
        case .read(let path, let range):
            HStack(spacing: 6) { Text("Read \(lastComponent(path))").lineLimit(1); if let range { Text(range).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
        case .edit(let files):
            HStack(spacing: 6) { Text(files.count == 1 ? "Edited \(lastComponent(files[0].path))" : "Edited \(files.count) files"); counts(files) }
        case .write(let path, let content):
            HStack(spacing: 6) { Text("Wrote \(lastComponent(path))"); Text("\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines").font(.caption2).foregroundStyle(.secondary) }
        case .search(let pattern, _, _): Text("Searched \(pattern)")
        case .web(let target, _): Text(target)
        case .todo(let items): Text("Updated plan · \(items.filter { $0.state == .done }.count)/\(items.count) done")
        case .task(let title, _): Text(title)
        case .plan: Text("Plan")
        case .generic: Text(tool.summary)
        }
    }

    @ViewBuilder private var stateView: some View {
        switch tool.state {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
        case .succeeded: EmptyView()
        }
    }

    @ViewBuilder private var detailView: some View {
        switch detail {
        case .shell(let command, let output, let exitCode):
            VStack(alignment: .leading, spacing: 7) {
                codeBlock("$ \(command)")
                if let output { cappedText(output) }
                if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption2.monospaced()).foregroundStyle(.red).padding(.horizontal, 6).padding(.vertical, 3).background(.red.opacity(0.12), in: Capsule()) }
            }
        case .read(let path, _): Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        case .edit(let files): DiffView(files: files)
        case .write(let path, let content):
            VStack(alignment: .leading, spacing: 5) { Text(path).font(.caption2).foregroundStyle(.secondary); cappedText(content, limit: 40) }
        case .search(_, _, let output), .web(_, let output), .task(_, let output), .generic(let output):
            if let output { cappedText(output) }
        case .todo(let items): TodoList(items: items)
        case .plan(let text):
            if let markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { Text(markdown) } else { Text(text) }
        }
    }

    private func codeBlock(_ value: String) -> some View { Text(value).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(9).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10)) }

    private func cappedText(_ text: String, limit: Int = 30) -> some View { OutputBlock(text: text, limit: limit) }

    private func counts(_ files: [FileDiff]) -> some View { HStack(spacing: 4) { Text("+\(files.reduce(0) { $0 + $1.added })").foregroundStyle(.green); Text("−\(files.reduce(0) { $0 + $1.removed })").foregroundStyle(.red) }.font(.caption2.monospaced()) }
}

struct DiffView: View {
    let files: [FileDiff]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in FileDiffView(file: file) }
        }
    }
}

private struct OutputBlock: View {
    let text: String
    let limit: Int
    @State private var showingAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 5) {
            Text((showingAll ? lines : Array(lines.prefix(limit))).joined(separator: "\n"))
                .font(.caption2.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if lines.count > limit && !showingAll {
                Button("Show all \(lines.count) lines") { showingAll = true }.font(.caption)
            }
        }
        .padding(9)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct FileDiffView: View {
    let file: FileDiff
    @State private var showingAll = false
    @State private var width: CGFloat = 0
    var body: some View {
        let visible = showingAll ? file.lines : Array(file.lines.prefix(60))
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(lastComponent(file.path)).font(.caption.weight(.semibold)); if file.change != .modified { Text(file.change == .added ? "New" : "Deleted").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text("+\(file.added)").foregroundStyle(.green); Text("−\(file.removed)").foregroundStyle(.red) }.font(.caption2.monospaced())
            Text(file.path).font(.caption2).foregroundStyle(.secondary)
            let numbered = visible.contains { $0.line != nil }
            ScrollView(.horizontal) { VStack(alignment: .leading, spacing: 0) { ForEach(Array(visible.enumerated()), id: \.offset) { _, line in DiffLineView(line: line, numbered: numbered).frame(minWidth: width, alignment: .leading) } } }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if file.lines.count > 60 && !showingAll { Button("Show all") { showingAll = true }.font(.caption) }
        }.padding(9).background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let numbered: Bool
    var body: some View {
        if line.kind == .gap { Text("⋯").font(.caption2.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 2) }
        else {
            let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
            HStack(spacing: 5) {
                if numbered { Text(line.line.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(.tertiary) }
                Text(marker); Text(line.text)
            }
            .font(.caption2.monospaced()).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .added ? Color.green.opacity(0.12) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
        }
    }
}

struct TodoList: View {
    let items: [TodoItem]
    var body: some View { VStack(alignment: .leading, spacing: 7) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: symbol(item.state)).foregroundStyle(color(item.state)); Text(item.text).font(item.state == .active ? .body.weight(.semibold) : .body).foregroundStyle(item.state == .done ? .secondary : .primary).strikethrough(item.state == .done) } } } }
    private func symbol(_ state: TodoItem.State) -> String { switch state { case .pending: "circle"; case .active: "circle.inset.filled"; case .done: "checkmark.circle.fill" } }
    private func color(_ state: TodoItem.State) -> Color { switch state { case .pending: .secondary; case .active: .accentColor; case .done: .green } }
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
