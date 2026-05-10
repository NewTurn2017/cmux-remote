import XCTest
import NIOCore
import NIOPosix
import SharedKit
@testable import CMUXClient

final class LiveSocketSmokeTests: XCTestCase {
    func testWorkspaceListAgainstRealCmux() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CMUX_LIVE"] != "1",
                      "set CMUX_LIVE=1 to run")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let chan = try await UnixSocketChannel(path: cmuxSocketPath(), group: group)
            .connect { _ in group.next().makeSucceededFuture(()) }
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(5))
        let workspaces = try await client.workspaceList()
        print("live workspaces: \(workspaces.map(\.name))")
        XCTAssertNotNil(workspaces)
    }
}
