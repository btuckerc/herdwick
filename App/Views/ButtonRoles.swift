import GameController
import SwiftUI

/// The app's button vocabulary, by where a button sits. Toolbar items, menus, list rows and
/// NavigationLinks keep their system styles; everything else picks one of these, so two
/// buttons doing the same kind of job look the same everywhere.
///
/// - Floating control: glass, over content (composer +, dock, key bar keys, host chips,
///   New Activity). Capsule, or a 44-pt circle for an icon.
/// - Primary action: the one commit action of a sheet, card or empty state (also a selected
///   host chip). Prominent glass capsule. Never destructive (destructive actions confirm in an
///   alert). The label takes the background colour: the dark-mode accent is a light sage that
///   white text doesn't read on.
/// - Choice: an option on a content card (ask options, approval rows). Not glass (cards are
///   content), full width, rounded rectangle so a two-line label stays legible. Neutral, or
///   accent-tinted for the agent's own recommendation.
/// - Inline action: a text action inside content ("Write Your Own Answer…", "Show all lines").
extension View {
    func floatingControl(_ shape: ButtonBorderShape = .capsule) -> some View {
        buttonStyle(.glass).buttonBorderShape(shape)
    }

    /// `shape` here, not a later `.buttonBorderShape`: the innermost one wins.
    func primaryAction(_ shape: ButtonBorderShape = .capsule) -> some View {
        buttonStyle(.glassProminent).buttonBorderShape(shape)
            .foregroundStyle(Color(uiColor: .systemBackground))
    }

    /// `recommended` only for an option the agent itself marked so; approval rows never. Both
    /// are `ChoiceStyle`: primary words on the inset surface inside a hairline, the
    /// recommendation's in the accent over a faint accent wash, and the cards say
    /// "Recommended" on it in the accent (round 6: a tint alone, beside a filled Approve, read
    /// as disabled; round 11: a lone tinted option read as chosen; round 28: a green fill under
    /// green words read muddy; round 29: the neutral grey fill, darker than its card in the
    /// light, read as disabled or pressed; round 62: opus#6, `.bordered`'s grey on the grey
    /// card still read as disabled in the dark, Deny the faintest control in the app).
    func choiceButton(recommended: Bool = false) -> some View {
        buttonStyle(ChoiceStyle(recommended: recommended))
    }

    func inlineAction() -> some View {
        buttonStyle(.borderless).font(.subheadline.weight(.medium))
    }

    /// ⌘1…⌘9 on the choices of the prompt on screen, in the order shown (Approve ⌘1, Deny ⌘2),
    /// so a hardware keyboard answers without reaching for the screen (round 7). Past nine, none.
    /// The label says it with a `ShortcutHint`.
    @ViewBuilder func numberedShortcut(_ index: Int?) -> some View {
        if let index, (0..<9).contains(index) {
            keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        } else {
            self
        }
    }
}

/// A choice on a card (`choiceButton(recommended:)`): primary words on the inset surface, a
/// step off the card in both appearances, inside a hairline, padded as `.bordered` pads,
/// dimmed while pressed. The agent's recommendation washes faintly in the accent inside an
/// accent hairline (round 51: sa#4, on the plain inset it read as one more grey plate in the
/// card; round 28: a strong green fill under green words read muddy, so 10 % under primary
/// words). Disabled, its words go secondary and the hairline neutral, the wash gone, still
/// readable (round 44: sa#3, sb#3, faded whole and dimmed again by Select mode, the words sank
/// near the background).
struct ChoiceStyle: ButtonStyle {
    let recommended: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.choice)
        let accent = recommended && isEnabled
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Tokens.secondaryText)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, 7)
            .background {
                shape.fill(Tokens.Surface.inset)
                shape.fill(Tokens.Tint.onAttention.opacity(accent ? 0.1 : 0))
            }
            .overlay {
                shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                shape.strokeBorder(accent ? Tokens.Tint.onAttention.opacity(0.8) : Color.secondary.opacity(isEnabled ? 0.45 : 0.4), lineWidth: 1)
            }
            .contentShape([.interaction, .hoverEffect], shape)
            .hoverEffect(.highlight)
    }
}

/// A button's key equivalent as part of its label, at its trailing end a level quieter than the
/// label, as a menu item's is, only while a hardware keyboard is attached: a choice's ⌘-number
/// (pass what `numberedShortcut` gets) or a named key ("⌘↩"). Round 25: the shortcuts and the
/// card owning them were invisible; round 26: drawn as a badge hanging off the button's corner
/// it read as a debug annotation and covered the label at accessibility sizes. Not at
/// accessibility sizes, where it took a word's width from every line of the label (round 33);
/// the key still works.
struct ShortcutHint: View {
    let key: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ index: Int?) { key = index.flatMap { (0..<9).contains($0) ? "⌘\($0 + 1)" : nil } }
    init(key: String) { self.key = key }

    var body: some View {
        if let key, HardwareKeyboard.shared.connected, !typeSize.isAccessibilitySize {
            // `.secondary` of the label's own colour: legible on a filled Approve as on grey.
            Text(key)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

/// Whether a hardware keyboard is attached, for hints that only it can use.
@MainActor @Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()
    private(set) var connected = GCKeyboard.coalesced != nil

    private init() {
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HardwareKeyboard.shared.connected = GCKeyboard.coalesced != nil }
            }
        }
    }
}
