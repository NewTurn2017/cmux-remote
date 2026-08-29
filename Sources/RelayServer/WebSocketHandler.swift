import Foundation
import NIOCore
import NIOWebSocket
@_spi(RelayServer) import RelayCore
import SharedKit
import Logging

// MARK: - CMUX dispatch facade

/// Indirection so the WS handler can be wired against either the real
/// `CMUXClient` (M3.11) or a recording / throwing test double. The facade
/// owns "one round-trip RPC against the cmux daemon" — fan-out for events
/// is handled by EventStream + SessionManager.broadcastToAll.
public protocol CMUXFacade: Sendable {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue
}

// MARK: - Pure protocol machine

/// Pure WS protocol logic — Hello detection + RPC dispatch — separated
/// from the NIO channel so it can be unit-tested without an event loop.
/// The handler below applies the actions back onto the channel.
///
/// Plan task 10's tests used `EmbeddedChannel`, but the channel-bound
/// pattern hits the same `Task` drain deadlock we resolved for the
/// CMUXClient baseline tests. Splitting protocol-from-pipeline keeps
/// the unit suite fast and deterministic; the NIO glue is exercised
/// in M3.11's HTTPServer fixture and the M3.13 live smoke.
public actor WSProtocolMachine {
    public enum Action: Equatable, Sendable {
        case sendText(String)
        case close
        case attachSession(deviceId: String)
        case subscribe(responseId: String, workspaceId: String, surfaceId: String, lines: Int)
        case unsubscribe(responseId: String, surfaceId: String)
        /// Requests a hub-backed `screen.full` without another terminal source read.
        case requestFull(responseId: String, surfaceId: String)
        case noteUserInput(surfaceId: String)
    }

    private let cmux: CMUXFacade
    private let authenticatedDeviceID: String
    private let uploadService: ChunkedFileUploadService
    private let artifactService: TerminalArtifactService
    private let uploadIDSource: @Sendable () -> UUID
    private var helloed = false

    public init(cmux: CMUXFacade) {
        self.cmux = cmux
        self.authenticatedDeviceID = ""
        self.uploadService = ChunkedFileUploadService()
        self.artifactService = TerminalArtifactService(
            dispatchNative: { method, params in
                await Self.dispatchNative(cmux: cmux, method: method, params: params)
            }
        )
        self.uploadIDSource = { UUID() }
    }

    init(
        cmux: CMUXFacade,
        authenticatedDeviceID: String,
        uploadService: ChunkedFileUploadService,
        artifactService: TerminalArtifactService,
        uploadIDSource: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.cmux = cmux
        self.authenticatedDeviceID = authenticatedDeviceID
        self.uploadService = uploadService
        self.artifactService = artifactService
        self.uploadIDSource = uploadIDSource
    }

    public var hasHelloed: Bool { helloed }

    /// Drive the machine with one inbound text frame. Returns the actions
    /// the handler should apply to the channel (in order).
    public func processText(_ text: String) async -> [Action] {
        let data = Data(text.utf8)
        if !helloed {
            guard let hello = try? JSONDecoder().decode(HelloFrame.self, from: data) else {
                return [.close]
            }
            helloed = true
            return [.attachSession(deviceId: hello.deviceId)]
        }

        guard let req = try? JSONDecoder().decode(RPCRequest.self, from: data) else {
            return []
        }
        if let immediate = Self.synchronousRelayOwnedResponse(for: req) {
            return [.sendText(immediate)]
        }
        if let response = await relayOwnedResponse(for: req) {
            return [.sendText(response)]
        }
        if let relayAction = Self.relayOwnedAction(for: req) {
            return [relayAction]
        }

        do {
            let result = try await cmux.dispatch(method: req.method, params: req.params)
            let resp = RPCResponse(id: req.id, ok: true, result: result, error: nil)
            var actions: [Action] = [.sendText(Self.encode(resp))]
            if Self.isSuccessfulInput(req),
               case .object(let params) = req.params,
               case .string(let surfaceId)? = params["surface_id"]
            {
                actions.append(.noteUserInput(surfaceId: surfaceId))
            }
            return actions
        } catch {
            let err = RPCError(code: "internal_error",
                               message: String(describing: error))
            let resp = RPCResponse(id: req.id, ok: false, result: nil, error: err)
            return [.sendText(Self.encode(resp))]
        }
    }

    /// The 100ms hello timer fired. Returns `[.close]` if the peer never
    /// sent a hello, `[]` otherwise (handler will see nil and no-op).
    public func helloMissed() -> [Action] {
        helloed ? [] : [.close]
    }


    private static func synchronousRelayOwnedResponse(for req: RPCRequest) -> String? {
        switch req.method {
        case "host.battery":
            return encode(RPCResponse(id: req.id, ok: true, result: HostBatteryService.snapshot().json, error: nil))
        case "file.upload":
            do {
                let uploaded = try RelayFileUploadService.save(params: req.params)
                return encode(RPCResponse(id: req.id, ok: true, result: uploaded.json, error: nil))
            } catch {
                return encode(errorResponse(id: req.id, code: "upload_failed", message: String(describing: error)))
            }
        default:
            return nil
        }
    }

    private func relayOwnedResponse(for req: RPCRequest) async -> String? {
        guard let method = RemoteRPCMethod(rawValue: req.method) else { return nil }
        do {
            let result: JSONValue
            switch method {
            case .hostCapabilities:
                _ = try Self.decode(HostCapabilitiesRequest.self, from: req.params)
                result = try Self.jsonValue(
                    HostCapabilitiesResult(capabilities: [
                        HostCapabilitiesResult.chunkUploadV2Capability,
                        HostCapabilitiesResult.terminalArtifactsV1Capability,
                    ])
                )

            case .uploadBegin:
                let request = try Self.decode(ChunkUploadBeginRequest.self, from: req.params)
                guard request.bytes <= request.batchBytes else {
                    throw RemoteProtocolError.invalidField("batch_bytes")
                }
                let uploadID = uploadIDSource().uuidString.lowercased()
                let state = try await uploadService.begin(
                    authenticatedDeviceID: authenticatedDeviceID,
                    uploadID: uploadID,
                    batchID: request.batchId,
                    batchFileCount: request.batchFileCount,
                    batchBytes: Int64(request.batchBytes),
                    filename: request.filename,
                    mimeType: request.mimeType,
                    declaredBytes: Int64(request.bytes),
                    sha256: request.sha256
                )
                result = try Self.jsonValue(ChunkUploadBeginResult(
                    uploadId: state.uploadID,
                    batchId: request.batchId
                ))

            case .uploadChunk:
                let request = try Self.decode(ChunkUploadChunkRequest.self, from: req.params)
                let nextOffset = try await uploadService.chunk(
                    authenticatedDeviceID: authenticatedDeviceID,
                    uploadID: request.uploadId,
                    offset: Int64(request.offset),
                    dataBase64: request.dataBase64
                )
                result = try Self.jsonValue(ChunkUploadChunkResult(
                    uploadId: request.uploadId,
                    nextOffset: Int(nextOffset),
                    receivedBytes: Int(nextOffset)
                ))

            case .uploadCommit:
                let request = try Self.decode(ChunkUploadCommitRequest.self, from: req.params)
                let committed = try await uploadService.commit(
                    authenticatedDeviceID: authenticatedDeviceID,
                    uploadID: request.uploadId
                )
                result = try Self.jsonValue(ChunkUploadCommitResult(
                    uploadId: committed.uploadID,
                    filename: committed.filename,
                    path: committed.path,
                    bytes: Int(committed.bytes),
                    mimeType: committed.mimeType,
                    sha256: committed.sha256
                ))

            case .uploadCancel:
                let request = try Self.decode(ChunkUploadCancelRequest.self, from: req.params)
                try await uploadService.cancel(
                    authenticatedDeviceID: authenticatedDeviceID,
                    uploadID: request.uploadId
                )
                result = try Self.jsonValue(ChunkUploadCancelResult(uploadId: request.uploadId))

            case .artifactScan:
                let request = try Self.decode(TerminalArtifactScanRequest.self, from: req.params)
                guard !request.workspaceId.isEmpty else {
                    throw RemoteProtocolError.invalidField("workspace_id")
                }
                guard !request.surfaceId.isEmpty else {
                    throw RemoteProtocolError.invalidField("surface_id")
                }
                let scan = try await artifactService.scan(scope: .init(
                    deviceID: authenticatedDeviceID,
                    workspaceID: request.workspaceId,
                    surfaceID: request.surfaceId
                ))
                result = try Self.jsonValue(TerminalArtifactScanResult(
                    generation: scan.generation,
                    artifacts: scan.artifacts.map {
                        TerminalArtifact(
                            artifactId: $0.id,
                            filename: $0.displayName,
                            mimeType: $0.mimeType ?? "application/octet-stream",
                            bytes: Int($0.size),
                            revision: $0.revision,
                            isImage: $0.kind == "image"
                        )
                    }
                ))

            case .artifactStat:
                let request = try Self.decode(TerminalArtifactStatRequest.self, from: req.params)
                guard !request.artifactId.isEmpty else {
                    throw RemoteProtocolError.invalidField("artifact_id")
                }
                let stat = try await artifactService.stat(
                    deviceID: authenticatedDeviceID,
                    artifactID: request.artifactId
                )
                result = try Self.jsonValue(TerminalArtifactStatResult(
                    artifactId: request.artifactId,
                    filename: stat.displayName,
                    mimeType: stat.mimeType ?? "application/octet-stream",
                    bytes: Int(stat.size),
                    revision: stat.revision
                ))

            case .artifactFetch:
                let request = try Self.decode(TerminalArtifactFetchRequest.self, from: req.params)
                let chunk = try await artifactService.fetch(
                    deviceID: authenticatedDeviceID,
                    artifactID: request.artifactId,
                    offset: Int64(request.offset)
                )
                result = try Self.jsonValue(TerminalArtifactFetchResult(
                    artifactId: request.artifactId,
                    offset: Int(chunk.offset),
                    totalBytes: Int(chunk.totalSize),
                    revision: chunk.revision,
                    dataBase64: chunk.data.base64EncodedString(),
                    eof: chunk.eof
                ))

            case .artifactThumbnail:
                let request = try Self.decode(TerminalArtifactThumbnailRequest.self, from: req.params)
                let thumbnail = try await artifactService.thumbnail(
                    deviceID: authenticatedDeviceID,
                    artifactID: request.artifactId,
                    maxDimension: request.dimension
                )
                result = try Self.jsonValue(TerminalArtifactThumbnailResult(
                    artifactId: request.artifactId,
                    revision: thumbnail.revision,
                    dimension: request.dimension,
                    width: thumbnail.pixelWidth,
                    height: thumbnail.pixelHeight,
                    mimeType: "image/jpeg",
                    dataBase64: thumbnail.data.base64EncodedString()
                ))
            }
            return Self.encode(RPCResponse(id: req.id, ok: true, result: result))
        } catch let error as RemoteProtocolError {
            return Self.encode(Self.protocolErrorResponse(id: req.id, error: error))
        } catch let error as ChunkedFileUploadService.ServiceError {
            return Self.encode(Self.uploadErrorResponse(id: req.id, error: error))
        } catch let error as TerminalArtifactService.Error {
            return Self.encode(Self.artifactErrorResponse(id: req.id, error: error))
        } catch {
            return Self.encode(Self.errorResponse(
                id: req.id,
                code: RemoteErrorCode.invalidRequest.rawValue,
                message: "Malformed relay-owned RPC",
                data: .object(["reason": .string(String(describing: error))])
            ))
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from params: JSONValue
    ) throws -> Value {
        let data = try JSONEncoder().encode(params)
        return try SharedKitJSON.snakeCaseDecoder.decode(type, from: data)
    }

    private static func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func protocolErrorResponse(id: String, error: RemoteProtocolError) -> RPCResponse {
        switch error {
        case .missingField(let field):
            return errorResponse(id: id, code: "missing_field", message: "Missing required field", field: field)
        case .invalidField(let field):
            return errorResponse(id: id, code: "invalid_field", message: "Invalid field", field: field)
        case .negativeOffset:
            return errorResponse(id: id, code: "invalid_offset", message: "Offset must not be negative", field: "offset")
        case .chunkTooLarge(let maxBytes):
            return errorResponse(
                id: id,
                code: "chunk_too_large",
                message: "Chunk exceeds the maximum decoded size",
                data: .object(["field": .string("data_base64"), "max_bytes": .int(Int64(maxBytes))])
            )
        case .invalidBase64:
            return errorResponse(id: id, code: "invalid_base64", message: "Base64 must be canonical", field: "data_base64")
        case .invalidThumbnailDimension:
            return errorResponse(id: id, code: "invalid_field", message: "Thumbnail dimension is unsupported", field: "dimension")
        }
    }

    private static func uploadErrorResponse(
        id: String,
        error: ChunkedFileUploadService.ServiceError
    ) -> RPCResponse {
        let mapping: (String, String?)
        switch error.code {
        case "device_scope_mismatch", "invalid_device_id", "unauthenticated": mapping = ("forbidden", nil)
        case "offset_conflict": mapping = ("invalid_offset", "offset")
        case "file_too_large": mapping = ("size_limit_exceeded", "bytes")
        case "batch_file_limit", "too_many_uploads": mapping = ("size_limit_exceeded", "batch_file_count")
        case "batch_too_large": mapping = ("size_limit_exceeded", "batch_bytes")
        case "batch_conflict": mapping = ("upload_conflict", "batch_id")
        case "invalid_upload_id": mapping = ("invalid_field", "upload_id")
        case "invalid_batch_id": mapping = ("invalid_field", "batch_id")
        case "invalid_batch_file_count": mapping = ("invalid_field", "batch_file_count")
        case "invalid_batch_bytes": mapping = ("invalid_field", "batch_bytes")
        case "invalid_filename": mapping = ("invalid_field", "filename")
        case "invalid_mime_type": mapping = ("invalid_field", "mime_type")
        case "invalid_size", "size_mismatch": mapping = ("invalid_field", "bytes")
        default: mapping = (error.code, nil)
        }
        return errorResponse(id: id, code: mapping.0, message: error.message, field: mapping.1)
    }

    private static func artifactErrorResponse(
        id: String,
        error: TerminalArtifactService.Error
    ) -> RPCResponse {
        switch error {
        case .forbidden:
            return errorResponse(id: id, code: "forbidden", message: "Artifact is not authorized", field: "artifact_id")
        case .expired:
            return errorResponse(id: id, code: "expired", message: "Artifact authorization expired", field: "artifact_id")
        case .fileChanged:
            return errorResponse(id: id, code: "file_changed", message: "Artifact changed after authorization", field: "artifact_id")
        case .fileNotFound:
            return errorResponse(id: id, code: "not_found", message: "Artifact was not found", field: "artifact_id")
        case .invalidParams:
            return errorResponse(id: id, code: "invalid_field", message: "Artifact request parameters are invalid")
        case .unsupportedMedia:
            return errorResponse(id: id, code: "unsupported_media", message: "Artifact media is unsupported", field: "artifact_id")
        case .native(let code):
            let mapped: String
            switch code {
            case "unauthorized", "forbidden": mapped = "forbidden"
            case "file_not_found", "not_found": mapped = "not_found"
            default: mapped = code
            }
            return errorResponse(id: id, code: mapped, message: "cmux artifact operation failed")
        }
    }

    private static func dispatchNative(
        cmux: CMUXFacade,
        method: String,
        params: JSONValue
    ) async -> TerminalArtifactService.NativeResult {
        do {
            return .success(try await cmux.dispatch(method: method, params: params))
        } catch let error as RPCError {
            return .failure(code: error.code)
        } catch {
            return .failure(code: "internal_error")
        }
    }

    private static func relayOwnedAction(for req: RPCRequest) -> Action? {
        guard case .object(let params) = req.params else { return nil }
        switch req.method {
        case "surface.subscribe":
            guard case .string(let workspaceId)? = params["workspace_id"],
                  case .string(let surfaceId)? = params["surface_id"]
            else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.subscribe requires workspace_id and surface_id")))
            }
            let lines: Int
            if case .int(let value)? = params["lines"] { lines = max(1, Int(value)) }
            else { lines = 200 }
            return .subscribe(responseId: req.id, workspaceId: workspaceId, surfaceId: surfaceId, lines: lines)
        case "surface.unsubscribe":
            guard case .string(let surfaceId)? = params["surface_id"] else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.unsubscribe requires surface_id")))
            }
            return .unsubscribe(responseId: req.id, surfaceId: surfaceId)
        case "surface.read_text":
            guard case .string(let surfaceId)? = params["surface_id"] else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.read_text requires surface_id")))
            }
            return .requestFull(responseId: req.id, surfaceId: surfaceId)
        default:
            return nil
        }
    }

    private static func isSuccessfulInput(_ request: RPCRequest) -> Bool {
        request.method == "surface.send_text" || request.method == "surface.send_key"
    }

    private static func okResponse(id: String) -> RPCResponse {
        RPCResponse(id: id, ok: true, result: .object([:]), error: nil)
    }

    private static func errorResponse(
        id: String,
        code: String,
        message: String,
        field: String? = nil
    ) -> RPCResponse {
        errorResponse(
            id: id,
            code: code,
            message: message,
            data: field.map { .object(["field": .string($0)]) }
        )
    }

    private static func errorResponse(
        id: String,
        code: String,
        message: String,
        data: JSONValue?
    ) -> RPCResponse {
        RPCResponse(
            id: id,
            ok: false,
            result: nil,
            error: RPCError(code: code, message: message, data: data)
        )
    }

    public static func encodeForHandler(_ resp: RPCResponse) -> String {
        encode(resp)
    }

    private static func encode(_ resp: RPCResponse) -> String {
        guard let data = try? SharedKitJSON.deterministicEncoder.encode(resp),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - NIO channel handler


/// Thin NIO handler whose connection-owned mutable state is confined to the
/// channel event loop. Async actions capture the protocol machine and a weak
/// lifecycle reference, never the handler or `ChannelHandlerContext`.
public final class WebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    /// Default per-connection bound for WebSocket frames waiting behind a write.
    public static let defaultMaximumQueuedOutputBytes = 2 * 1024 * 1024

    /// Default hard cap on admitted but unfinished inbound actions per connection.
    public static let defaultMaximumOutstandingInboundActions = 64

    /// Default retained payload cap, sized for two maximum WebSocket frames.
    public static let defaultMaximumOutstandingInboundBytes = 2 * HTTPServer.maxWebSocketFrameBytes

    public let deviceId: String
    private let deviceStore: DeviceStore
    private let sessionManager: any WebSocketSessionManaging
    private let machine: WSProtocolMachine
    private let logger = Logger(label: "cmux-relay.ws")
    private let maximumQueuedOutputBytes: Int
    private let maximumOutstandingInboundActions: Int
    private let maximumOutstandingInboundBytes: Int

    private var actionQueue: WSActionQueue?
    private var sessionLifecycle: WebSocketSessionLifecycle?

    public convenience init(
        deviceId: String,
        deviceStore: DeviceStore,
        sessionManager: SessionManager,
        cmuxClient: CMUXFacade,
        maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes,
        maximumOutstandingInboundActions: Int = WebSocketHandler.defaultMaximumOutstandingInboundActions,
        maximumOutstandingInboundBytes: Int = WebSocketHandler.defaultMaximumOutstandingInboundBytes
    ) {
        self.init(
            deviceId: deviceId,
            deviceStore: deviceStore,
            sessionManager: sessionManager,
            machine: WSProtocolMachine(cmux: cmuxClient),
            maximumQueuedOutputBytes: maximumQueuedOutputBytes,
            maximumOutstandingInboundActions: maximumOutstandingInboundActions,
            maximumOutstandingInboundBytes: maximumOutstandingInboundBytes
        )
    }

    convenience init(
        deviceId: String,
        deviceStore: DeviceStore,
        sessionManager: SessionManager,
        cmuxClient: CMUXFacade,
        uploadService: ChunkedFileUploadService,
        artifactService: TerminalArtifactService,
        maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes,
        maximumOutstandingInboundActions: Int = WebSocketHandler.defaultMaximumOutstandingInboundActions,
        maximumOutstandingInboundBytes: Int = WebSocketHandler.defaultMaximumOutstandingInboundBytes
    ) {
        self.init(
            deviceId: deviceId,
            deviceStore: deviceStore,
            sessionManager: sessionManager,
            machine: WSProtocolMachine(
                cmux: cmuxClient,
                authenticatedDeviceID: deviceId,
                uploadService: uploadService,
                artifactService: artifactService
            ),
            maximumQueuedOutputBytes: maximumQueuedOutputBytes,
            maximumOutstandingInboundActions: maximumOutstandingInboundActions,
            maximumOutstandingInboundBytes: maximumOutstandingInboundBytes
        )
    }

    convenience init(
        deviceId: String,
        deviceStore: DeviceStore,
        sessionLifecycleManager: any WebSocketSessionManaging,
        cmuxClient: CMUXFacade,
        maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes,
        maximumOutstandingInboundActions: Int = WebSocketHandler.defaultMaximumOutstandingInboundActions,
        maximumOutstandingInboundBytes: Int = WebSocketHandler.defaultMaximumOutstandingInboundBytes
    ) {
        self.init(
            deviceId: deviceId,
            deviceStore: deviceStore,
            sessionManager: sessionLifecycleManager,
            machine: WSProtocolMachine(cmux: cmuxClient),
            maximumQueuedOutputBytes: maximumQueuedOutputBytes,
            maximumOutstandingInboundActions: maximumOutstandingInboundActions,
            maximumOutstandingInboundBytes: maximumOutstandingInboundBytes
        )
    }

    private init(
        deviceId: String,
        deviceStore: DeviceStore,
        sessionManager: any WebSocketSessionManaging,
        machine: WSProtocolMachine,
        maximumQueuedOutputBytes: Int,
        maximumOutstandingInboundActions: Int,
        maximumOutstandingInboundBytes: Int
    ) {
        self.deviceId = deviceId
        self.deviceStore = deviceStore
        self.sessionManager = sessionManager
        self.machine = machine
        self.maximumQueuedOutputBytes = max(1, maximumQueuedOutputBytes)
        self.maximumOutstandingInboundActions = max(1, maximumOutstandingInboundActions)
        self.maximumOutstandingInboundBytes = max(1, maximumOutstandingInboundBytes)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        installLifecycleIfNeeded(context: context)
        if context.channel.isActive {
            activateIfNeeded()
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        installLifecycleIfNeeded(context: context)
        activateIfNeeded()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        precondition(context.eventLoop.inEventLoop)
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        let buffer = frame.unmaskedData
        guard let text = buffer.getString(
            at: buffer.readerIndex,
            length: buffer.readableBytes
        ), let actionQueue,
           let sessionLifecycle,
           let generation = sessionLifecycle.activeGeneration
        else { return }

        let machine = self.machine
        guard actionQueue.enqueue(retainedByteCount: text.utf8.count, { [weak sessionLifecycle] in
            let actions = await machine.processText(text)
            guard !Task.isCancelled else { return }
            await sessionLifecycle?.apply(actions: actions, generation: generation)
        }) else {
            logger.warning("Closing WebSocket after inbound action queue overflow")
            invalidate(context: context, closeChannel: true)
            return
        }

        if actionQueue.shouldApplyBackpressure {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure {
                self.logger.warning("Failed to pause WebSocket inbound reads: \($0)")
            }
        }
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        precondition(context.eventLoop.inEventLoop)
        sessionLifecycle?.writabilityChanged()
        context.fireChannelWritabilityChanged()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        invalidate(context: context, closeChannel: false)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        invalidate(context: context, closeChannel: true)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("WebSocket channel failed: \(String(describing: error))")
        invalidate(context: context, closeChannel: true)
    }

    private func installLifecycleIfNeeded(context: ChannelHandlerContext) {
        precondition(context.eventLoop.inEventLoop)
        guard actionQueue == nil, sessionLifecycle == nil else { return }
        let channel = WSChannelContext(
            context,
            maximumQueuedOutputBytes: maximumQueuedOutputBytes
        )
        let logger = self.logger
        actionQueue = WSActionQueue(
            eventLoop: context.eventLoop,
            maximumOutstandingActions: maximumOutstandingInboundActions,
            maximumOutstandingRetainedBytes: maximumOutstandingInboundBytes
        ) { [weak channel] in
            channel?.setAutoRead(true) { error in
                logger.warning("Failed to resume WebSocket inbound reads: \(error)")
            }
        }
        sessionLifecycle = WebSocketSessionLifecycle(
            eventLoop: context.eventLoop,
            channel: channel,
            manager: sessionManager,
            deviceId: deviceId
        )
    }

    private func activateIfNeeded() {
        guard let actionQueue, let sessionLifecycle else { return }
        _ = sessionLifecycle.activate(machine: machine, queue: actionQueue)
    }

    private func invalidate(context: ChannelHandlerContext, closeChannel: Bool) {
        precondition(context.eventLoop.inEventLoop)
        let lifecycle = sessionLifecycle
        let queue = actionQueue
        sessionLifecycle = nil
        actionQueue = nil
        queue?.invalidate()
        lifecycle?.invalidate(closeChannel: closeChannel)
    }
}
