import XCTest
import NIOCore
import SharedKit
@testable import CMUXClient

final class CMUXClientTests: XCTestCase {
    func testCallEncodesRequestAndResolvesOnResponse() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        defer { Task { await fix.shutdown() } }

        async let result = fix.client.call(method: "workspace.list", params: .object([:]))

        let outString = try await fix.awaitRequestLine()
        XCTAssertTrue(outString.contains("\"method\":\"workspace.list\""),
                      "missing method on wire: \(outString)")
        let outId = try Self.extractId(from: outString)

        try await fix.sendToClient(line: #"{"id":"\#(outId)","result":{"workspaces":[]}}"#)

        let value = try await result
        XCTAssertTrue(value.isOk)
    }



    func testAuthenticateSendsAuthLoginRequest() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        defer { Task { await fix.shutdown() } }

        async let auth: Void = fix.client.authenticate(password: "secret")

        let outString = try await fix.awaitRequestLine()
        XCTAssertTrue(outString.contains("\"method\":\"auth.login\""),
                      "missing auth method on wire: \(outString)")
        XCTAssertTrue(outString.contains("\"password\":\"secret\""),
                      "missing password param on wire: \(outString)")
        let outId = try Self.extractId(from: outString)

        try await fix.sendToClient(line: #"{"id":"\#(outId)","result":{"authenticated":true}}"#)

        try await auth
    }

    func testCapabilityWrapsEverySocketCommand() async throws {
        let capability = "v1.test-nonce.test-signature"
        let fix = try await MTELGCmuxFixture.make(
            requestTimeout: .seconds(2),
            socketCapability: capability
        )
        defer { Task { await fix.shutdown() } }

        async let result = fix.client.call(method: "workspace.list", params: .object([:]))

        let outString = try await fix.awaitRequestLine()
        let prefix = "_cmux_capability_v1 \(capability) "
        XCTAssertTrue(outString.hasPrefix(prefix), "missing capability envelope")
        let command = String(outString.dropFirst(prefix.count))
        XCTAssertNotNil(command.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        })
        let outId = try Self.extractId(from: command)

        try await fix.sendToClient(line: #"{"id":"\#(outId)","result":{"workspaces":[]}}"#)
        let value = try await result
        XCTAssertTrue(value.isOk)
    }

    func testPlainAccessDeniedFailsPendingAndFutureCalls() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        defer { Task { await fix.shutdown() } }

        async let result = fix.client.call(method: "workspace.list", params: .object([:]))
        _ = try await fix.awaitRequestLine()

        try await fix.sendToClient(line: "ERROR: Access denied — only processes started inside cmux can connect")

        do {
            _ = try await result
            XCTFail("expected access denied server message")
        } catch CMUXClientError.serverMessage(let message) {
            XCTAssertTrue(message.contains("Access denied"), message)
        }

        do {
            _ = try await fix.client.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected cached terminal server message")
        } catch CMUXClientError.serverMessage(let message) {
            XCTAssertTrue(message.contains("Access denied"), message)
        }
    }

    func testTimeoutThrows() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .milliseconds(100))
        defer { Task { await fix.shutdown() } }

        do {
            _ = try await fix.client.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected timeout")
        } catch CMUXClientError.timeout {
            // ok
        }
    }

    func testServerPushDispatchesToHandler() async throws {
        let fix = try await MTELGCmuxFixture.make()
        defer { Task { await fix.shutdown() } }

        let exp = expectation(description: "push delivered")
        await fix.client.onEventStream { frame in
            if case .event = frame { exp.fulfill() }
        }
        try await fix.sendToClient(
            line: #"{"type":"event","category":"system","name":"x","payload":{}}"#)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    private static func extractId(from line: String) throws -> String {
        let pattern = #"\"id\":\"([^\"]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: line,
                                                   range: NSRange(line.startIndex..., in: line)),
                                   "no id in: \(line)")
        return String(line[Range(match.range(at: 1), in: line)!])
    }
}
