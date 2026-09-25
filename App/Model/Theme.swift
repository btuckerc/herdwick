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
                   0x5B6166, 0xF08A84, 0xB5D9A2, 0xF2D59B, 0x9DBFE8, 0xD9B6E6, 0x9BDCD5, 0xF4F0E8]),
        TerminalTheme(
            id: "herdwick-day", name: "Herdwick Day", isDark: false,
            background: 0xF6F3EC, foreground: 0x33312D, cursor: 0x8A6A2F, selection: 0xDCD6C8,
            ansi: [0x33312D, 0xB83A3A, 0x4E7F3A, 0x9A6B12, 0x2F5F9E, 0x8A4B9E, 0x2A7F78, 0xB8B2A6,
                   0x6B675F, 0xD04A45, 0x5E9646, 0xB07F1E, 0x3C73B8, 0xA05CB5, 0x35968E, 0xE8E4DA]),
        TerminalTheme(
            id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
            background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC, selection: 0x585B70,
            ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                   0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8]),
        TerminalTheme(
            id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
            background: 0xEFF1F5, foreground: 0x4C4F69, cursor: 0xDC8A78, selection: 0xACB0BE,
            ansi: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                   0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC]),
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night", isDark: true,
            background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5, selection: 0x33467C,
            ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                   0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        TerminalTheme(
            id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
            background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x504945,
            ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light", isDark: false,
            background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75, selection: 0xEEE8D5,
            ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
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
    var appearance: Appearance { didSet { save() } }
    var darkThemeID: String { didSet { save() } }
    var lightThemeID: String { didSet { save() } }
    var font: TerminalFont { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var haptics: Bool { didSet { save() } }
    var composerAutocorrect: Bool { didSet { save() } }
    /// The on-screen keyboard's Return sends instead of adding a line.
    var returnKeySends: Bool { didSet { save() } }
    var showWorkingSubagents: Bool { didSet { save() } }
    var attachmentRetention: AttachmentRetention { didSet { save() } }
    /// One inbox for every saved host instead of the selected one.
    var allHosts: Bool { didSet { save() } }
    var inboxView: InboxKind { didSet { save() } }
    var inboxGrouping: InboxGrouping { didSet { save() } }
    var inboxSort: InboxSort { didSet { save() } }
    /// Fold idle, read agents into one "N Idle" row.
    var collapseIdle: Bool { didSet { save() } }
    /// How much of a thread shows by default; a thread can override it for itself.
    var detailLevel: DetailLevel { didSet { save() } }
    /// Alerts for agents that need you (with the badge) and for finished work.
    var notifyNeedsYou: Bool { didSet { save() } }
    var notifyFinished: Bool { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        darkThemeID = defaults.string(forKey: "theme.dark") ?? "herdwick-night"
        lightThemeID = defaults.string(forKey: "theme.light") ?? "herdwick-day"
        font = TerminalFont(rawValue: defaults.string(forKey: "font") ?? "") ?? .sfMono
        // `double(forKey:)` also reads launch-argument strings (`-fontSize 14`).
        fontSize = defaults.object(forKey: "fontSize") == nil ? 12 : defaults.double(forKey: "fontSize")
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        composerAutocorrect = defaults.object(forKey: "composerAutocorrect") as? Bool ?? false
        returnKeySends = defaults.object(forKey: "returnKeySends") as? Bool ?? false
        showWorkingSubagents = defaults.object(forKey: "showWorkingSubagents") as? Bool ?? true
        attachmentRetention = AttachmentRetention(rawValue: defaults.string(forKey: "attachmentRetention") ?? "") ?? .day
        allHosts = defaults.object(forKey: "allHosts") as? Bool ?? false
        inboxView = InboxKind(rawValue: defaults.string(forKey: "inboxView") ?? "") ?? .agents
        inboxGrouping = InboxGrouping(rawValue: defaults.string(forKey: "inboxGrouping") ?? "") ?? .none
        inboxSort = InboxSort(rawValue: defaults.string(forKey: "inboxSort") ?? "") ?? .recent
        collapseIdle = defaults.object(forKey: "collapseIdle") as? Bool ?? false
        detailLevel = DetailLevel(rawValue: defaults.string(forKey: "detailLevel") ?? "") ?? .folded
        notifyNeedsYou = defaults.object(forKey: "notifyNeedsYou") as? Bool ?? false
        notifyFinished = defaults.object(forKey: "notifyFinished") as? Bool ?? false
    }

    func theme(for scheme: ColorScheme) -> TerminalTheme {
        TerminalTheme.named(scheme == .dark ? darkThemeID : lightThemeID)
    }

    private func save() {
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(darkThemeID, forKey: "theme.dark")
        defaults.set(lightThemeID, forKey: "theme.light")
        defaults.set(font.rawValue, forKey: "font")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(haptics, forKey: "haptics")
        defaults.set(composerAutocorrect, forKey: "composerAutocorrect")
        defaults.set(returnKeySends, forKey: "returnKeySends")
        defaults.set(showWorkingSubagents, forKey: "showWorkingSubagents")
        defaults.set(attachmentRetention.rawValue, forKey: "attachmentRetention")
        defaults.set(allHosts, forKey: "allHosts")
        defaults.set(inboxView.rawValue, forKey: "inboxView")
        defaults.set(inboxGrouping.rawValue, forKey: "inboxGrouping")
        defaults.set(inboxSort.rawValue, forKey: "inboxSort")
        defaults.set(collapseIdle, forKey: "collapseIdle")
        defaults.set(detailLevel.rawValue, forKey: "detailLevel")
        defaults.set(notifyNeedsYou, forKey: "notifyNeedsYou")
        defaults.set(notifyFinished, forKey: "notifyFinished")
    }
}

/// Agents answers "who needs me"; Machines mirrors herdr's own host › workspace › tab › pane tree.
enum InboxKind: String, CaseIterable, Identifiable {
    case agents, machines
    var id: Self { self }
    var label: String { switch self { case .agents: "Agents"; case .machines: "Machines" } }
}

/// Section headers in the Agents view. "Needs You" is always pinned first, whatever the grouping.
enum InboxGrouping: String, CaseIterable, Identifiable {
    case none, host, workspace, status
    var id: Self { self }
    var label: String { switch self { case .none: "None"; case .host: "Host"; case .workspace: "Workspace"; case .status: "Status" } }
}

/// Order within a section. Priority: blocked, unread done, working, read done, idle, unknown; recency breaks ties.
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
