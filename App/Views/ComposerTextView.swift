import GameController
import SwiftUI
import UIKit

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    let autocorrect: Bool
    let returnKeySends: Bool
    let onSend: () -> Void

    func makeUIView(context: Context) -> ComposerInput {
        let view = ComposerInput()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.delegate = context.coordinator
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerInput, context: Context) {
        context.coordinator.parent = self
        // Only outside changes (a cleared draft, a demo cue) are pushed in; the view's own
        // edits already match, and writing a stale binding back would drop keystrokes.
        if text != context.coordinator.reported, view.markedTextRange == nil {
            view.text = text
            context.coordinator.reported = text
        }
        view.autocorrectionType = autocorrect ? .default : .no
        view.autocapitalizationType = autocorrect ? .sentences : .none
        let key: UIReturnKeyType = returnKeySends ? .send : .default
        if view.returnKeyType != key {
            view.returnKeyType = key
            if view.isFirstResponder { view.reloadInputViews() }
        }
        view.onSend = onSend
        view.accessibilityLabel = placeholder
        view.basePlaceholder = placeholder
        view.placeholder.isHidden = !view.text.isEmpty
        // Follow only changes the caller makes. A FocusState with no `.focused` view reads
        // false while UIKit is editing, so comparing levels would drop the keyboard mid-typing.
        let wanted = focus.wrappedValue
        if wanted != context.coordinator.lastFocus {
            context.coordinator.lastFocus = wanted
            if wanted && !view.isFirstResponder { view.becomeFirstResponder() }
            if !wanted && view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerInput, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        uiView.isScrollEnabled = height > line * 6
        return CGSize(width: width, height: min(max(line, height), line * 6))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// The last text this view pushed into the binding.
        var reported = ""
        /// The last focus value seen from SwiftUI; UIKit's own editing never moves it.
        var lastFocus = false
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            reported = textView.text
            parent.text = textView.text
            (textView as? ComposerInput)?.placeholder.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focus.wrappedValue = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focus.wrappedValue = false }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard parent.returnKeySends, replacement == "\n", textView.markedTextRange == nil,
                  (textView as? ComposerInput)?.insertingLiterally != true else { return true }
            parent.onSend()
            return false
        }
    }
}

final class ComposerInput: UITextView {
    var onSend: (() -> Void)?
    var insertingLiterally = false
    let placeholder = UILabel()
    /// The caller's placeholder; a hardware keyboard adds the newline hint to it.
    var basePlaceholder = "" { didSet { updatePlaceholder() } }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .placeholderText
        addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
        ])
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePlaceholder), name: name, object: nil)
        }
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Send") { [weak self] _ in
            self?.onSend?()
            return true
        }]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Presentation only: key handling never depends on detecting a keyboard.
    @objc private func updatePlaceholder() {
        // U+FE0E keeps ↩ a text glyph; without it iOS draws the emoji.
        placeholder.text = GCKeyboard.coalesced == nil ? basePlaceholder : "\(basePlaceholder) · ⇧↩\u{FE0E} new line"
    }

    /// Entries for the ⌘-hold overlay and the iPad menu bar. Plain Return is handled in
    /// `pressesBegan`: two key commands on "\r" match unreliably.
    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(sendCommand), input: "\r", modifierFlags: .command)
        let newline = UIKeyCommand(title: "New Line", action: #selector(newlineCommand), input: "\r", modifierFlags: .shift)
        return (super.keyCommands ?? []) + [send, newline]
    }
    @objc private func sendCommand() { onSend?() }
    @objc private func newlineCommand() { insertLiteralNewline() }

    /// Hardware keyboard, whatever the on-screen key does: Return and ⌘Return send;
    /// ⇧Return and ⌥Return break the line.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = returnKey(presses) else { return super.pressesBegan(presses, with: event) }
        if key.modifierFlags.contains(.command) {
            onSend?()
        } else if !key.modifierFlags.isDisjoint(with: [.shift, .alternate]) {
            insertLiteralNewline()
        } else {
            onSend?()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if returnKey(presses) != nil { return }
        super.pressesEnded(presses, with: event)
    }

    /// A Return press this view handles itself; nil for anything else, including Return
    /// that confirms marked (IME) text.
    private func returnKey(_ presses: Set<UIPress>) -> UIKey? {
        guard markedTextRange == nil, let key = presses.first?.key,
              key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
              key.modifierFlags.subtracting([.shift, .alternate, .command, .numericPad]).isEmpty else { return nil }
        return key
    }

    private func insertLiteralNewline() {
        insertingLiterally = true
        insertText("\n")
        insertingLiterally = false
    }

    override func paste(_ sender: Any?) {
        insertingLiterally = true
        defer { insertingLiterally = false }
        super.paste(sender)
    }
}
