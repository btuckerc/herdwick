import LocalAuthentication
import SwiftUI
import UIKit

@MainActor @Observable
final class AppLock {
    private(set) var unlocked = false
    private(set) var authenticating = false
    private(set) var error: String?
    private var backgrounded: Date?
    private var context: LAContext?
    static let gracePeriod: TimeInterval = 30

    func phaseChanged(_ phase: ScenePhase, enabled: Bool) {
        if phase == .background {
            backgrounded = .now
            context?.invalidate()
        } else if phase == .active {
            if let backgrounded, Date.now.timeIntervalSince(backgrounded) > Self.gracePeriod { unlocked = false }
            backgrounded = nil
            if enabled && !unlocked { authenticate() }
        }
    }

    func settingChanged(enabled: Bool) {
        unlocked = false
        if enabled { authenticate() }
    }

    func authenticate() {
        guard !authenticating else { return }
        authenticating = true
        error = nil
        let context = LAContext()
        self.context = context
        Task { @MainActor in
            defer { authenticating = false; self.context = nil }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Unlock your Herdwick conversations.")
                if accepted && backgrounded == nil { unlocked = true }
            } catch {
                self.error = "Authentication wasn't completed. Unlock to try again."
            }
        }
    }
}

/// Apply once to each scene root. With App Lock on, a window-level shield (over sheets too)
/// hides the app while it isn't active or unlocked; with it off, nothing covers the app.
struct AppPrivacyModifier: ViewModifier {
    @Environment(Settings.self) private var settings
    @Environment(\.scenePhase) private var phase
    @State private var lock = AppLock()

    func body(content: Content) -> some View {
        content
            .background(PrivacyWindowShield(covered: settings.appLock && (phase != .active || !lock.unlocked),
                                            active: phase == .active, lock: lock))
            .onChange(of: phase, initial: true) { _, value in lock.phaseChanged(value, enabled: settings.appLock) }
            .onChange(of: settings.appLock) { _, value in lock.settingChanged(enabled: value) }
    }
}

private struct PrivacyCover: View {
    let active: Bool
    let lock: AppLock
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Herdwick").font(.title)
                if active {
                    if let error = lock.error { Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Button("Unlock") { lock.authenticate() }.disabled(lock.authenticating)
                }
            }.padding()
        }
        .accessibilityAddTraits(.isModal)
    }
}

private struct PrivacyWindowShield: UIViewRepresentable {
    let covered: Bool
    let active: Bool
    let lock: AppLock

    final class Anchor: UIView {
        var shield: UIHostingController<PrivacyCover>?
        var covered = false
        override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
        func refresh() {
            guard let shield else { return }
            guard covered, let window else { shield.view.removeFromSuperview(); return }
            shield.view.frame = window.bounds
            shield.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(shield.view)
            window.bringSubviewToFront(shield.view)
        }
    }

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        let root = PrivacyCover(active: active, lock: lock)
        if let shield = view.shield { shield.rootView = root }
        else { view.shield = UIHostingController(rootView: root) }
        view.covered = covered
        view.refresh()
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.shield?.view.removeFromSuperview() }
}
