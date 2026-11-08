import Foundation
import SharedKit

struct TextDocument: Equatable, Sendable {
    let artifactId: String
    let filename: String
    let revision: String
    let text: String
    let rawPrefix: Data
    let totalBytes: Int

    var displayedBytes: Int { rawPrefix.count }
    var isTruncated: Bool { displayedBytes < totalBytes }
}

enum TextArtifactLoaderError: Error, Equatable {
    case malformedChunk
    case fileChanged
}

/// Reads an authorized artifact through `terminal.artifact.fetch` and keeps at
/// most `displayLimitBytes`. The fetch contract has no length parameter, so the
/// chunk that crosses the limit is received whole and cut locally.
struct TextArtifactLoader: Sendable {
    static let displayLimitBytes = 2 * 1024 * 1024

    let rpc: any RPCDispatch
    var displayLimit: Int = TextArtifactLoader.displayLimitBytes

    func load(_ artifact: TerminalArtifact) async throws -> TextDocument {
        var collected = Data()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let response = try await rpc.call(
                method: RemoteRPCMethod.artifactFetch.rawValue,
                params: .object([
                    "artifact_id": .string(artifact.artifactId),
                    "offset": .int(Int64(offset)),
                ])
            )
            try Task.checkCancellation()
            let chunk: TerminalArtifactFetchResult
            do {
                chunk = try response.unwrapResult().decode(TerminalArtifactFetchResult.self)
            } catch let error as CmuxRemoteRPCError {
                throw error
            } catch {
                throw TextArtifactLoaderError.malformedChunk
            }
            let data: Data
            do { data = try chunk.decodedBytes() } catch { throw TextArtifactLoaderError.malformedChunk }
            guard chunk.revision == artifact.revision, chunk.totalBytes == artifact.bytes else {
                throw TextArtifactLoaderError.fileChanged
            }
            let nextOffset = offset + data.count
            guard chunk.artifactId == artifact.artifactId,
                  chunk.offset == offset,
                  chunk.eof || !data.isEmpty,
                  nextOffset <= chunk.totalBytes,
                  chunk.eof == (nextOffset == chunk.totalBytes)
            else { throw TextArtifactLoaderError.malformedChunk }

            collected.append(data.prefix(max(0, displayLimit - collected.count)))
            offset = nextOffset
            if chunk.eof || collected.count >= displayLimit { break }
        }

        let isTruncated = collected.count < artifact.bytes
        let kept = isTruncated ? UTF8Boundary.trimmingIncompleteSuffix(collected) : collected
        return TextDocument(
            artifactId: artifact.artifactId,
            filename: artifact.filename,
            revision: artifact.revision,
            text: String(decoding: kept, as: UTF8.self),
            rawPrefix: kept,
            totalBytes: artifact.bytes
        )
    }
}
