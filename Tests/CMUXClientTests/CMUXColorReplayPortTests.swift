import Foundation
import SharedKit
import Testing
@testable import CMUXClient

@Suite("CMUX color replay port")
struct CMUXColorReplayPortTests {
    @Test func renderGridWinsOverLegacyTextAndEmitsCanonicalGreenTruecolor() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "terminal-replay-34-styles",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(
            CMUXReadTextRaw.self,
            from: Data(contentsOf: fixtureURL)
        )

        let screen = raw.toScreen(rev: 1)

        #expect(screen.rows.count == 5)
        #expect(screen.rows.contains {
            $0.contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m")
        })
    }
}
