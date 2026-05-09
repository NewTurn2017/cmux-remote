import Testing
import Foundation
@testable import SharedKit

@Suite("JSON-RPC envelope")
struct JSONRPCTests {
    @Test func requestEncodesWithIdMethodParams() throws {
        let req = RPCRequest(id: "req-1", method: "workspace.list", params: .object([:]))
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"method\":\"workspace.list\""))
        #expect(json.contains("\"id\":\"req-1\""))
        let back = try JSONDecoder().decode(RPCRequest.self, from: data)
        #expect(back == req)
    }

    @Test func okSuccessOmitsOkField() throws {
        // cmux returns success without `ok`; only `result` is present.
        let raw = #"{"id":"r1","result":{"workspaces":[]}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.id == "r1")
        #expect(resp.ok == nil)
        #expect(resp.error == nil)
        #expect(resp.result == .object(["workspaces": .array([])]))
        #expect(resp.isOk)
    }

    @Test func okExplicitTrueIsAlsoSuccess() throws {
        // Some methods do echo `ok: true`; both shapes are accepted.
        let raw = #"{"id":"r2","ok":true,"result":{"x":1}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.ok == true)
        #expect(resp.isOk)
    }

    @Test func errorResponseDecodes() throws {
        // cmux uses string error codes, not JSON-RPC 2.0 integers.
        let raw = #"{"id":"r3","ok":false,"error":{"code":"method_not_found","message":"Unknown method"}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.ok == false)
        #expect(resp.error?.code == "method_not_found")
        #expect(resp.error?.message == "Unknown method")
        #expect(!resp.isOk)
    }

    @Test func paramsAcceptArbitraryShape() throws {
        let raw = #"{"id":"r4","method":"events.subscribe","params":{"categories":["notification"]}}"#
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
