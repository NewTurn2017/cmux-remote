import Foundation
import SharedKit
import Testing
@testable import RelayServer

/// Records, without changing it, what the production output bound does with large
/// `terminal.artifact.fetch` responses. The relay's default fetch chunk is 3 MiB of data.
@Suite("WebSocketOutputPumpFetchSizeTests")
struct WebSocketOutputPumpFetchSizeTests {
    struct Observed: Equatable, CustomStringConvertible {
        let rawBytes: Int
        let framedBytes: Int
        let written: Bool
        let closed: Bool

        var description: String {
            "raw=\(rawBytes) framed=\(framedBytes) written=\(written) closed=\(closed)"
        }
    }

    @Test func characterizesArtifactFetchResponsesAgainstTheOutputQueueBound() throws {
        let bound = WebSocketHandler.defaultMaximumQueuedOutputBytes
        #expect(bound == 2 * 1_024 * 1_024)
        #expect(TerminalArtifactService.maximumFetchBytes == 3 * 1_024 * 1_024)

        let observed = try [1_024 * 1_024, 1_536 * 1_024, TerminalArtifactService.maximumFetchBytes].map { rawBytes in
            let text = try Self.fetchResponseText(rawBytes: rawBytes)
            let channel = ControllableWebSocketOutputChannel()
            let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: bound)
            pump.enqueueCritical(text)
            let framed = try WebSocketFramedSize(text: text).totalBytes
            return Observed(
                rawBytes: rawBytes,
                framedBytes: framed,
                written: channel.writtenTexts == [text],
                closed: pump.isClosed && channel.closeCount == 1
            )
        }
        for item in observed {
            print("FETCH_SIZE_CHARACTERIZATION \(item)")
        }

        #expect(observed.map(\.written) == [true, false, false])
        #expect(observed.map(\.closed) == [false, true, true])
        #expect(observed[0].framedBytes <= bound)
        #expect(observed[1].framedBytes > bound)
        #expect(observed[2].framedBytes > bound)
    }

    private static func fetchResponseText(rawBytes: Int) throws -> String {
        let chunk = TerminalArtifactFetchResult(
            artifactId: "artifact-id",
            offset: 0,
            totalBytes: rawBytes,
            revision: "revision-1",
            dataBase64: Data(count: rawBytes).base64EncodedString(),
            eof: true
        )
        let result = try JSONDecoder().decode(JSONValue.self, from: SharedKitJSON.snakeCaseEncoder.encode(chunk))
        return WSProtocolMachine.encodeForHandler(RPCResponse(id: "fetch", ok: true, result: result))
    }
}
