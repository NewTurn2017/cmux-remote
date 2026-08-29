import Foundation

/// RPC method names owned by the remote file and terminal-artifact contracts.
public enum RemoteRPCMethod: String, Codable, Sendable, Equatable {
    /// Requests relay capability negotiation.
    case hostCapabilities = "host.capabilities"
    /// Starts a chunked upload.
    case uploadBegin = "file.upload.begin"
    /// Sends one upload chunk.
    case uploadChunk = "file.upload.chunk"
    /// Commits a complete upload.
    case uploadCommit = "file.upload.commit"
    /// Cancels an upload.
    case uploadCancel = "file.upload.cancel"
    /// Scans the active terminal for authorized artifacts.
    case artifactScan = "terminal.artifact.scan"
    /// Reads metadata for an authorized artifact.
    case artifactStat = "terminal.artifact.stat"
    /// Fetches one chunk of an authorized artifact.
    case artifactFetch = "terminal.artifact.fetch"
    /// Generates a bounded thumbnail for an authorized artifact.
    case artifactThumbnail = "terminal.artifact.thumbnail"
}

/// Capability identifiers exchanged by ``HostCapabilitiesResult``.
public struct HostCapabilities: Codable, Sendable, Equatable {
    /// The capability identifier for the v2 chunk-upload contract.
    public static let chunkUploadV2 = "file.upload.v2"
    /// The capability identifier for relay-native terminal artifacts.
    public static let terminalArtifactsV1 = "terminal.artifact.v1"
}

/// Empty parameters for `host.capabilities`.
public struct HostCapabilitiesRequest: Codable, Sendable, Equatable {
    /// Creates an empty capability request.
    public init() {}
}

/// Capabilities supported by the relay for additive remote features.
public struct HostCapabilitiesResult: Codable, Sendable, Equatable {
    /// Capability identifiers supported by the relay.
    public var capabilities: [String]

    /// The v2 chunk-upload capability identifier.
    public static let chunkUploadV2Capability = HostCapabilities.chunkUploadV2
    /// The relay-native terminal-artifact capability identifier.
    public static let terminalArtifactsV1Capability = HostCapabilities.terminalArtifactsV1

    /// Creates a capability result.
    ///
    /// - Parameter capabilities: Identifiers supported by the relay.
    public init(capabilities: [String]) {
        self.capabilities = capabilities
    }

    /// Whether v2 chunked uploads are supported.
    public var supportsChunkUploadV2: Bool {
        capabilities.contains(Self.chunkUploadV2Capability)
    }

    /// Whether relay-native terminal artifacts are supported.
    public var supportsTerminalArtifactsV1: Bool {
        capabilities.contains(Self.terminalArtifactsV1Capability)
    }
}

/// Structured validation failures returned by remote contract decoding.
public enum RemoteProtocolError: Error, Sendable, Equatable {
    /// A required wire field was absent.
    case missingField(String)
    /// A field was present but had an invalid value or type.
    case invalidField(String)
    /// An offset was below zero.
    case negativeOffset
    /// A chunk exceeded the contract's raw-byte limit.
    case chunkTooLarge(maxBytes: Int)
    /// A base64 field was not canonical base64.
    case invalidBase64
    /// A thumbnail dimension was outside the contract's supported range.
    case invalidThumbnailDimension
}

/// Known structured RPC error codes, preserving unknown future codes.
public enum RemoteErrorCode: Sendable, Equatable, Codable {
    /// The request was malformed.
    case invalidRequest
    /// A required field was absent.
    case missingField
    /// A field failed validation.
    case invalidField
    /// The upload offset did not match server state.
    case invalidOffset
    /// The upload chunk exceeded the raw limit.
    case chunkTooLarge
    /// The declared upload exceeded a file or batch limit.
    case sizeLimitExceeded
    /// The upload hash did not match.
    case hashMismatch
    /// The artifact authorization expired or was not valid for this request.
    case forbidden
    /// The artifact no longer matches its authorized revision.
    case fileChanged
    /// The requested artifact does not exist.
    case notFound
    /// The requested RPC method is unavailable.
    case methodNotFound
    /// An upload identifier was reused with conflicting metadata.
    case uploadConflict
    /// The upload identifier was not found.
    case uploadNotFound
    /// A base64 field was malformed.
    case invalidBase64
    /// A hash field was malformed.
    case invalidHash
    /// An authorization or upload lease expired.
    case expired
    /// The requested media type is unsupported.
    case unsupportedMedia
    /// A code unknown to this client version.
    case unknown(String)

    /// The snake_case code sent on the wire.
    public var rawValue: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .missingField: return "missing_field"
        case .invalidField: return "invalid_field"
        case .invalidOffset: return "invalid_offset"
        case .chunkTooLarge: return "chunk_too_large"
        case .sizeLimitExceeded: return "size_limit_exceeded"
        case .hashMismatch: return "hash_mismatch"
        case .forbidden: return "forbidden"
        case .fileChanged: return "file_changed"
        case .notFound: return "not_found"
        case .methodNotFound: return "method_not_found"
        case .uploadConflict: return "upload_conflict"
        case .uploadNotFound: return "upload_not_found"
        case .invalidBase64: return "invalid_base64"
        case .invalidHash: return "invalid_hash"
        case .expired: return "expired"
        case .unsupportedMedia: return "unsupported_media"
        case .unknown(let rawValue): return rawValue
        }
    }

    /// Decodes a known code and retains unknown codes for forward compatibility.
    ///
    /// - Parameter rawValue: The wire error code.
    public init(rawValue: String) {
        switch rawValue {
        case "invalid_request": self = .invalidRequest
        case "missing_field": self = .missingField
        case "invalid_field": self = .invalidField
        case "invalid_offset": self = .invalidOffset
        case "chunk_too_large": self = .chunkTooLarge
        case "size_limit_exceeded": self = .sizeLimitExceeded
        case "hash_mismatch": self = .hashMismatch
        case "forbidden": self = .forbidden
        case "file_changed": self = .fileChanged
        case "not_found": self = .notFound
        case "method_not_found": self = .methodNotFound
        case "upload_conflict": self = .uploadConflict
        case "upload_not_found": self = .uploadNotFound
        case "invalid_base64": self = .invalidBase64
        case "invalid_hash": self = .invalidHash
        case "expired": self = .expired
        case "unsupported_media": self = .unsupportedMedia
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes an error code from its wire string.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: value)
    }

    /// Encodes the error code as its deterministic wire string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RPCError: Error {}

extension RPCRequest {
    /// Creates an RPC envelope from an encodable typed payload.
    ///
    /// - Parameters:
    ///   - id: The request correlation identifier.
    ///   - method: The method name on the wire.
    ///   - payload: The method-specific parameters.
    /// - Throws: An encoding error when the payload cannot be represented as JSON.
    public init<Payload: Encodable>(id: String, method: String, payload: Payload) throws {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(payload)
        let params = try JSONDecoder().decode(JSONValue.self, from: data)
        self.init(id: id, method: method, params: params)
    }
}

extension RPCResponse {
    /// Decodes a successful method result into its typed payload.
    ///
    /// - Parameter type: The expected result type.
    /// - Returns: The decoded result.
    /// - Throws: The response RPC error, a missing-result error, or a decoding error.
    public func decodeResult<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        if let error {
            throw error
        }
        guard let result else {
            throw RemoteProtocolError.invalidField("result")
        }
        let data = try SharedKitJSON.snakeCaseEncoder.encode(result)
        return try SharedKitJSON.snakeCaseDecoder.decode(Payload.self, from: data)
    }
}
