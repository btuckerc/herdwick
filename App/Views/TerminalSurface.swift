import HerdrAPI
import SwiftTerm
import SwiftUI
import UIKit

/// Owns one SwiftTerm view and the herdr stream feeding it. Survives SwiftUI
/// re-renders; the stream is reopened on reconnect, resize (read-only mode) or
/// when the user switches between reading and typing.
@MainActor @Observable
final class TerminalController {
    /// The grid that fits the view with the current font; herdr renders at this size.
    private(set) var grid: Grid?
    private(set) var closedReason: String?
    private(set) var hasFrame = false

    struct Grid: Hashable {
        var cols: Int
        var rows: Int
    }

    @ObservationIgnored let view = HerdwickTerminalView(frame: .zero)
    @ObservationIgnored private var session: TerminalSession?
    @ObservationIgnored private let bridge = DelegateBridge()

    init() {
        view.terminalDelegate = bridge
        bridge.onSize = { [weak self] cols, rows in self?.sizeChanged(cols: cols, rows: rows) }
        bridge.onInput = { [weak self] bytes in self?.forward(bytes) }
        view.allowMouseReporting = false
        view.optionAsMetaKey = true
        view.changeScrollback(nil)
    }

    func apply(theme: TerminalTheme, font: TerminalFont, size: Double) {
        view.font = font.uiFont(size: size)
        view.nativeBackgroundColor = UIColor(hex: theme.background)
        view.nativeForegroundColor = UIColor(hex: theme.foreground)
        view.caretColor = UIColor(hex: theme.cursor)
        view.selectedTextBackgroundColor = UIColor(hex: theme.selection)
        view.installColors(theme.ansi.map { hex in
            SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xFF), green8: UInt16((hex >> 8) & 0xFF), blue8: UInt16(hex & 0xFF))
        })
        view.keyboardAppearance = theme.isDark ? .dark : .light
        view.backgroundColor = UIColor(hex: theme.background)
    }

    /// Streams the pane until cancelled or the stream ends. `control` takes input
    /// ownership, which also resizes the pane to this grid on the host.
    func run(client: HerdrClient, session: String, pane: String, control: Bool) async {
        guard let grid else { return }
        closedReason = nil
        view.acceptsKeyboard = control
        do {
            let stream = try await client.terminal(pane: pane, session: session, cols: grid.cols, rows: grid.rows, control: control)
            self.session = stream
            defer {
                self.session = nil
                Task { await stream.close() }
            }
            for try await message in stream.messages {
                switch message {
                case .frame(let frame):
                    view.feed(byteArray: frame.bytes[...])
                    hasFrame = true
                case .closed(let reason):
                    closedReason = reason ?? "The pane closed."
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            // A dropped transport is handled by the connection; the view reopens on reconnect.
        }
        if !Task.isCancelled { view.acceptsKeyboard = false }
    }

    private func sizeChanged(cols: Int, rows: Int) {
        let next = Grid(cols: cols, rows: rows)
        guard next != grid, cols > 4, rows > 2 else { return }
        grid = next
        if let session, view.acceptsKeyboard {
            Task { try? await session.send(.resize(cols: cols, rows: rows)) }
        }
    }

    private func forward(_ bytes: [UInt8]) {
        guard let session else { return }
        Task { try? await session.send(.bytes(bytes)) }
    }

    func focusKeyboard() {
        _ = view.becomeFirstResponder()
    }
}

/// SwiftTerm view that only raises the keyboard while the user is typing into the pane.
final class HerdwickTerminalView: TerminalView {
    var acceptsKeyboard = false {
        didSet { if !acceptsKeyboard, isFirstResponder { _ = resignFirstResponder() } }
    }

    override var canBecomeFirstResponder: Bool { acceptsKeyboard }
}

/// SwiftTerm's delegate is a class protocol; this keeps the controller free of UIKit plumbing.
private final class DelegateBridge: NSObject, TerminalViewDelegate {
    var onSize: ((Int, Int) -> Void)?
    var onInput: (([UInt8]) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onSize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput?(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        // SwiftTerm's UIKit view calls its delegate on the main thread.
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalSurface: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> HerdwickTerminalView { controller.view }
    func updateUIView(_ view: HerdwickTerminalView, context: Context) {}
}
