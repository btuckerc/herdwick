import Foundation
import HerdrAPI
import Observation

/// Notification policy only; never changes read state or blocked status.
@MainActor @Observable
final class Mutes {
    static let shared = Mutes()
    private(set) var entries = AttentionSnapshot.mutes

    func isMuted(_ address: PaneAddress, reference: String?) -> Bool {
        guard let reference else { return false }
        return entries[key(address, reference: reference)]?.active(reference: reference) ?? false
    }

    func set(_ address: PaneAddress, reference: String, until: Date?) {
        entries[key(address, reference: reference)] = .init(reference: reference, expires: until)
        AttentionSnapshot.mutes = entries
    }

    func unmute(_ address: PaneAddress, reference: String) {
        entries.removeValue(forKey: key(address, reference: reference))
        AttentionSnapshot.mutes = entries
    }

    func watcherMutes(_ link: HostConnection) -> [PushWatch.Config.Mute] {
        (link.snapshot?.agents ?? []).compactMap { agent in
            guard let reference = agent.agentSession?.value,
                  let mute = entries[key(link.address(paneID: agent.paneID), reference: reference)],
                  mute.active(reference: reference) else { return nil }
            return .init(pane: agent.paneID, reference: reference,
                         expires: mute.expires.map { Int($0.timeIntervalSince1970) } ?? 0)
        }
    }

    private func key(_ address: PaneAddress, reference: String) -> String {
        AttentionSnapshot.muteKey(AttentionSnapshot.key(host: address.hostID, session: address.session,
                                                       pane: address.paneID), reference: reference)
    }
}
