import Testing
import Foundation
@testable import SharedKit

@Suite("JSON-RPC envelope")
struct JSONRPCTests {
    @Test func requestEncodesWithIdMethodParams() throws {
        let req = RPCRequest(id: 1, method: "workspace.list", params: .object([:]))
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"method\":\"workspace.list\""))
        #expect(json.contains("\"id\":1"))
        let back = try JSONDecoder().decode(RPCRequest.self, from: data)
        #expect(back == req)
    }

    @Test func okResponseDecodes() throws {
        let raw = #"{"id":1,"ok":true,"result":{"workspaces":[]}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.id == 1)
        #expect(resp.ok == true)
        #expect(resp.error == nil)
        #expect(resp.result == .object(["workspaces": .array([])]))
    }

    @Test func errorResponseDecodes() throws {
        let raw = #"{"id":2,"ok":false,"error":{"code":-32000,"message":"boom"}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.ok == false)
        #expect(resp.error?.code == -32000)
        #expect(resp.error?.message == "boom")
    }

    @Test func paramsAcceptArbitraryShape() throws {
        let raw = #"{"id":7,"method":"events.subscribe","params":{"categories":["notification"]}}"#
        let req = try JSONDecoder().decode(RPCRequest.self, from: Data(raw.utf8))
        #expect(req.method == "events.subscribe")
        if case .object(let dict) = req.params,
           case .array(let arr) = dict["categories"],
           case .string(let s)  = arr.first {
            #expect(s == "notification")
        } else {
            Issue.record("params shape not parsed")
        }
    }
}
