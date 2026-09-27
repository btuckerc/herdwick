import Foundation

extension HerdrClient {
    public func createWorktree(workspaceID: String, branch: String, session: String) async throws -> WorkspaceCreateResult {
        struct Params: Encodable, Sendable {
            var workspace_id: String
            var branch: String
            var focus = false
        }
        return try await request("worktree.create", params: Params(workspace_id: workspaceID, branch: branch), session: session)
    }

    public func integrations(session: String) async throws -> [IntegrationInfo] {
        let result: IntegrationList = try await request("integration.list", params: EmptyParams(), session: session)
        return result.integrations
    }

    public func installIntegration(_ target: String, session: String) async throws {
        struct Params: Encodable, Sendable { var target: String }
        let _: Ignored = try await request("integration.install", params: Params(target: target), session: session)
    }
}
