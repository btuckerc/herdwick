import GameController
import SwiftUI
import UIKit

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    /// What VoiceOver calls the field, when more than its placeholder ("Message to Review PR #412").
    var spokenLabel: String? = nil
    let autocorrect: Bool
    let returnKeySends: Bool
    var dismissals = 0
    /// Dictation is under way: Return, ⌘Return and the Send action do nothing; Escape cancels it.
    var sendsBlocked = false
    /// Whether the Send button would send now; VoiceOver's Send action is offered only then
    /// (round 33: it reported success while offline, busy or empty, sending nothing).
    var canSend = true
    var onDictate: () -> Void = {}
    var onCancelDictation: () -> Void = {}
    var handle: ComposerHandle?
    /// Just before the field takes focus, ahead of the keyboard's first frame.
    var onWillFocus: () -> Void = {}
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
        handle?.input = view
        return view
    }

    func updateUIView(_ view: ComposerInput, context: Context) {
        context.coordinator.parent = self
        // Only outside changes (a cleared draft, a demo cue) are pushed in; the view's own
        // edits already match, and writing a stale binding back would drop keystrokes. A
        // clear (a send) also ends any composition, or its text would come back.
        if text != context.coordinator.reported, view.markedTextRange == nil || text.isEmpty {
            if view.markedTextRange != nil { view.unmarkText() }
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
        view.sendsBlocked = sendsBlocked
        view.canSend = canSend
        view.onDictate = onDictate
        view.onCancelDictation = onCancelDictation
        view.onSend = onSend
        handle?.input = view
        view.accessibilityLabel = spokenLabel ?? placeholder
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
        if dismissals != context.coordinator.lastDismissals {
            context.coordinator.lastDismissals = dismissals
            // After this update: resigning inside it asks the hosting view to take first
            // responder, which re-enters the graph update and never returns.
            Task { @MainActor [weak view] in
                if view?.isFirstResponder == true { view?.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerInput, context: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // Six whole lines as TextKit sets them (taller than six `lineHeight`s, which cut the
        // sixth line in half), then it scrolls.
        let cap = ceil((Array(repeating: "X", count: 6).joined(separator: "\n") as NSString)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height)
        let scrolls = height > cap
        if scrolls != uiView.isScrollEnabled {
            uiView.isScrollEnabled = scrolls
            // Held at the caret (the newest line while typing), not wherever enabling left it.
            if scrolls { Task { @MainActor [weak uiView] in uiView?.scrollRangeToVisible(uiView?.selectedRange ?? NSRange()) } }
        }
        return CGSize(width: width, height: min(max(font.lineHeight, height), cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// The last text this view pushed into the binding.
        var reported = ""
        /// The last focus value seen from SwiftUI; UIKit's own editing never moves it.
        var lastFocus = false
        var lastDismissals = 0
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            reported = textView.text
            parent.text = textView.text
            (textView as? ComposerInput)?.placeholder.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            parent.onWillFocus()
            return true
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focus.wrappedValue = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focus.wrappedValue = false }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard parent.returnKeySends, replacement == "\n", textView.markedTextRange == nil,
                  (textView as? ComposerInput)?.insertingLiterally != true else { return true }
            if !parent.sendsBlocked { parent.onSend() }
            return false
        }
    }
}

final class ComposerInput: UITextView {
    var onSend: (() -> Void)?
    var onDictate: (() -> Void)?
    var onCancelDictation: (() -> Void)?
    var sendsBlocked = false
    /// VoiceOver's Send action, there only while the Send button would send.
    var canSend = false {
        didSet {
            guard canSend != oldValue else { return }
            accessibilityCustomActions = canSend ? [UIAccessibilityCustomAction(name: "Send") { [weak self] _ in
                guard let self, self.canSend, !self.sendsBlocked else { return false }
                self.onSend?()
                return true
            }] : []
        }
    }
    var insertingLiterally = false
    let placeholder = UILabel()
    /// The caller's placeholder; a hardware keyboard adds the newline hint to it.
    var basePlaceholder = "" { didSet { updatePlaceholder() } }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        // Darker than the system's placeholder grey (round 19: the light composer's "Message"
        // read as faint as disabled text; round 72: sb#13, at the secondary label's 60 % too).
        placeholder.textColor = Tokens.placeholderText
        addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            // Truncated at the field's edge, not drawn under the mic beside it.
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.widthAnchor),
        ])
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePlaceholder), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Presentation only: key handling never depends on detecting a keyboard. The hint shows
    /// only when it fits whole: a phone-width field cut it to "⇧↩ ne…".
    @objc private func updatePlaceholder() {
        // U+FE0E keeps ↩ a text glyph; without it iOS draws the emoji.
        let hinted = "\(basePlaceholder) · ⇧↩\u{FE0E} new line"
        let fits = bounds.width > 0
            && (hinted as NSString).size(withAttributes: [.font: placeholder.font as Any]).width <= bounds.width
        let text = GCKeyboard.coalesced != nil && fits ? hinted : basePlaceholder
        if placeholder.text != text { placeholder.text = text }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePlaceholder()
    }

    /// Entries for the ⌘-hold overlay and the iPad menu bar. Plain Return is handled in
    /// `pressesBegan`: two key commands on "\r" match unreliably.
    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(sendCommand), input: "\r", modifierFlags: .command)
        let newline = UIKeyCommand(title: "New Line", action: #selector(newlineCommand), input: "\r", modifierFlags: .shift)
        let dictate = UIKeyCommand(title: "Dictate", action: #selector(dictateCommand), input: "d", modifierFlags: [.command, .shift])
        var commands = (super.keyCommands ?? []) + [send, newline, dictate]
        // Only while dictating, so Escape keeps its usual meaning otherwise.
        if sendsBlocked {
            commands.append(UIKeyCommand(title: "Cancel Dictation", action: #selector(cancelDictationCommand), input: UIKeyCommand.inputEscape, modifierFlags: []))
        }
        return commands
    }
    @objc private func sendCommand() { if !sendsBlocked && markedTextRange == nil { onSend?() } }
    @objc private func newlineCommand() { insertLiteralNewline() }
    @objc private func dictateCommand() { onDictate?() }
    @objc private func cancelDictationCommand() { onCancelDictation?() }

    /// Hardware keyboard, whatever the on-screen key does: Return and ⌘Return send;
    /// ⇧Return and ⌥Return break the line.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = returnKey(presses) else { return super.pressesBegan(presses, with: event) }
        if key.modifierFlags.contains(.command) {
            if !sendsBlocked { onSend?() }
        } else if !key.modifierFlags.isDisjoint(with: [.shift, .alternate]) {
            insertLiteralNewline()
        } else if !sendsBlocked {
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

    /// Inserts at the selection as typing would (one undo step), spaced from the words around
    /// it. A composition in progress (marked IME text) is committed first, so the words always
    /// land now, before sending unlocks.
    func insertDictation(_ text: String) {
        guard !text.isEmpty else { return }
        if markedTextRange != nil { unmarkText() }
        guard let selection = selectedTextRange else { return }
        var spaced = text
        if character(from: selection.start, offset: -1).map({ !$0.isWhitespace }) == true { spaced = " " + spaced }
        if character(from: selection.end, offset: 1).map({ !$0.isWhitespace && !$0.isPunctuation }) == true { spaced += " " }
        insertingLiterally = true
        insertText(spaced)
        insertingLiterally = false
    }

    /// The character just before (-1) or after (1) a position, if any.
    private func character(from position: UITextPosition, offset: Int) -> Character? {
        guard let other = self.position(from: position, offset: offset),
              let range = offset < 0 ? textRange(from: other, to: position) : textRange(from: position, to: other) else { return nil }
        return self.text(in: range)?.first
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

/// The composer's field, for writing dictated text at its live selection rather than into
/// a snapshot of the draft. Not observed: setting it never re-renders the composer.
@MainActor final class ComposerHandle {
    weak var input: ComposerInput?
}
