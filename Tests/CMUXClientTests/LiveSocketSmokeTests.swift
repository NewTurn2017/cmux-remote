import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import CMUXClient

@Suite("LiveSocketSmokeTests")
struct LiveSocketSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_LIVE"] == "1"))
    func workspaceListAgainstRealCmux() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var channel: Channel?
        do {
            let connectedChannel = try await UnixSocketChannel(path: cmuxSocketPath(), group: group)
                .connect { _ in group.next().makeSucceededFuture(()) }
            channel = connectedChannel
            let client = CMUXClient(channel: connectedChannel, requestTimeout: .seconds(5))
            try await client.awaitReady()
            let workspaces = try await client.workspaceList()
            print("live workspaces: \(workspaces.map(\.name))")
            try await connectedChannel.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await channel?.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
