import Foundation
import Testing
@testable import HerdrAPI

@Suite struct LaunchDecodeTests {
    @Test func worktreeCreationRetainsDestinationAndMetadata() throws {
        let bytes = Data(#"{"type": "worktree_created", "workspace": {"workspace_id": "w2", "number": 2, "label": "linked", "focused": false, "pane_count": 1, "tab_count": 1, "active_tab_id": "w2:t1", "agent_status": "unknown", "worktree": {"repo_key": "/tmp/herdwick-launch-bbjjmcwb/.git", "repo_name": "herdwick-launch-bbjjmcwb", "repo_root": "/tmp/herdwick-launch-bbjjmcwb", "checkout_path": "/tmp/herdwick-launch-bbjjmcwb/linked", "is_linked_worktree": true}}, "tab": {"tab_id": "w2:t1", "workspace_id": "w2", "number": 1, "label": "1", "focused": false, "pane_count": 1, "agent_status": "unknown"}, "root_pane": {"pane_id": "w2:p1", "terminal_id": "term_65c748a29cf062", "workspace_id": "w2", "tab_id": "w2:t1", "focused": false, "cwd": "/tmp/herdwick-launch-bbjjmcwb/linked", "foreground_cwd": "/tmp/herdwick-launch-bbjjmcwb/linked", "agent_status": "unknown", "scroll": {"offset_from_bottom": 0, "max_offset_from_bottom": 0, "viewport_rows": 40}, "revision": 0}, "worktree": {"path": "/tmp/herdwick-launch-bbjjmcwb/linked", "branch": "launch-test", "is_bare": false, "is_detached": false, "is_prunable": false, "is_linked_worktree": true, "open_workspace_id": "w2", "label": "herdwick-launch-bbjjmcwb"}}"#.utf8)
        let result = try JSONDecoder().decode(WorkspaceCreateResult.self, from: bytes)
        #expect(result.workspace.worktree?.isLinkedWorktree == true)
        #expect(result.workspace.worktree?.checkoutPath == result.rootPane.cwd)
        #expect(result.rootPane.workspaceID == result.workspace.id)
        #expect(result.rootPane.focused == false)
        #expect(result.workspace.worktree?.repoRoot == "/tmp/herdwick-launch-bbjjmcwb")
    }
    @Test func integrationStatesPreserveMissingVersusUnavailable() throws {
        let bytes = Data(#"{"type": "integration_list", "integrations": [{"target": "pi", "label": "pi", "command": "pi", "available": false, "state": "not_installed"}, {"target": "omp", "label": "omp", "command": "omp", "available": true, "state": "current"}, {"target": "claude", "label": "claude", "command": "claude", "available": true, "state": "not_installed"}, {"target": "codex", "label": "codex", "command": "codex", "available": true, "state": "not_installed"}, {"target": "copilot", "label": "copilot", "command": "copilot", "available": false, "state": "not_installed"}, {"target": "devin", "label": "devin", "command": "devin", "available": false, "state": "not_installed"}, {"target": "droid", "label": "droid", "command": "droid", "available": false, "state": "not_installed"}, {"target": "kimi", "label": "kimi", "command": "kimi", "available": false, "state": "not_installed"}, {"target": "opencode", "label": "opencode", "command": "opencode", "available": false, "state": "not_installed"}, {"target": "kilo", "label": "kilo", "command": "kilo", "available": false, "state": "not_installed"}, {"target": "hermes", "label": "hermes", "command": "hermes", "available": false, "state": "not_installed"}, {"target": "qodercli", "label": "qodercli", "command": "qodercli", "available": false, "state": "not_installed"}, {"target": "qwen", "label": "qwen", "command": "qwen", "available": false, "state": "not_installed"}, {"target": "cursor", "label": "cursor", "command": "cursor-agent", "available": false, "state": "not_installed"}, {"target": "mastracode", "label": "mastracode", "command": "mastracode", "available": false, "state": "not_installed"}, {"target": "antigravity_cli", "label": "antigravity-cli", "command": "agy", "available": false, "state": "not_installed"}, {"target": "grok", "label": "grok", "command": "grok", "available": false, "state": "not_installed"}]}"#.utf8)
        let result = try JSONDecoder().decode(IntegrationList.self, from: bytes)
        #expect(result.integrations.first { $0.target == "omp" }?.state == "current")
        #expect(result.integrations.first { $0.target == "claude" }?.state == "not_installed")
        #expect(result.integrations.first { $0.target == "claude" }?.available == true)
        #expect(result.integrations.first { $0.target == "pi" }?.available == false)
    }
}
