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

    @Test func eventCategoriesIncludeAgentAndHookForNeedsInputSubscriptions() {
        #expect(EventCategory.allCases.contains(.agent))
        #expect(EventCategory.allCases.contains(.hook))
        #expect(!EventCategory.allCases.contains(.unknown))
    }

    @Test func surfaceDecodesWithoutType() throws {
        let json = #"{"id":"s1","title":"shell","index":0}"#
        let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
        #expect(surface == Surface(id: "s1", title: "shell", index: 0))
        #expect(surface.type == nil)
    }

    @Test func surfaceDecodesWithType() throws {
        let json = #"{"id":"s2","title":"docs","index":1,"type":"browser"}"#
        let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
        #expect(surface.type == "browser")
        let data = try SharedKitJSON.deterministicEncoder.encode(surface)
        #expect(try JSONDecoder().decode(Surface.self, from: data) == surface)
    }

    @Test func surfaceNilTypeOmitsKey() throws {
        let data = try SharedKitJSON.deterministicEncoder.encode(Surface(id: "s1", title: "shell", index: 0))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] == nil)
        #expect(Set(object.keys) == ["id", "title", "index"])
    }

    @Test func surfaceIsTerminalForNilAndTerminalOnly() {
        #expect(Surface(id: "a", title: "", index: 0).isTerminal)
        #expect(Surface(id: "a", title: "", index: 0, type: "terminal").isTerminal)
        #expect(!Surface(id: "a", title: "", index: 0, type: "browser").isTerminal)
        #expect(!Surface(id: "a", title: "", index: 0, type: "markdown").isTerminal)
        #expect(!Surface(id: "a", title: "", index: 0, type: "future-kind").isTerminal)
    }
}
