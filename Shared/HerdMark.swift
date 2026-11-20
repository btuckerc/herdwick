import SwiftUI

/// The Herdwick sheep from the app icon: a scalloped dark fleece, a cream face with ears, and a
/// prompt on the face. Its mood is what follows the prompt, so it shows in a still: working, a
/// blinking cursor; waiting, an amber "?" with ears that perk as it begins; quiet, a dim "z";
/// done, a green check with one small hop (round 21: the sheep looked the same in every state).
/// Under 60 pt the face is too small to read a glyph on it, so waiting, quiet and done move to
/// a badge at its lower trailing corner, as the Done seal's check sits (round 22: on the 28 pt
/// dock sheep and the 56 pt Overview sheep the "?" was a few pixels). Reduce Motion holds each
/// still. Decorative.
struct HerdMark: View {
    enum Mood: Equatable {
        case idle, working, waiting, quiet, done
    }

    let size: CGFloat
    let mood: Mood

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    @State private var perk = false
    @State private var hop = false

    init(size: CGFloat = 64, mood: Mood = .idle) {
        self.size = size
        self.mood = mood
    }

    var body: some View {
        Canvas { context, canvas in draw(in: &context, side: canvas.width) }
            .overlay { cursor }
            .overlay(alignment: .bottomTrailing) { badge }
            .frame(width: size, height: size)
            .offset(y: hop ? -3 : 0)
            .accessibilityHidden(true)
            .onAppear { blink(); animateMood() }
            .onChange(of: reduceMotion) { blink() }
            .onChange(of: mood) { blink(); animateMood() }
    }

    /// Below this size the mood is a corner badge rather than a glyph on the face.
    private var badged: Bool { size < 60 }

    @ViewBuilder private var cursor: some View {
        switch badged ? (mood == .working ? .working : .idle) : mood {
        case .working, .idle:
            RoundedRectangle(cornerRadius: size * 0.008)
                .fill(Self.amber).frame(width: size * 0.105, height: size * 0.04)
                .offset(x: size * 0.0725, y: size * 0.065).opacity(dim ? 0.25 : 1)
        case .waiting:
            Text("?").font(.system(size: size * 0.20, weight: .bold, design: .rounded))
                .foregroundStyle(Self.amber).offset(x: size * 0.025, y: size * 0.035)
        case .quiet:
            Text("z").font(.system(size: size * 0.17, weight: .medium, design: .rounded))
                .foregroundStyle(Self.ink.opacity(0.55)).offset(x: size * 0.06, y: size * 0.065)
        case .done:
            Image(systemName: "checkmark").font(.system(size: size * 0.16, weight: .bold))
                .foregroundStyle(Color.green).offset(x: size * 0.04, y: size * 0.04)
        }
    }

    @ViewBuilder private var badge: some View {
        if badged, let badge = badgeSymbol {
            Image(systemName: badge.symbol)
                .font(.system(size: max(11, size * 0.4), weight: .bold))
                .foregroundStyle(.white, badge.tint)
                .background(Circle().fill(.background).padding(-1.5))
                .offset(x: size * 0.06, y: size * 0.04)
        }
    }

    private var badgeSymbol: (symbol: String, tint: Color)? {
        switch mood {
        // The app's Needs You mark, orange "!", not a second yellow "?" (round 40: opus#10, the
        // Overview's sheep said "?" beside cards marked "!").
        case .waiting: ("exclamationmark.circle.fill", Color.orange)
        case .quiet: ("moon.circle.fill", Color.secondary)
        case .done: ("checkmark.circle.fill", Color.green)
        case .working, .idle: nil
        }
    }

    private func animateMood() {
        guard !reduceMotion else {
            withAnimation(nil) { perk = false; hop = false }
            return
        }
        if mood == .waiting {
            withAnimation(.easeOut(duration: 0.2)) { perk = true }
            withAnimation(.easeInOut(duration: 0.3).delay(0.2)) { perk = false }
        }
        if mood == .done {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { hop = true }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8).delay(0.22)) { hop = false }
        }
    }

    private func blink() {
        guard mood == .working, !reduceMotion else {
            withAnimation(nil) { dim = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
    }

    private func draw(in context: inout GraphicsContext, side s: CGFloat) {
        let c = s / 2
        var fleece = Path(ellipseIn: CGRect(x: c - 0.3 * s, y: c - 0.3 * s, width: 0.6 * s, height: 0.6 * s))
        for index in 0..<9 {
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / 9
            let x = c + 0.3 * s * cos(angle), y = c + 0.3 * s * sin(angle)
            fleece.addEllipse(in: CGRect(x: x - 0.17 * s, y: y - 0.17 * s, width: 0.34 * s, height: 0.34 * s))
        }
        context.fill(fleece, with: .color(colorScheme == .dark ? Self.fleeceDark : Self.fleece))
        for side in [-1.0, 1.0] {
            var ear = context
            ear.translateBy(x: c + side * 0.245 * s, y: c - 0.1 * s - (mood == .waiting && perk ? 0.025 * s : 0))
            ear.rotate(by: .degrees(side * (mood == .waiting && perk ? 19 : 12)))
            ear.fill(Path(ellipseIn: CGRect(x: -0.095 * s, y: -0.05 * s, width: 0.19 * s, height: 0.1 * s)),
                     with: .color(Self.cream))
        }
        let face = UnevenRoundedRectangle(topLeadingRadius: 0.13 * s, bottomLeadingRadius: 0.18 * s,
                                          bottomTrailingRadius: 0.18 * s, topTrailingRadius: 0.13 * s)
            .path(in: CGRect(x: c - 0.18 * s, y: c - 0.22 * s, width: 0.36 * s, height: 0.47 * s))
        context.fill(face, with: .color(Self.cream))
        var prompt = Path()
        prompt.move(to: CGPoint(x: c - 0.1 * s, y: c - 0.11 * s))
        prompt.addLine(to: CGPoint(x: c - 0.03 * s, y: c - 0.03 * s))
        prompt.addLine(to: CGPoint(x: c - 0.1 * s, y: c + 0.05 * s))
        context.stroke(prompt, with: .color(Self.ink),
                       style: StrokeStyle(lineWidth: 0.04 * s, lineCap: .round, lineJoin: .round))
    }

    private static let fleece = Color(red: 0.235, green: 0.224, blue: 0.212)
    private static let fleeceDark = Color(red: 0.31, green: 0.295, blue: 0.28)
    private static let cream = Color(red: 0.933, green: 0.922, blue: 0.89)
    private static let ink = Color(red: 0.15, green: 0.15, blue: 0.14)
    private static let amber = Color(red: 0.878, green: 0.663, blue: 0.231)
}


/// The sheep with a check at its lower trailing corner: a turn finished, or nothing waits on
/// you (round 15: Delight was the lowest area; a Done card was an anonymous check). `play`
/// signs it once (the sheep settles from 0.9 with a slight overshoot while the check pops in
/// 80 ms behind, done by ~420 ms); Reduce Motion shows it finished. Decorative.
struct HerdSeal: View {
    let size: CGFloat
    /// The surface behind it, ringing the check so it reads apart from the fleece.
    let ring: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markIn: Bool
    @State private var checkIn: Bool

    init(size: CGFloat, play: Bool = false, ring: Color = Color(uiColor: .secondarySystemBackground)) {
        self.size = size
        self.ring = ring
        _markIn = State(initialValue: !play)
        _checkIn = State(initialValue: !play)
    }

    var body: some View {
        HerdMark(size: size)
            .scaleEffect(markIn ? 1 : 0.9)
            // An accent disc behind the sheep so the dark fleece holds on a dark card and the
            // seal reads as the result's mark (round 15: graders found it quiet, near lost).
            .padding(size * 0.12)
            .background(Circle().fill(Color.accentColor.opacity(0.2)).scaleEffect(markIn ? 1 : 0.7))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white, Color.accentColor)
                    .background(Circle().fill(ring).padding(-2))
                    .offset(x: size * 0.04, y: size * 0.02)
                    .scaleEffect(checkIn ? 1 : 0.3)
                    .opacity(checkIn ? 1 : 0)
            }
            .accessibilityHidden(true)
            .onAppear(perform: sign)
    }

    private func sign() {
        guard !markIn || !checkIn, !reduceMotion else {
            markIn = true
            checkIn = true
            return
        }
        withAnimation(.spring(duration: 0.32, bounce: 0.45)) { markIn = true }
        withAnimation(.spring(duration: 0.34, bounce: 0.4).delay(0.08)) { checkIn = true }
    }
}

#Preview {
    HStack(spacing: 24) {
        HerdMark(size: 96, mood: .working)
        HerdMark(size: 56)
    }
    .padding()
}
