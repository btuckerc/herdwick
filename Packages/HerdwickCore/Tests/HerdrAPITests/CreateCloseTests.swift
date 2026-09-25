import Foundation
import Testing
@testable import HerdrAPI

@Suite struct CreateCloseTests {
    @Test func creationResultsDecodeSchemaShapes() throws {
        let workspace = #"{"workspace":{"workspace_id":"w1","number":1,"label":"Repo","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"t1","agent_status":"idle"},"tab":{"tab_id":"t1","workspace_id":"w1","number":1,"label":"main","focused":false,"pane_count":1,"agent_status":"idle"},"root_pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"t1","focused":false,"agent_status":"idle","revision":0,"state_labels":{}}}"#
        let result = try JSONDecoder().decode(WorkspaceCreateResult.self, from: Data(workspace.utf8))
        #expect(result.workspace.id == "w1")
        #expect(result.tab.id == "t1")
        #expect(result.rootPane.id == "w1:p1")
        let tab = #"{"tab":{"tab_id":"t2","workspace_id":"w1","number":2,"label":"new","focused":false,"pane_count":1,"agent_status":"idle"},"root_pane":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"t2","focused":false,"agent_status":"idle","revision":0,"state_labels":{}}}"#
        #expect(try JSONDecoder().decode(TabCreateResult.self, from: Data(tab.utf8)).rootPane.id == "w1:p2")
    }

    @Test func requestParametersMatchSchema() throws {
        struct Create: Encodable { var workspace_id: String; var label: String?; var cwd: String?; var focus = false }
        let line = try HerdrClient.requestLine(id: "1", method: "tab.create", params: Create(workspace_id: "w1", label: "Review", cwd: "/repo"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == "w1")
        #expect(params["focus"] as? Bool == false)
        #expect(params["cwd"] as? String == "/repo")
    }

    @Test func closeErrorsAreTyped() throws {
        for (code, expected) in [("confirmation_required", HerdrError.confirmationRequired("Confirm")), ("workspace_group_close_required", HerdrError.workspaceGroupCloseRequired("Group"))] {
            let line = Array("{\"id\":\"1\",\"error\":{\"code\":\"\(code)\",\"message\":\"\(expectedMessage(expected))\"}}".utf8)
            #expect(throws: expected) { let _: HerdrClient.Ignored = try HerdrClient.decodeResponse(line) }
        }
    }

    private func expectedMessage(_ error: HerdrError) -> String {
        switch error { case .confirmationRequired(let message), .workspaceGroupCloseRequired(let message): message; default: "" }
    }
}
