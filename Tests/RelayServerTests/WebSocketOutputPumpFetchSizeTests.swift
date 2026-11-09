import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("WebSocketOutputPumpFetchSizeTests")
struct WebSocketOutputPumpFetchSizeTests {
    private static let shippedAppMessageLimit = 1_048_576

    @Test func largestFetchAndThumbnailResponsesStayUnderOneMiBAndAreWritten() throws {
        #expect(TerminalArtifactService.maximumFetchBytes == 737_280)
        #expect(TerminalArtifactService.maximumThumbnailBytes == 737_280)

        for (label, text) in [("fetch", try Self.fetchResponseText()), ("thumbnail", try Self.thumbnailResponseText())] {
            let framed = try WebSocketFramedSize(text: text).totalBytes
            let channel = ControllableWebSocketOutputChannel()
            let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: WebSocketHandler.defaultMaximumQueuedOutputBytes)
            pump.enqueueCritical(text)
            print("RESPONSE_FRAME_SIZE \(label) framed=\(framed) limit=\(Self.shippedAppMessageLimit)")

            #expect(framed < Self.shippedAppMessageLimit)
            #expect(channel.writtenTexts == [text])
            #expect(!pump.isClosed)
            #expect(channel.closeCount == 0)
        }
    }

    private static let longIdentifier = String(repeating: "f", count: 64)

    private static func fetchResponseText() throws -> String {
        let chunk = TerminalArtifactFetchResult(
            artifactId: longIdentifier,
            offset: Int(TerminalArtifactService.maximumImageBytes),
            totalBytes: Int(TerminalArtifactService.maximumImageBytes) + TerminalArtifactService.maximumFetchBytes,
            revision: longIdentifier,
            dataBase64: Data(count: TerminalArtifactService.maximumFetchBytes).base64EncodedString(),
            eof: true
        )
        return try responseText(chunk)
    }

    private static func thumbnailResponseText() throws -> String {
        let thumbnail = TerminalArtifactThumbnailResult(
            artifactId: longIdentifier,
            revision: longIdentifier,
            dimension: TerminalArtifactLimits.maxThumbnailDimension,
            width: TerminalArtifactLimits.maxThumbnailDimension,
            height: TerminalArtifactLimits.maxThumbnailDimension,
            mimeType: "image/jpeg",
            dataBase64: Data(count: TerminalArtifactService.maximumThumbnailBytes).base64EncodedString()
        )
        return try responseText(thumbnail)
    }

    private static func responseText<Result: Encodable>(_ value: Result) throws -> String {
        let result = try JSONDecoder().decode(JSONValue.self, from: SharedKitJSON.snakeCaseEncoder.encode(value))
        return WSProtocolMachine.encodeForHandler(RPCResponse(id: longIdentifier, ok: true, result: result))
    }
}
