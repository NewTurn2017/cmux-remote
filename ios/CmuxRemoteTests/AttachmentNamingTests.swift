import XCTest
import UniformTypeIdentifiers
@testable import CmuxRemote

final class AttachmentNamingTests: XCTestCase {
    func testSanitizedBasenameKeepsPlainName() {
        XCTAssertEqual(AttachmentNaming.sanitizedBasename("report.pdf"), "report.pdf")
    }

    func testSanitizedBasenameTakesLastPathComponent() {
        XCTAssertEqual(AttachmentNaming.sanitizedBasename("a/b/c.txt"), "c.txt")
    }

    func testSanitizedBasenamePreventsTraversal() {
        XCTAssertEqual(AttachmentNaming.sanitizedBasename("../../etc/passwd"), "passwd")
    }

    func testSanitizedBasenameStripsControlChars() {
        XCTAssertEqual(AttachmentNaming.sanitizedBasename("a\nb\t.txt"), "ab.txt")
    }

    func testSanitizedBasenameFallsBackToFile() {
        XCTAssertEqual(AttachmentNaming.sanitizedBasename(""), "file")
        XCTAssertEqual(AttachmentNaming.sanitizedBasename("///"), "file")
    }

    func testTimestampedFilenameFormat() {
        let name = AttachmentNaming.timestampedFilename(originalName: "../x/report.pdf", date: Date())
        XCTAssertNotNil(
            name.range(of: #"^\d{8}-\d{6}-report\.pdf$"#, options: .regularExpression),
            "unexpected filename: \(name)"
        )
    }

    func testMimeTypeFromUTType() {
        XCTAssertEqual(AttachmentNaming.mimeType(for: .pdf), "application/pdf")
        XCTAssertEqual(AttachmentNaming.mimeType(for: .plainText), "text/plain")
    }

    func testMimeTypeFallsBackWhenNil() {
        XCTAssertEqual(AttachmentNaming.mimeType(for: nil), "application/octet-stream")
    }
}
