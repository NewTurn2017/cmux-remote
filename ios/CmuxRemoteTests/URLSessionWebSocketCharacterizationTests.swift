import Foundation
import Testing
@testable import CmuxRemote

/// The WebSocket task the app creates accepts messages up to 4 MiB on both creation paths.
@Suite("URLSessionWebSocketCharacterizationTests")
struct URLSessionWebSocketCharacterizationTests {
    @Test
    func appWebSocketTaskAllowsFourMebibyteMessages() async throws {
        let url = try #require(URL(string: "ws://127.0.0.1:9/ws"))
        let factory = URLSessionWebSocketConnectionFactory()
        var sizes: [String: Int] = [:]
        for (path, protocols) in [("request", [String]()), ("protocols", ["cmux-remote.v1"])] {
            let connection = await factory.makeConnection(
                url: url,
                headers: ["Authorization": "Bearer characterization"],
                protocols: protocols,
                onOpen: {},
                onClose: { _ in }
            )
            let task = try #require(
                Mirror(reflecting: connection).children.first { $0.label == "task" }?.value as? URLSessionWebSocketTask
            )
            sizes[path] = task.maximumMessageSize
            await connection.cancel()
        }
        #expect(URLSessionWebSocketConnectionFactory.maximumMessageBytes == 4_194_304)
        #expect(sizes["request"] == URLSessionWebSocketConnectionFactory.maximumMessageBytes)
        #expect(sizes["protocols"] == URLSessionWebSocketConnectionFactory.maximumMessageBytes)
    }
}
