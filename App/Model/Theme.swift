import HerdrAPI
import SwiftUI
import UIKit

/// A terminal palette in Ghostty's shape: background, foreground, cursor,
/// selection and the 16 ANSI colours.
struct TerminalTheme: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDark: Bool
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: UInt32
    let ansi: [UInt32]

    var backgroundColor: Color { Color(hex: background) }
    var foregroundColor: Color { Color(hex: foreground) }

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: "herdwick-night", name: "Herdwick Night", isDark: true,
            background: 0x1B1D1F, foreground: 0xDCD7CD, cursor: 0xE8C27A, selection: 0x3A3F44,
            ansi: [0x2A2D30, 0xE06C6C, 0x9CC48A, 0xE8C27A, 0x7FA7D9, 0xC49BD8, 0x7CC7C0, 0xCFC9BD,
                   0x7D858B, 0xF08A84, 0xB5D9A2, 0xF2D59B, 0x9DBFE8, 0xD9B6E6, 0x9BDCD5, 0xF4F0E8]),
        TerminalTheme(
            id: "herdwick-day", name: "Herdwick Day", isDark: false,
            background: 0xF6F3EC, foreground: 0x33312D, cursor: 0x8A6A2F, selection: 0xDCD6C8,
            ansi: [0x33312D, 0xB83A3A, 0x4C7B38, 0x936611, 0x2F5F9E, 0x8A4B9E, 0x297B74, 0xB8B2A6,
                   0x6B675F, 0xCB3933, 0x4D7A39, 0x8F6718, 0x3B71B4, 0x9A51B0, 0x2B7A73, 0xE8E4DA]),
        TerminalTheme(
            id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
            background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC, selection: 0x585B70,
            ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                   0x82859D, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8]),
        TerminalTheme(
            id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
            background: 0xEFF1F5, foreground: 0x4C4F69, cursor: 0xDC8A78, selection: 0xACB0BE,
            ansi: [0x5C5F77, 0xD20F39, 0x327C21, 0x996114, 0x1761F5, 0xC71F9A, 0x13797E, 0xACB0BE,
                   0x6A6D82, 0xD20F39, 0x327C21, 0x996114, 0x1761F5, 0xC71F9A, 0x13797E, 0xBCC0CC]),
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night", isDark: true,
            background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5, selection: 0x33467C,
            ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                   0x7882AB, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        TerminalTheme(
            id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
            background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x504945,
            ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x9A8C7E, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light", isDark: false,
            background: 0xFDF6E3, foreground: 0x5F747C, cursor: 0x586E75, selection: 0xEEE8D5,
            ansi: [0x073642, 0xDA2825, 0x687800, 0x8F6C00, 0x2076B2, 0xCF2D7C, 0x217D76, 0xEEE8D5,
                   0x002B36, 0xC44815, 0x586E75, 0x5F747C, 0x647476, 0x6368C0, 0x657474, 0xFDF6E3]),
    ]

    static func named(_ id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum TerminalFont: String, CaseIterable, Identifiable, Sendable {
    case sfMono, menlo, courier
    var id: Self { self }

    var label: String {
        switch self {
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .courier: "Courier New"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .sfMono: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo: UIFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .courier: UIFont(name: "CourierNewPSMT", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor @Observable
final class Settings {
    var appearance: Appearance { didSet { if appearance != oldValue { defaults.set(appearance.rawValue, forKey: "appearance") } } }
    var darkThemeID: String { didSet { if darkThemeID != oldValue { defaults.set(darkThemeID, forKey: "theme.dark") } } }
    var lightThemeID: String { didSet { if lightThemeID != oldValue { defaults.set(lightThemeID, forKey: "theme.light") } } }
    var font: TerminalFont { didSet { if font != oldValue { defaults.set(font.rawValue, forKey: "font") } } }
    var fontSize: Double { didSet { if fontSize != oldValue { defaults.set(fontSize, forKey: "fontSize") } } }
    /// The terminal's text sizes, in Settings, pinch and ⌘+/⌘−. Up to 32 so the live terminal
    /// can be read at accessibility text sizes, scrolling sideways past the screen (round 38: sb#15,
    /// a 20 pt cap left only Read as Text).
    static let fontSizes: ClosedRange<Double> = 8...32
    /// The size until the user picks one: 12 pt, 15 on the iPad (its pane has room, and 12 there
    /// reads as fine print beside 17 pt text), grown with the text size up to 20 (round 40: sb#13,
    /// sa#4, at accessibility sizes the terminal still opened at 12 pt).
    static var defaultFontSize: Double {
        let base: Double = UIDevice.current.userInterfaceIdiom == .pad ? 15 : 12
        let category = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        return min(max(base, 20), UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: category).rounded())
    }
    /// Back to `defaultFontSize`, unset again, so it keeps following the text size (round 41:
    /// sb#3, ⌘0 stored the size as a choice).
    func resetFontSize() {
        fontSize = Self.defaultFontSize
        defaults.removeObject(forKey: "fontSize")
    }
    var haptics: Bool { didSet { if haptics != oldValue { defaults.set(haptics, forKey: "haptics") } } }
    var composerAutocorrect: Bool { didSet { if composerAutocorrect != oldValue { defaults.set(composerAutocorrect, forKey: "composerAutocorrect") } } }
    /// The on-screen keyboard's Return sends instead of adding a line.
    var returnKeySends: Bool { didSet { if returnKeySends != oldValue { defaults.set(returnKeySends, forKey: "returnKeySends") } } }
    var attachmentRetention: AttachmentRetention { didSet { if attachmentRetention != oldValue { defaults.set(attachmentRetention.rawValue, forKey: "attachmentRetention") } } }
    /// One inbox for every saved host instead of the selected one.
    var allHosts: Bool { didSet { if allHosts != oldValue { defaults.set(allHosts, forKey: "allHosts") } } }
    var inboxGrouping: InboxGrouping { didSet { if inboxGrouping != oldValue { defaults.set(inboxGrouping.rawValue, forKey: "inboxGrouping") } } }
    var inboxSort: InboxSort { didSet { if inboxSort != oldValue { defaults.set(inboxSort.rawValue, forKey: "inboxSort") } } }
    /// Fold read results into one "N Read" row.
    var collapseIdle: Bool { didSet { if collapseIdle != oldValue { defaults.set(collapseIdle, forKey: "collapseIdle") } } }
    /// The agent dock in conversations and agents' terminals.
    var showsDock: Bool { didSet { if showsDock != oldValue { defaults.set(showsDock, forKey: "showsDock") } } }
    /// How much of a conversation shows; set in Settings or any conversation's More menu.
    var detailLevel: DetailLevel { didSet { if detailLevel != oldValue { defaults.set(detailLevel.rawValue, forKey: "detailLevel") } } }
    /// Alerts for agents that need you (with the badge) and for finished work.
    var notifyNeedsYou: Bool {
        didSet {
            guard notifyNeedsYou != oldValue else { return }
            defaults.set(notifyNeedsYou, forKey: "notifyNeedsYou")
            onNotifyNeedsYouChange?()
        }
    }
    @ObservationIgnored var onNotifyNeedsYouChange: (() -> Void)?
    var answerFromNotifications: Bool {
        didSet {
            guard answerFromNotifications != oldValue else { return }
            defaults.set(answerFromNotifications, forKey: "answerFromNotifications")
            onAnswerFromNotificationsChange?()
        }
    }
    @ObservationIgnored var onAnswerFromNotificationsChange: (() -> Void)?
    var notifyFinished: Bool { didSet { if notifyFinished != oldValue { defaults.set(notifyFinished, forKey: "notifyFinished") } } }
    /// Opt-in: while the app is away, hosts send alerts through the push relay (`Push`).
    var pushWhileAway: Bool { didSet { if pushWhileAway != oldValue { defaults.set(pushWhileAway, forKey: "pushWhileAway") } } }
    /// Text inserted into the composer from its + menu; never sent by itself.
    var snippets: [Snippet] { didSet { if snippets != oldValue { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } } }
    /// Dictation's dictionary: phrases speech recognition gets wrong, rewritten before they reach the draft.
    var dictationReplacements: [WordReplacement] { didSet { if dictationReplacements != oldValue { defaults.set(try? JSONEncoder().encode(dictationReplacements), forKey: "dictationReplacements") } } }
    /// Dictation's known terms, by line or comma: spelled as entered wherever they're heard.
    var dictationTerms: String { didSet { if dictationTerms != oldValue { defaults.set(dictationTerms, forKey: "dictationTerms") } } }
    var knownTerms: [String] { dictationTerms.split { $0 == "," || $0.isNewline }.map(String.init) }
    /// The dictation card shows the words as they're heard; off, it shows only what it's doing.
    var showsLiveTranscript: Bool { didSet { if showsLiveTranscript != oldValue { defaults.set(showsLiveTranscript, forKey: "showsLiveTranscript") } } }
    /// Named ways to start an agent: a kind plus literal extra arguments.
    var launchPresets: [LaunchPreset] { didSet { if launchPresets != oldValue { defaults.set(try? JSONEncoder().encode(launchPresets), forKey: "launchPresets") } } }
    /// A line of each conversation's newest message under its inbox row.
    var inboxPreviews: Bool { didSet { if inboxPreviews != oldValue { defaults.set(inboxPreviews, forKey: "inboxPreviews") } } }
    /// Keep the last loaded part of recent conversations on this device to read offline.
    var offlineTranscripts: Bool {
        didSet {
            guard offlineTranscripts != oldValue else { return }
            defaults.set(offlineTranscripts, forKey: "offlineTranscripts")
            TranscriptCache.preferenceChanged()
        }
    }
    /// Face ID (or the passcode) before the app shows anything, and a cover in the app switcher.
    var appLock: Bool { didSet { if appLock != oldValue { defaults.set(appLock, forKey: "appLock") } } }

    private let defaults = UserDefaults.standard

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        darkThemeID = defaults.string(forKey: "theme.dark") ?? "herdwick-night"
        lightThemeID = defaults.string(forKey: "theme.light") ?? "herdwick-day"
        font = TerminalFont(rawValue: defaults.string(forKey: "font") ?? "") ?? .sfMono
        // `double(forKey:)` also reads launch-argument strings (`-fontSize 14`).
        fontSize = defaults.object(forKey: "fontSize") == nil ? Self.defaultFontSize : defaults.double(forKey: "fontSize")
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        composerAutocorrect = defaults.object(forKey: "composerAutocorrect") as? Bool ?? false
        returnKeySends = defaults.object(forKey: "returnKeySends") as? Bool ?? false
        attachmentRetention = AttachmentRetention(rawValue: defaults.string(forKey: "attachmentRetention") ?? "") ?? .day
        allHosts = defaults.object(forKey: "allHosts") as? Bool ?? false
        // Round 5 made Status the default; None, the old default, was stored by every install, so
        // it is read as Status once. A None chosen after that stays.
        if defaults.object(forKey: "inboxGrouping.statusDefault") == nil {
            if defaults.string(forKey: "inboxGrouping") == InboxGrouping.none.rawValue { defaults.removeObject(forKey: "inboxGrouping") }
            defaults.set(true, forKey: "inboxGrouping.statusDefault")
        }
        inboxGrouping = InboxGrouping(rawValue: defaults.string(forKey: "inboxGrouping") ?? "") ?? .status
        inboxSort = InboxSort(rawValue: defaults.string(forKey: "inboxSort") ?? "") ?? .recent
        collapseIdle = defaults.object(forKey: "collapseIdle") as? Bool ?? false
        showsDock = defaults.object(forKey: "showsDock") as? Bool ?? true
        // "full" was a third level, retired: it reads as Folded, and the key forgets it.
        if defaults.string(forKey: "detailLevel") == "full" { defaults.set(DetailLevel.folded.rawValue, forKey: "detailLevel") }
        detailLevel = DetailLevel(rawValue: defaults.string(forKey: "detailLevel") ?? "") ?? .folded
        notifyNeedsYou = defaults.object(forKey: "notifyNeedsYou") as? Bool ?? false
        notifyFinished = defaults.object(forKey: "notifyFinished") as? Bool ?? false
        answerFromNotifications = defaults.object(forKey: "answerFromNotifications") as? Bool ?? true
        pushWhileAway = defaults.object(forKey: "pushWhileAway") as? Bool ?? false
        snippets = Self.decode([Snippet].self, "snippets") ?? []
        dictationReplacements = Self.decode([WordReplacement].self, "dictationReplacements") ?? []
        dictationTerms = defaults.string(forKey: "dictationTerms") ?? ""
        showsLiveTranscript = defaults.object(forKey: "showsLiveTranscript") as? Bool ?? true
        launchPresets = Self.decode([LaunchPreset].self, "launchPresets") ?? []
        inboxPreviews = defaults.object(forKey: "inboxPreviews") as? Bool ?? true
        offlineTranscripts = defaults.object(forKey: "offlineTranscripts") as? Bool ?? false
        appLock = defaults.object(forKey: "appLock") as? Bool ?? false
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func theme(for scheme: ColorScheme) -> TerminalTheme {
        TerminalTheme.named(scheme == .dark ? darkThemeID : lightThemeID)
    }

}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
}

/// Starts `kind` with `arguments` passed as literal argv (no shell parsing).
struct LaunchPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: String
    var arguments: [String]
}

/// Section headers in the Agents view. In Priority, "Needs You" is pinned first whatever the grouping.
enum InboxGrouping: String, CaseIterable, Identifiable {
    case none, host, workspace, status
    var id: Self { self }
    var label: String { switch self { case .none: "None"; case .host: "Host"; case .workspace: "Workspace"; case .status: "Status" } }
}

/// Order within a section, below "Needs You", which either way is pinned. Recent: last message
/// sent or received, newest first. Priority: unread done, working, idle or read done, unknown;
/// last message breaks ties.
enum InboxSort: String, CaseIterable, Identifiable {
    case recent, priority
    var id: Self { self }
    var label: String { switch self { case .recent: "Recent"; case .priority: "Priority" } }
}


extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
