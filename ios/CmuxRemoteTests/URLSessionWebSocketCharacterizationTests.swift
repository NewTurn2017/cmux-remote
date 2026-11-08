import Foundation
import Testing
@testable import CmuxRemote

/// Records, without changing it, the receive limit of the WebSocket task the app creates.
@Suite("URLSessionWebSocketCharacterizationTests")
struct URLSessionWebSocketCharacterizationTests {
    @Test
    func characterizesDefaultMaximumMessageSizeOfAppWebSocketTask() async throws {
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
        print("characterization: URLSessionWebSocketTask.maximumMessageSize request=\(sizes["request"] ?? -1) protocols=\(sizes["protocols"] ?? -1)")
        #expect(sizes["request"] == 1_048_576)
        #expect(sizes["protocols"] == 1_048_576)
    }
}
