import Foundation
import SharedKit

/// RPC dispatch backing Demo Mode. Mirrors the small slice of the wire
/// protocol the iOS app actually exercises (workspace.list, surface.list,
/// surface.subscribe / send_text / send_key) and routes the rest to a
/// benign `ok` response so demo navigation never trips error handling.
///
/// Holds an `onSubscribe` hook so the app layer can push a corresponding
/// `screen.full` frame into `SurfaceStore` the moment a surface chip is
/// tapped — without that, the terminal mirror would stay blank in demo
/// mode (real mode populates it via WS push).
public actor DemoRPCDispatch: RPCDispatch {
    public typealias SubscribeHandler = @Sendable (String) async -> Void
    public typealias FileFeatureQAStateHandler = @Sendable (String) async -> Void

    private var onSubscribe: SubscribeHandler?
    private var onFileFeatureQAState: FileFeatureQAStateHandler?
    private var workspaces: [DemoWorkspace]
    private let fileFeatureFixturesEnabled: Bool
    private let attachmentScenario: String?
    private let artifactScenario: String?
    private let fileFeatureCacheNamespace: String?
    private var staleFeatureResponseGateEnabled: Bool
    private var staleFeatureResponse: RPCResponse?
    private var staleFeatureContinuation: CheckedContinuation<RPCResponse, Never>?
    private var thumbnailContinuation: CheckedContinuation<RPCResponse, Never>?
    private var shouldGateThumbnail: Bool
    private var uploadSequence = 0
    private var intentionallyFailedAttachmentNames: Set<String> = []
    private var blockedAttachmentUploadID: String?
    private var blockedAttachmentChunk: CheckedContinuation<RPCResponse, Never>?
    private var uploads: [String: (
        batchID: String,
        filename: String,
        mimeType: String,
        bytes: Int,
        sha256: String,
        data: Data
    )] = [:]
    private var activeImageRevision: String

    public init(
        fileFeatureFixturesEnabled: Bool = false,
        staleFeatureResponseGateEnabled: Bool = false,
        attachmentScenario: String? = nil,
        artifactScenario: String? = nil,
        fileFeatureCacheNamespace: String? = nil
    ) {
        self.workspaces = DemoContent.workspaces
        #if DEBUG
        let cacheNamespace = fileFeatureCacheNamespace?.isEmpty == false
            ? fileFeatureCacheNamespace
            : nil
        self.fileFeatureFixturesEnabled = fileFeatureFixturesEnabled
        self.staleFeatureResponseGateEnabled = staleFeatureResponseGateEnabled
        self.attachmentScenario = attachmentScenario
        self.artifactScenario = artifactScenario
        self.fileFeatureCacheNamespace = cacheNamespace
        self.activeImageRevision = Self.fixtureRevision(
            DemoContent.fileFeatureImageArtifact.revision,
            namespace: cacheNamespace
        )
        self.shouldGateThumbnail = artifactScenario == "source-states"
        #else
        self.fileFeatureFixturesEnabled = false
        self.staleFeatureResponseGateEnabled = false
        self.attachmentScenario = nil
        self.artifactScenario = nil
        self.fileFeatureCacheNamespace = nil
        self.activeImageRevision = DemoContent.fileFeatureImageArtifact.revision
        self.shouldGateThumbnail = false
        #endif
    }

    public func setOnSubscribe(_ handler: @escaping SubscribeHandler) {
        self.onSubscribe = handler
    }

    public func setOnFileFeatureQAState(_ handler: @escaping FileFeatureQAStateHandler) {
        onFileFeatureQAState = handler
    }

    public func releaseStaleFileFeatureResponse() async {
        if let response = staleFeatureResponse,
           let continuation = staleFeatureContinuation
        {
            staleFeatureResponse = nil
            staleFeatureContinuation = nil
            continuation.resume(returning: response)
            await onFileFeatureQAState?(DemoContent.fileFeatureQAStateReleased)
            return
        }
        if let continuation = thumbnailContinuation {
            thumbnailContinuation = nil
            shouldGateThumbnail = false
            continuation.resume(returning: errorResponse(
                code: .fileChanged,
                message: "The deterministic source image changed"
            ))
            await onFileFeatureQAState?("thumbnail-file-changed")
        }
    }

    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        if fileFeatureFixturesEnabled, let remoteMethod = RemoteRPCMethod(rawValue: method) {
            do {
                return try await fileFeatureResponse(method: remoteMethod, params: params)
            } catch {
                return RPCResponse(
                    id: "demo",
                    ok: false,
                    error: RPCError(
                        code: RemoteErrorCode.invalidRequest.rawValue,
                        message: "Invalid deterministic file-feature fixture request"
                    )
                )
            }
        }
        switch method {
        case "workspace.list":
            return RPCResponse(id: "demo", result: .object([
                "workspaces": .array(workspaces.enumerated().map { index, ws in
                    var payload: [String: JSONValue] = [
                        "id": .string(ws.id),
                        "title": .string(ws.title),
                        "index": .int(Int64(index)),
                    ]
                    if ws.id == "WS-DEMO-1" {
                        payload["agent"] = .string("Claude Code")
                        payload["status"] = .string("Claude is waiting for your input")
                        payload["summary"] = .string("Claude needs your permission")
                        payload["active_surface_id"] = .string("SF-DEMO-1A")
                    }
                    return .object(payload)
                }),
            ]))

        case "surface.list":
            guard case .object(let p) = params,
                  case .string(let workspaceId)? = p["workspace_id"],
                  let workspace = workspaces.first(where: { $0.id == workspaceId })
            else {
                return RPCResponse(id: "demo", result: .object(["surfaces": .array([])]))
            }
            return RPCResponse(id: "demo", result: .object([
                "surfaces": .array(workspace.surfaces.enumerated().map { index, surface in
                    .object([
                        "id": .string(surface.id),
                        "title": .string(surface.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))

        case "surface.subscribe":
            if case .object(let p) = params,
               case .string(let surfaceId)? = p["surface_id"]
            {
                await onSubscribe?(surfaceId)
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.read_text":
            if case .object(let p) = params,
               case .string(let surfaceId)? = p["surface_id"],
               let surface = surface(for: surfaceId)
            {
                return RPCResponse(id: "demo", result: .object([
                    "text": .string(surface.screen.joined(separator: "\n")),
                ]))
            }
            return RPCResponse(id: "demo", result: .object(["text": .string("")]))

        case "workspace.create":
            let title: String
            if case .object(let p) = params, case .string(let value)? = p["title"] {
                title = value
            } else if case .object(let p) = params, case .string(let value)? = p["name"] {
                title = value
            } else {
                title = "Terminal \(workspaces.count + 1)"
            }
            let workspaceId = "WS-DEMO-NEW-\(UUID().uuidString.prefix(8))"
            let workspace = DemoWorkspace(
                id: workspaceId,
                title: title,
                surfaces: [DemoSurface(id: "SF-DEMO-NEW-\(UUID().uuidString.prefix(8))", title: "shell", screen: ["$", "", "new demo workspace"])]
            )
            workspaces.append(workspace)
            return RPCResponse(id: "demo", ok: true, result: .object([
                "workspace_id": .string(workspaceId),
                "workspace": .object([
                    "id": .string(workspace.id),
                    "title": .string(workspace.title),
                    "index": .int(Int64(workspaces.count - 1)),
                ]),
            ]))

        case "workspace.rename":
            if case .object(let p) = params,
               case .string(let title)? = p["title"]
            {
                let workspaceId: String?
                if case .string(let id)? = p["workspace_id"] {
                    workspaceId = id
                } else {
                    workspaceId = workspaces.first?.id
                }
                if let workspaceId, let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
                    let old = workspaces[index]
                    workspaces[index] = DemoWorkspace(id: old.id, title: title, surfaces: old.surfaces)
                }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "workspace.close":
            if case .object(let p) = params, case .string(let workspaceId)? = p["workspace_id"], workspaces.count > 1 {
                workspaces.removeAll { $0.id == workspaceId }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.create":
            guard case .object(let p) = params,
                  case .string(let workspaceId)? = p["workspace_id"],
                  let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId })
            else {
                return RPCResponse(id: "demo", result: .object([
                    "surface_id": .string("SF-DEMO-NEW-\(UUID().uuidString.prefix(8))"),
                ]))
            }
            let old = workspaces[workspaceIndex]
            let nextIndex = old.surfaces.count + 1
            let surfaceId = "SF-DEMO-NEW-\(UUID().uuidString.prefix(8))"
            let surface = DemoSurface(id: surfaceId, title: "shell \(nextIndex)", screen: ["$", "", "new demo surface"])
            workspaces[workspaceIndex] = DemoWorkspace(id: old.id, title: old.title, surfaces: old.surfaces + [surface])
            return RPCResponse(id: "demo", result: .object([
                "surface_id": .string(surfaceId),
            ]))

        case "surface.close":
            if case .object(let p) = params,
               case .string(let workspaceId)? = p["workspace_id"],
               case .string(let surfaceId)? = p["surface_id"],
               let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId })
            {
                let old = workspaces[workspaceIndex]
                if old.surfaces.count > 1 {
                    workspaces[workspaceIndex] = DemoWorkspace(
                        id: old.id,
                        title: old.title,
                        surfaces: old.surfaces.filter { $0.id != surfaceId }
                    )
                }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.unsubscribe",
             "surface.send_text",
             "surface.send_key",
             "surface.focus",
             "notification.create":
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "file.upload":
            return RPCResponse(id: "demo", ok: true, result: .object([
                "filename": .string("demo-image.jpg"),
                "path": .string("/Users/demo/Downloads/cmux-remote/demo-image.jpg"),
                "bytes": .int(42),
                "mime_type": .string("image/jpeg"),
            ]))

        case "host.battery":
            return RPCResponse(id: "demo", ok: true, result: .object([
                "available": .bool(true),
                "percent": .int(88),
                "state": .string("charged"),
                "is_charging": .bool(true),
                "power_source": .string("AC Power"),
            ]))

        default:
            return RPCResponse(id: "demo", ok: true, result: .object([:]))
        }
    }

    private func fileFeatureResponse(
        method: RemoteRPCMethod,
        params: JSONValue
    ) async throws -> RPCResponse {
        switch method {
        case .hostCapabilities:
            return try encodedResponse(HostCapabilitiesResult(capabilities: [
                HostCapabilities.chunkUploadV2,
                HostCapabilities.terminalArtifactsV1,
            ]))

        case .uploadBegin:
            let request = try params.decode(ChunkUploadBeginRequest.self)
            uploadSequence += 1
            let uploadID = String(format: "demo-upload-%04d", uploadSequence)
            uploads[uploadID] = (
                request.batchId,
                request.filename,
                request.mimeType,
                request.bytes,
                request.sha256,
                Data()
            )
            return try encodedResponse(ChunkUploadBeginResult(
                uploadId: uploadID,
                batchId: request.batchId,
                chunkBytes: ChunkUploadLimits.rawChunkBytes
            ))

        case .uploadChunk:
            let request = try params.decode(ChunkUploadChunkRequest.self)
            guard var upload = uploads[request.uploadId],
                  upload.data.count == request.offset
            else {
                return errorResponse(
                    code: .invalidOffset,
                    message: "The deterministic fixture received a stale upload offset"
                )
            }
            if attachmentScenario == "happy",
               upload.filename == "sheet.hwpx",
               !intentionallyFailedAttachmentNames.contains(upload.filename)
            {
                intentionallyFailedAttachmentNames.insert(upload.filename)
                return errorResponse(
                    code: .invalidRequest,
                    message: "The deterministic fixture failed this upload once"
                )
            }
            if attachmentScenario == "boundary-cancel",
               upload.filename == "cancel-target.bin",
               request.offset == 0
            {
                blockedAttachmentUploadID = request.uploadId
                return await withCheckedContinuation { continuation in
                    blockedAttachmentChunk = continuation
                }
            }
            upload.data.append(try request.decodedBytes())
            uploads[request.uploadId] = upload
            return try encodedResponse(ChunkUploadChunkResult(
                uploadId: request.uploadId,
                nextOffset: upload.data.count,
                receivedBytes: upload.data.count
            ))

        case .uploadCommit:
            let request = try params.decode(ChunkUploadCommitRequest.self)
            guard let upload = uploads.removeValue(forKey: request.uploadId),
                  upload.data.count == upload.bytes
            else {
                return errorResponse(code: .uploadNotFound, message: "The deterministic upload is unavailable")
            }
            return try encodedResponse(ChunkUploadCommitResult(
                uploadId: request.uploadId,
                filename: upload.filename,
                path: deterministicAttachmentPath(filename: upload.filename),
                bytes: upload.bytes,
                mimeType: upload.mimeType,
                sha256: upload.sha256
            ))

        case .uploadCancel:
            let request = try params.decode(ChunkUploadCancelRequest.self)
            uploads[request.uploadId] = nil
            if blockedAttachmentUploadID == request.uploadId,
               let continuation = blockedAttachmentChunk
            {
                blockedAttachmentUploadID = nil
                blockedAttachmentChunk = nil
                continuation.resume(returning: errorResponse(
                    code: .invalidRequest,
                    message: "The deterministic fixture cancelled the blocked upload"
                ))
            }
            return try encodedResponse(ChunkUploadCancelResult(
                uploadId: request.uploadId,
                cancelled: true
            ))

        case .artifactScan:
            let request = try params.decode(TerminalArtifactScanRequest.self)
            switch request.surfaceId {
            case DemoContent.fileFeatureUnavailableSurfaceID:
                return errorResponse(code: .methodNotFound, message: "Terminal artifacts are unavailable")
            case DemoContent.fileFeatureErrorSurfaceID:
                return errorResponse(code: .forbidden, message: "Terminal artifact authorization failed")
            case DemoContent.fileFeatureMalformedSurfaceID:
                return RPCResponse(id: "demo", result: .object([
                    "generation": .string("malformed"),
                    "artifacts": .object([:]),
                ]))
            default:
                let replacement = request.surfaceId == DemoContent.fileFeatureReplacementSurfaceID
                activeImageRevision = fixtureRevision(
                    replacement
                        ? DemoContent.fileFeatureReplacementRevision
                        : DemoContent.fileFeatureImageArtifact.revision
                )
                var image = DemoContent.fileFeatureImageArtifact
                image.revision = activeImageRevision
                var document = DemoContent.fileFeatureDocumentArtifact
                document.revision = fixtureRevision(document.revision)
                let response = try encodedResponse(TerminalArtifactScanResult(
                    generation: replacement
                        ? DemoContent.fileFeatureScanGeneration + 1
                        : DemoContent.fileFeatureScanGeneration,
                    artifacts: [image, document]
                ))
                if staleFeatureResponseGateEnabled,
                   request.surfaceId == DemoContent.fileFeatureHappySurfaceID
                {
                    staleFeatureResponseGateEnabled = false
                    staleFeatureResponse = response
                    await onFileFeatureQAState?(DemoContent.fileFeatureQAStateBlocked)
                    return await withCheckedContinuation { continuation in
                        staleFeatureContinuation = continuation
                    }
                }
                return response
            }

        case .artifactStat:
            let request = try params.decode(TerminalArtifactStatRequest.self)
            if request.artifactId == DemoContent.fileFeatureStaleArtifactID {
                return errorResponse(code: .fileChanged, message: "The deterministic artifact changed")
            }
            if request.artifactId == DemoContent.fileFeatureImageArtifact.artifactId {
                return try encodedResponse(TerminalArtifactStatResult(
                    artifactId: request.artifactId,
                    filename: DemoContent.fileFeatureImageArtifact.filename,
                    mimeType: DemoContent.fileFeatureImageArtifact.mimeType,
                    bytes: DemoContent.fileFeatureImageBytes.count,
                    revision: activeImageRevision,
                    width: DemoContent.fileFeatureImageWidth,
                    height: DemoContent.fileFeatureImageHeight
                ))
            }
            guard request.artifactId == DemoContent.fileFeatureDocumentArtifact.artifactId else {
                return errorResponse(code: .notFound, message: "The deterministic artifact is unavailable")
            }
            return try encodedResponse(TerminalArtifactStatResult(
                artifactId: request.artifactId,
                filename: DemoContent.fileFeatureDocumentArtifact.filename,
                mimeType: DemoContent.fileFeatureDocumentArtifact.mimeType,
                bytes: DemoContent.fileFeatureDocumentArtifact.bytes,
                revision: DemoContent.fileFeatureDocumentArtifact.revision
            ))

        case .artifactThumbnail:
            let request = try params.decode(TerminalArtifactThumbnailRequest.self)
            guard request.artifactId == DemoContent.fileFeatureImageArtifact.artifactId else {
                return errorResponse(code: .unsupportedMedia, message: "The deterministic artifact has no thumbnail")
            }
            if artifactScenario == "source-states", shouldGateThumbnail {
                await onFileFeatureQAState?("thumbnail-blocked")
                return await withCheckedContinuation { continuation in
                    thumbnailContinuation = continuation
                }
            }
            return try encodedResponse(TerminalArtifactThumbnailResult(
                artifactId: request.artifactId,
                revision: activeImageRevision,
                dimension: request.dimension,
                width: DemoContent.fileFeatureImageWidth,
                height: DemoContent.fileFeatureImageHeight,
                mimeType: "image/jpeg",
                dataBase64: DemoContent.fileFeatureThumbnailBytes.base64EncodedString()
            ))

        case .artifactFetch:
            let request = try params.decode(TerminalArtifactFetchRequest.self)
            guard request.artifactId == DemoContent.fileFeatureImageArtifact.artifactId,
                  request.offset <= DemoContent.fileFeatureImageBytes.count
            else {
                return errorResponse(code: .notFound, message: "The deterministic artifact is unavailable")
            }
            let chunk = DemoContent.fileFeatureImageBytes.dropFirst(request.offset)
            return try encodedResponse(TerminalArtifactFetchResult(
                artifactId: request.artifactId,
                offset: request.offset,
                totalBytes: DemoContent.fileFeatureImageBytes.count,
                revision: activeImageRevision,
                dataBase64: Data(chunk).base64EncodedString(),
                eof: true
            ))
        }
    }

    private func fixtureRevision(_ revision: String) -> String {
        Self.fixtureRevision(revision, namespace: fileFeatureCacheNamespace)
    }

    private static func fixtureRevision(_ revision: String, namespace: String?) -> String {
        guard let namespace else { return revision }
        return "\(revision)-\(namespace)"
    }

    private func deterministicAttachmentPath(filename: String) -> String {
        let happyNames = [
            "report.pdf",
            "contract.docx",
            "hangul.hwp",
            "sheet.hwpx",
            "archive.zip",
            "mystery.unknown",
        ]
        let ordinal = happyNames.firstIndex(of: filename) ?? max(0, uploadSequence - 1)
        return "/Users/demo/Drop/\(ordinal)-it's \(filename)"
    }

    private func encodedResponse<Value: Encodable>(_ value: Value) throws -> RPCResponse {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        return RPCResponse(id: "demo", ok: true, result: result)
    }

    private func errorResponse(code: RemoteErrorCode, message: String) -> RPCResponse {
        RPCResponse(
            id: "demo",
            ok: false,
            error: RPCError(code: code.rawValue, message: message)
        )
    }

    private func surface(for id: String) -> DemoSurface? {
        for workspace in workspaces {
            if let surface = workspace.surfaces.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }
}
