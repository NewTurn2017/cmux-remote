import XCTest
@testable import CmuxRemote

final class WSClientTests: XCTestCase {
    func testConnectsAndDeliversTextFrame() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["WS_ECHO"] != "1", "set WS_ECHO=1 to run")
        let url = URL(string: "wss://echo.websocket.events/")!
        let exp = expectation(description: "received echo")
        let client = WSClient(url: url, headers: [:])
        await client.setOnText { text in if text.contains("hello") { exp.fulfill() } }
        await client.connect()
        await client.send(text: "hello")
        await fulfillment(of: [exp], timeout: 5)
        await client.close()
    }
}
