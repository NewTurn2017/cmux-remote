import XCTest
import SharedKit
@testable import RelayServer

final class SurfaceHistoryServiceTests: XCTestCase {
    func testPagesOlderRowsWithAnOpaqueStableCursor() async throws {
        let facade = HistoryCMUXFacade(rows: (0...6).map { "line-\($0)" })
        let service = SurfaceHistoryService(cmux: facade)

        let first = try await service.page(
            workspaceId: "w",
            surfaceId: "s",
            cursor: nil,
            tailLines: 2,
            limit: 2
        )
        XCTAssertEqual(rows(in: first), ["line-3", "line-4"])
        XCTAssertEqual(anchorRows(in: first), ["line-5", "line-6"])
        let firstCursor = try XCTUnwrap(nextCursor(in: first))

        let second = try await service.page(
            workspaceId: "w",
            surfaceId: "s",
            cursor: firstCursor,
            tailLines: 2,
            limit: 2
        )
        XCTAssertEqual(rows(in: second), ["line-1", "line-2"])
        XCTAssertNil(anchorRows(in: second))
        let secondCursor = try XCTUnwrap(nextCursor(in: second))

        let third = try await service.page(
            workspaceId: "w",
            surfaceId: "s",
            cursor: secondCursor,
            tailLines: 2,
            limit: 2
        )
        XCTAssertEqual(rows(in: third), ["line-0"])
        XCTAssertNil(nextCursor(in: third))

        let calls = await facade.calls
        XCTAssertEqual(calls, 1, "later pages must be served from the same Mac snapshot")
    }

    func testCursorCannotBeReusedForAnotherSurface() async throws {
        let service = SurfaceHistoryService(cmux: HistoryCMUXFacade(rows: ["a", "b", "c"]))
        let first = try await service.page(
            workspaceId: "w",
            surfaceId: "s",
            cursor: nil,
            tailLines: 1,
            limit: 1
        )
        let cursor = try XCTUnwrap(nextCursor(in: first))

        do {
            _ = try await service.page(
                workspaceId: "w",
                surfaceId: "other",
                cursor: cursor,
                tailLines: 1,
                limit: 1
            )
            XCTFail("a cursor must be bound to its source terminal")
        } catch SurfaceHistoryError.cursorExpired {
            // Expected.
        }
    }

    func testPrewarmMakesTheFirstPageReadOnlyTheCachedSnapshot() async throws {
        let facade = HistoryCMUXFacade(rows: ["one", "two", "three"])
        let service = SurfaceHistoryService(cmux: facade)

        await service.prewarm(workspaceId: "w", surfaceId: "s")
        _ = try await service.page(
            workspaceId: "w",
            surfaceId: "s",
            cursor: nil,
            tailLines: 1,
            limit: 1
        )

        let calls = await facade.calls
        XCTAssertEqual(calls, 1)
    }

    private func rows(in page: JSONValue) -> [String] {
        guard case .object(let values) = page,
              case .array(let rows)? = values["rows"]
        else { return [] }
        return rows.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    private func anchorRows(in page: JSONValue) -> [String]? {
        guard case .object(let values) = page else { return nil }
        guard case .array(let rows)? = values["anchor_rows"] else { return nil }
        return rows.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    private func nextCursor(in page: JSONValue) -> String? {
        guard case .object(let values) = page,
              case .string(let cursor)? = values["next_cursor"]
        else { return nil }
        return cursor
    }
}

private actor HistoryCMUXFacade: CMUXFacade {
    private let rows: [String]
    private(set) var calls = 0

    init(rows: [String]) {
        self.rows = rows
    }

    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls += 1
        XCTAssertEqual(method, "surface.read_text")
        return .object(["text": .string(rows.joined(separator: "\n"))])
    }
}
