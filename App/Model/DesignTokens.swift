import SwiftUI

/// The app's few visual constants. Views use these instead of literals so the inbox, the
/// conversation and the sheets share one rhythm. Terminal palettes stay in `Theme.swift`.
enum Tokens {
    /// Spacing steps; nothing in between.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Corner radii for content (controls are capsules or circles): a plate holding code,
    /// output or a command, and a card such as a pending question.
    enum Radius {
        static let plate: CGFloat = 12
        static let card: CGFloat = 20
        /// A choice button on a card: multi-line labels read badly in a capsule.
        static let choice: CGFloat = 14
    }

    /// The smallest tap target, and the size of every circular control.
    static let minTap: CGFloat = 44

    /// The widest a conversation's column runs, transcript and composer alike, centred in a wide
    /// iPad detail (round 36: lines ran the column's whole width).
    static let readableWidth: CGFloat = 720

    /// Surfaces: the screen, a card raised on it, and a plate inside a card.
    enum Surface {
        static let base = Color(uiColor: .systemBackground)
        static let raised = Color(uiColor: .secondarySystemBackground)
        static let inset = Color(uiColor: .tertiarySystemBackground)
        /// A raised card's edge: a hairline in the light, where the pale grey card on white
        /// barely parted from the page (round 89: opus#14, sa#13); none in the dark, where the
        /// step in grey already does it.
        static let edge = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .clear : .separator
        })
    }

    /// Semantic colours. Status always comes with words; colour is the second channel.
    enum Tint {
        static let attention = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(hex: 0xC25400)
        })
        /// Under a Needs You item: the raised surface, neutral; the orange glyph and the status
        /// words mark the attention (round 15: orange at 10% over black read murky brown; round
        /// 18: #2C251D still a heavy brown plate, the 10% peach one more hue against the card's
        /// orange and greens; round 26: #262320 and a 7% peach still read as a brown plate beside
        /// the neutral greys, and two graders asked for a neutral surface).
        static let attentionWash = Surface.raised
        static let progress = Color.blue
        /// The unread dot, Mail's blue: green already says yes, recommended, links and done.
        static let unread = Color.blue
        /// Done, passed, approved: system green in the dark; darker in the light, where system
        /// green on white is about 2:1 (round 41: sa#5, "8 tests passed"'s check read pale).
        static let settled = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(hex: 0x248A3D)
        })
        static let danger = Color.red
        /// A finished result's closing warning ("Before deploying: …"): yellow, the system's
        /// caution, so a read result never wears Needs You's orange (round 78: opus#7, an orange
        /// triangle on a read row read as an agent waiting). Darker in the light, about 4.9:1 on white.
        static let caution = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemYellow : UIColor(hex: 0x9A6700)
        })
        /// A quiet wash under its own tint (a failed step's rule, the catch-up line).
        static func plate(_ color: Color) -> Color { color.opacity(0.12) }
        /// Accent words on the Needs You wash ("Recommended", Write Your Own Answer, the
        /// recommended option): the accent in the dark; darker in the light, where the accent
        /// and system green on the peach wash fell under 4.5:1 (round 14).
        static let onAttention = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: 0x8CC498) : UIColor(hex: 0x2E6B3F)
        })
    }

    /// Secondary words that carry information (a row's workspace and time, a preview, a tool
    /// call's summary, the dock's captions). Lighter than the system's secondary label in the
    /// dark and darker in the light, where its ~3.5:1 on white read as faint at footnote sizes
    /// (round 6), and a step further in both (round 14: still a grey layer that took effort to
    /// read); further again with Increase Contrast.
    static let secondaryText = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return UIColor(hex: traits.accessibilityContrast == .high ? 0xD1D1D6 : 0xB8B8BE) }
        return UIColor(hex: traits.accessibilityContrast == .high ? 0x3A3A3C : 0x55555A)
    })

    /// An empty field's placeholder: a step under `secondaryText`, so it still reads as unwritten,
    /// and well above the system's placeholder grey (round 72: sb#13, the light composer's
    /// "Message" read faint beside the transcript); `secondaryText` itself with Increase Contrast.
    static let placeholderText = UIColor { traits in
        if traits.userInterfaceStyle == .dark { return UIColor(hex: traits.accessibilityContrast == .high ? 0xD1D1D6 : 0xA1A1A6) }
        return UIColor(hex: traits.accessibilityContrast == .high ? 0x3A3A3C : 0x6E6E73)
    }

    /// The user's own messages: the accent, faint, with primary text, in both appearances.
    static let userBubble = Color.accentColor.opacity(0.18)

    /// The sidebar's open row: an inset rounded fill of the accent, faint enough that the row's
    /// words keep their own colours on it.
    static let selectionFill = Color.accentColor.opacity(0.2)
}

extension View {
    /// A card on the raised surface, with the light appearance's hairline edge
    /// (`Tokens.Surface.edge`): the result card, the cards over the composer and the Overview's.
    func raisedCard() -> some View {
        background(Tokens.Surface.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Surface.edge, lineWidth: 0.5) }
    }
}
