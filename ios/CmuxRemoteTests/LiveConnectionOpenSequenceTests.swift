import Testing
@testable import CmuxRemote

@Suite
struct LiveConnectionOpenSequenceTests {
    @Test @MainActor
    func immediateOpenCompletesInitializationBeforeInitialRefreshes() async {
        var events: [String] = []

        await LiveRelaySession.runOpenSequence(
            sendHello: { events.append("hello") },
            initializeRemoteFiles: { events.append("remote-files") },
            resubscribeSurface: { events.append("surface-resubscribe") },
            refreshWorkspace: { events.append("workspace.list") },
            refreshHost: { events.append("host.battery") }
        )

        #expect(events == [
            "hello",
            "remote-files",
            "surface-resubscribe",
            "workspace.list",
            "host.battery",
        ])
    }

    @Test @MainActor
    func reconnectRunsWorkspaceAndHostRefreshOncePerOpen() async {
        var workspaceRefreshCount = 0
        var hostRefreshCount = 0
        var surfaceResubscribeCount = 0

        for _ in 0..<2 {
            await LiveRelaySession.runOpenSequence(
                sendHello: {},
                initializeRemoteFiles: {},
                resubscribeSurface: { surfaceResubscribeCount += 1 },
                refreshWorkspace: { workspaceRefreshCount += 1 },
                refreshHost: { hostRefreshCount += 1 }
            )
        }

        #expect(surfaceResubscribeCount == 2)
        #expect(workspaceRefreshCount == 2)
        #expect(hostRefreshCount == 2)
    }
}
