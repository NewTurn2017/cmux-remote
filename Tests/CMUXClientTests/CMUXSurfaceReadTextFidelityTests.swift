import Foundation
import Testing
import SharedKit
@testable import CMUXClient

@Suite("CMUXSurfaceReadTextFidelityTests")
struct CMUXSurfaceReadTextFidelityTests {
    @Test func requested200StillRetainsOnly120CombinedRows() async throws {
        let scrollbackSpans = (0..<125).map { row in
            "{\"row\":\(row),\"column\":0,\"style_id\":0,\"text\":\"history \(row)\"}"
        }.joined(separator: ",")
        let payload = RenderGridTestSupport.responseJSON(
            columns: 16,
            rows: 2,
            cursorRow: 1,
            cursorColumn: 2,
            rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"viewport 0"},{"row":1,"column":0,"style_id":0,"text":"viewport 1"}]"#,
            scrollbackRows: 125,
            scrollbackSpans: "[\(scrollbackSpans)]"
        )

        let (screen, request) = try await Self.readScreen(lines: 200, payload: payload)

        #expect(request.params == .object([
            "workspace_id": .string("workspace"),
            "surface_id": .string("surface"),
            "lines": .int(200),
        ]))
        print("requestedLines=200 retainedCombinedRows=\(screen.rows.count) cursor=\(screen.cursor.x),\(screen.cursor.y)")
        #expect(screen.rows.count == 120)
        #expect(RenderGridTestSupport.visibleText(screen.rows[0]) == "history 7")
        #expect(RenderGridTestSupport.visibleText(screen.rows[117]) == "history 124")
        #expect(RenderGridTestSupport.visibleText(screen.rows[118]) == "viewport 0")
        #expect(RenderGridTestSupport.visibleText(screen.rows[119]) == "viewport 1")
        #expect(screen.cursor == CursorPos(x: 2, y: 119))
    }

    @Test func requested200StillCapsViewportLargerThan120() async throws {
        let payload = RenderGridTestSupport.responseJSON(
            columns: 8,
            rows: 121,
            cursorRow: 120,
            cursorColumn: 3,
            rowSpans: #"[{"row":120,"column":0,"style_id":0,"text":"tail"}]"#
        )

        let (screen, request) = try await Self.readScreen(lines: 200, payload: payload)

        #expect(request.params == .object([
            "workspace_id": .string("workspace"),
            "surface_id": .string("surface"),
            "lines": .int(200),
        ]))
        print("requestedLines=200 viewportRows=121 retainedRows=\(screen.rows.count) tailCursor=\(screen.cursor.x),\(screen.cursor.y)")
        #expect(screen.rows.count == 120)
        #expect(RenderGridTestSupport.visibleText(screen.rows[119]) == "tail")
        #expect(screen.cursor == CursorPos(x: 3, y: 119))
    }

    @Test func availableRowsBelowRetentionLimitAreNotSynthesized() async throws {
        let payload = RenderGridTestSupport.responseJSON(
            columns: 8,
            rows: 2,
            cursorRow: 1,
            cursorColumn: 2,
            rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"one"},{"row":1,"column":0,"style_id":0,"text":"two"}]"#
        )

        let (screen, _) = try await Self.readScreen(lines: 200, payload: payload)

        print("availableRows=2 retainedRows=\(screen.rows.count) synthesizedRows=false")
        #expect(screen.rows.count == 2)
        #expect(screen.cursor == CursorPos(x: 2, y: 1))
    }

    @Test func negativeRequestedLinesRejectBeforeRPC() async throws {
        let fixture = try await MTELGCmuxFixture.make(requestTimeout: .milliseconds(50))
        do {
            _ = try await fixture.client.surfaceReadText(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: -1
            )
            Issue.record("negative line count must reject")
        } catch CMUXClientError.decoding(let message) {
            print("malformedLinesRejected=true error=\(message)")
            #expect(message.contains("lines"))
        } catch {
            Issue.record("expected line-count decoding error, got \(error)")
        }
        await fixture.shutdown()
    }

    static func readScreen(lines: Int, payload: Data) async throws -> (Screen, RPCRequest) {
        let fixture = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        do {
            async let pendingScreen = fixture.client.surfaceReadText(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: lines
            )
            let requestLine = try await fixture.awaitRequestLine()
            let request = try SharedKitJSON.snakeCaseDecoder.decode(
                RPCRequest.self,
                from: Data(requestLine.utf8)
            )
            let result = try SharedKitJSON.snakeCaseDecoder.decode(JSONValue.self, from: payload)
            let response = RPCResponse(id: request.id, result: result)
            let responseData = try SharedKitJSON.deterministicEncoder.encode(response)
            let responseLine = try #require(String(data: responseData, encoding: .utf8))
            try await fixture.sendToClient(line: responseLine)
            let screen = try await pendingScreen
            await fixture.shutdown()
            return (screen, request)
        } catch {
            await fixture.shutdown()
            throw error
        }
    }
}
