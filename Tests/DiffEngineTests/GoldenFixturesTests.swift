import Testing
import Foundation
import SharedKit
@testable import RelayCore

struct Fixture: Decodable {
    let before: Screen
    let after: Screen
    let expectedOps: [DiffOp]
    enum CodingKeys: String, CodingKey { case before, after, expectedOps = "expected_ops" }
}

@Suite("DiffEngine golden fixtures")
struct GoldenFixturesTests {
    static var allFixtureURLs: [URL] {
        let bundle = Bundle.module
        return (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(arguments: GoldenFixturesTests.allFixtureURLs)
    func reproducesExpectedOps(url: URL) throws {
        let data = try Data(contentsOf: url)
        let fix  = try JSONDecoder().decode(Fixture.self, from: data)
        var state = RowState()
        _ = state.ingest(snapshot: fix.before)
        let actual = state.ingest(snapshot: fix.after)
        #expect(actual == fix.expectedOps,
                "\(url.lastPathComponent): expected \(fix.expectedOps), got \(actual)")
    }
}
