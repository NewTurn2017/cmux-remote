import Foundation

public struct TerminalArtifactFetchRequest: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Byte offset requested by the client.
    public var offset: Int

    /// Creates a fetch request.
    public init(artifactId: String, offset: Int) {
        self.artifactId = artifactId; self.offset = offset
    }
    private enum CodingKeys: String, CodingKey { case artifactId, offset }

    /// Decodes and validates a fetch request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.artifactId), let artifactId = try? c.decode(String.self, forKey: .artifactId), !artifactId.isEmpty else { throw RemoteProtocolError.missingField("artifact_id") }
        guard c.contains(.offset), let offset = try? c.decode(Int.self, forKey: .offset) else { throw RemoteProtocolError.invalidField("offset") }
        guard offset >= 0 else { throw RemoteProtocolError.negativeOffset }
        self.init(artifactId: artifactId, offset: offset)
    }
}

/// One bounded response chunk from `terminal.artifact.fetch`.
