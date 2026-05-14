import XCTest
import SharedKit
@testable import CmuxRemote

final class CommandComposerTests: XCTestCase {
    func testSubmitSendsNewlineAndRecordsHistory() async {
        var composer = CommandComposer()
        composer.draft = "ls -alh"
        var sent: [String] = []

        await composer.submit { text in sent.append(text) }

        XCTAssertEqual(sent, ["ls -alh\n"])
        XCTAssertEqual(composer.history, ["ls -alh"])
        XCTAssertEqual(composer.draft, "")
        XCTAssertFalse(composer.isSending)
    }

    func testHistoryNavigation() async {
        var composer = CommandComposer()
        composer.draft = "pwd"
        await composer.submit { _ in }
        composer.draft = "git status"
        await composer.submit { _ in }

        composer.previousHistory()
        XCTAssertEqual(composer.draft, "git status")
        composer.previousHistory()
        XCTAssertEqual(composer.draft, "pwd")
        composer.nextHistory()
        XCTAssertEqual(composer.draft, "git status")
        composer.nextHistory()
        XCTAssertEqual(composer.draft, "")
    }

    func testModifierKeyIsOneShot() {
        var composer = CommandComposer()
        composer.toggle(.ctrl)

        let key = composer.key("c")

        XCTAssertEqual(KeyEncoder.encode(key), "ctrl+c")
        XCTAssertEqual(composer.activeModifiers, [])
    }

    func testPasteAppendsDraft() {
        var composer = CommandComposer()
        composer.draft = "echo "

        composer.paste("hello")

        XCTAssertEqual(composer.draft, "echo hello")
    }

    func testSubmitFailureKeepsDraftAndReportsError() async {
        enum SendFailure: Error { case offline }
        var composer = CommandComposer()
        composer.draft = "date"

        await composer.submit { _ in throw SendFailure.offline }

        XCTAssertEqual(composer.draft, "date")
        XCTAssertFalse(composer.isSending)
        XCTAssertNotNil(composer.errorMessage)
        XCTAssertEqual(composer.history, [])
    }
}
