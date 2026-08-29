import Foundation

public struct ChunkUploadChunkRequest: Codable, Sendable, Equatable {
    /// Upload identifier returned by begin.
    public var uploadId: String
    /// Byte offset at which this chunk must be written.
    public var offset: Int
    /// Canonical base64-encoded raw bytes.
    public var dataBase64: String

    /// Creates a chunk request.
    public init(uploadId: String, offset: Int, dataBase64: String) {
        self.uploadId = uploadId
        self.offset = offset
        self.dataBase64 = dataBase64
    }

    /// The decoded chunk bytes, when the base64 payload is valid.
    ///
    /// - Returns: Decoded bytes.
    /// - Throws: ``RemoteProtocolError`` for malformed or oversized data.
    public func decodedBytes() throws -> Data {
        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty,
              data.base64EncodedString() == dataBase64 else { throw RemoteProtocolError.invalidBase64 }
        guard data.count <= ChunkUploadLimits.rawChunkBytes else {
            throw RemoteProtocolError.chunkTooLarge(maxBytes: ChunkUploadLimits.rawChunkBytes)
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case uploadId, offset, dataBase64
    }

    /// Decodes and validates a chunk request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.uploadId), let uploadId = try? c.decode(String.self, forKey: .uploadId), !uploadId.isEmpty else { throw RemoteProtocolError.missingField("upload_id") }
        guard c.contains(.offset), let offset = try? c.decode(Int.self, forKey: .offset) else { throw RemoteProtocolError.invalidField("offset") }
        guard offset >= 0 else { throw RemoteProtocolError.negativeOffset }
        guard c.contains(.dataBase64), let dataBase64 = try? c.decode(String.self, forKey: .dataBase64) else { throw RemoteProtocolError.missingField("data_base64") }
        self.init(uploadId: uploadId, offset: offset, dataBase64: dataBase64)
        _ = try decodedBytes()
    }
}

/// Server acknowledgement for `file.upload.chunk`.
