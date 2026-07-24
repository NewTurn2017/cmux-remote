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

        XCTAssertEqual(KeyEncoder.encode(key), "ctrl-c")
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
    func testLiveInputTranslatorMapsTextNewlineAndDelete() {
        let text = LiveTerminalInputTranslator.interpret(replacementText: "hello")
        XCTAssertEqual(text, [.text("hello")])

        let newline = LiveTerminalInputTranslator.interpret(replacementText: "\n")
        XCTAssertEqual(newline, [.key(.enter)])

        let delete = LiveTerminalInputTranslator.interpretDeletion(count: 2)
        XCTAssertEqual(delete, [.key(.backspace), .key(.backspace)])
    }

    func testLiveInputTranslatorSuppressesHangulImmediateSend() {
        XCTAssertEqual(LiveTerminalInputTranslator.interpret(replacementText: "ㅎ"), [])
        XCTAssertEqual(LiveTerminalInputTranslator.interpret(replacementText: "한"), [])
        XCTAssertEqual(LiveTerminalInputTranslator.interpret(replacementText: "hello한"), [])
        XCTAssertTrue(LiveTerminalInputTranslator.containsHangul("한글"))
        XCTAssertTrue(LiveTerminalInputTranslator.containsHangul("ㅎㅏㄴ"))
        XCTAssertFalse(LiveTerminalInputTranslator.containsHangul("hello"))
        XCTAssertFalse(LiveTerminalInputTranslator.shouldUseLocalEditing(currentText: "$ ", replacementText: "a"))
        XCTAssertTrue(LiveTerminalInputTranslator.shouldUseLocalEditing(currentText: "$ ", replacementText: "한"))
        XCTAssertTrue(LiveTerminalInputTranslator.shouldUseLocalEditing(currentText: "$ 한", replacementText: ""))
    }

}
