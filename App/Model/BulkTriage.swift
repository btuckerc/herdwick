import Foundation
import HerdrAPI

/// One action over the inbox's selection, agent by agent, each host's in turn. Each target is
/// the `AgentStamp` taken when the user picked it, checked again just before its action: a
/// close awaits herdr, and meanwhile its host may have moved to another session, where the
/// same pane ID is someone else, or a picked agent may have exited and another started in its
/// pane. An agent no longer there counts as done; one on a host that isn't connected, or that
/// herdr refuses, is a failure and stays selected.
@MainActor
enum BulkTriage {
    enum Operation { case markRead, hide, unhide, close }

    struct Failure: Identifiable {
        let address: PaneAddress
        let title: String
        let message: String
        var id: PaneAddress { address }
    }

    struct Result {
        let succeeded: Set<PaneAddress>
        let failures: [Failure]
    }

    /// `targets`: each selected address and the agent it held when picked.
    static func perform(_ operation: Operation, targets: [PaneAddress: AgentStamp], model: AppModel) async -> Result {
        var succeeded = Set<PaneAddress>()
        var failures: [Failure] = []
        for (address, stamp) in targets.sorted(by: { order($0.key, $1.key) }) {
            guard let thread = model.threads.first(where: { $0.address == address }), thread.stamp == stamp else {
                succeeded.insert(address)
                continue
            }
            guard thread.connection.isLive else {
                failures.append(Failure(address: address, title: thread.agent.conversationTitle,
                                        message: "Host is not connected."))
                continue
            }
            switch operation {
            case .markRead: thread.connection.markSeen(thread.agent)
            case .hide: thread.connection.hide(thread.agent)
            case .unhide: thread.connection.unhide(thread.agent)
            case .close:
                do {
                    guard let request = thread.connection.close(stamp) else { break }
                    try await request.value
                } catch {
                    failures.append(Failure(address: address, title: thread.agent.conversationTitle,
                                            message: error.localizedDescription))
                    continue
                }
            }
            succeeded.insert(address)
        }
        return Result(succeeded: succeeded, failures: failures)
    }

    private static func order(_ lhs: PaneAddress, _ rhs: PaneAddress) -> Bool {
        if lhs.hostID != rhs.hostID { return lhs.hostID.uuidString < rhs.hostID.uuidString }
        if lhs.session != rhs.session { return lhs.session < rhs.session }
        return lhs.paneID < rhs.paneID
    }
}
