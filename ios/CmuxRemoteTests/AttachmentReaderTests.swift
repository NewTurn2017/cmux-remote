import XCTest
@testable import CmuxRemote

final class AttachmentReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AttachmentReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func makeFile(byteCount: Int) throws -> URL {
        let url = directory.appendingPathComponent("payload-\(byteCount).bin")
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }

    func testReadsFileUnderLimit() throws {
        let url = try makeFile(byteCount: 1024)

        let data = try AttachmentReader.readBounded(from: url, limit: 4096)

        XCTAssertEqual(data?.count, 1024)
        XCTAssertEqual(data, Data(repeating: 0xAB, count: 1024))
    }

    func testReadsFileExactlyAtLimit() throws {
        let url = try makeFile(byteCount: 4096)

        let data = try AttachmentReader.readBounded(from: url, limit: 4096)

        XCTAssertEqual(data?.count, 4096)
    }

    func testReturnsNilWhenOneByteOverLimit() throws {
        let url = try makeFile(byteCount: 4097)

        let data = try AttachmentReader.readBounded(from: url, limit: 4096)

        XCTAssertNil(data)
    }

    // The point of the bounded read: a file far larger than the limit must not
    // be pulled into memory before we reject it.
    func testDoesNotBufferFarBeyondLimitForOversizedFile() throws {
        let url = try makeFile(byteCount: 1 << 20)

        let data = try AttachmentReader.readBounded(from: url, limit: 1024)

        XCTAssertNil(data)
    }

    func testReadsEmptyFile() throws {
        let url = try makeFile(byteCount: 0)

        let data = try AttachmentReader.readBounded(from: url, limit: 4096)

        XCTAssertEqual(data, Data())
    }

    func testThrowsWhenFileMissing() throws {
        let missing = directory.appendingPathComponent("does-not-exist.bin")

        XCTAssertThrowsError(try AttachmentReader.readBounded(from: missing, limit: 4096))
    }
}
