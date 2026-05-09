import XCTest
import NIOCore
import NIOEmbedded
@testable import CMUXClient

final class LineFramerTests: XCTestCase {
    func testDecodesSingleLine() throws {
        let chan = EmbeddedChannel(handler: LineFrameDecoder())
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        buf.writeString("{\"x\":1}\n")
        try chan.writeInbound(buf)
        let line: ByteBuffer = try XCTUnwrap(try chan.readInbound())
        XCTAssertEqual(line.getString(at: 0, length: line.readableBytes), "{\"x\":1}")
    }

    func testBuffersAcrossWrites() throws {
        let chan = EmbeddedChannel(handler: LineFrameDecoder())
        var a = ByteBufferAllocator().buffer(capacity: 8); a.writeString("{\"a\"")
        var b = ByteBufferAllocator().buffer(capacity: 8); b.writeString(":1}\n{\"b\":2}\n")
        try chan.writeInbound(a)
        XCTAssertNil(try chan.readInbound() as ByteBuffer?)
        try chan.writeInbound(b)
        let first: ByteBuffer  = try XCTUnwrap(try chan.readInbound())
        let second: ByteBuffer = try XCTUnwrap(try chan.readInbound())
        XCTAssertEqual(first.getString(at: 0, length: first.readableBytes), "{\"a\":1}")
        XCTAssertEqual(second.getString(at: 0, length: second.readableBytes), "{\"b\":2}")
    }

    func testEncoderAppendsNewline() throws {
        let chan = EmbeddedChannel(handler: LineFrameEncoder())
        var buf = ByteBufferAllocator().buffer(capacity: 8); buf.writeString("hi")
        try chan.writeOutbound(buf)
        let out: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        XCTAssertEqual(out.getString(at: 0, length: out.readableBytes), "hi\n")
    }
}
