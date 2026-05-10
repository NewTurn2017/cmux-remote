import Testing
import Foundation
@testable import SharedKit

@Suite("Models")
struct ModelsTests {
    @Test func workspaceRoundTrip() throws {
        let ws = Workspace(id: "EC6D3886-5A82-41EB-B5B7-61AF2FDBF621",
                           name: "frontend",
                           index: 0)
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back == ws)
    }

    @Test func surfaceRoundTrip() throws {
        let sf = Surface(id: "B79A6DD6-7BD4-43AF-9853-A805659C1DBC",
                         title: "shell",
                         index: 2)
        let data = try JSONEncoder().encode(sf)
        let back = try JSONDecoder().decode(Surface.self, from: data)
        #expect(back == sf)
    }

    @Test func notificationRoundTrip() throws {
        let n = NotificationRecord(
            id: "n-1", workspaceId: "ws-1", surfaceId: "sf-1",
            title: "Build done", subtitle: "ws/frontend", body: "✅ tests green",
            ts: 1714000000, threadId: "ws-ws-1"
        )
        let data = try JSONEncoder().encode(n)
        let back = try JSONDecoder().decode(NotificationRecord.self, from: data)
        #expect(back == n)
    }

    @Test func bootInfoRoundTrip() throws {
        let b = BootInfo(bootId: "b-7", startedAt: 1714000000)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(BootInfo.self, from: data)
        #expect(back == b)
    }
}
