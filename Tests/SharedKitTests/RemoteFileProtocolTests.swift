import Foundation
import Testing
@testable import SharedKit

@Suite("Remote file protocol")
struct RemoteFileProtocolTests {
    @Test func capabilityRequestAndResultUseSeparateWireCapabilities() throws {
        let request = HostCapabilitiesRequest()
        let result = HostCapabilitiesResult(
            capabilities: [
                HostCapabilitiesResult.chunkUploadV2Capability,
                HostCapabilitiesResult.terminalArtifactsV1Capability,
            ]
        )

        let requestJSON = try JSONDecoder().decode(
            HostCapabilitiesRequest.self,
            from: JSONEncoder().encode(request)
        )
        let resultJSON = try JSONDecoder().decode(
            HostCapabilitiesResult.self,
            from: JSONEncoder().encode(result)
        )

        #expect(requestJSON == request)
        #expect(resultJSON == result)
        #expect(result.supportsChunkUploadV2)
        #expect(result.supportsTerminalArtifactsV1)
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] != nil)

        let requestEnvelope = try RPCRequest(id: "cap-1", method: RemoteRPCMethod.hostCapabilities.rawValue, payload: request)
        let responseEnvelope = RPCResponse(id: "cap-1", ok: true, result: .object(["capabilities": .array(result.capabilities.map(JSONValue.string))]))
        #expect(requestEnvelope.method == "host.capabilities")
        #expect(requestEnvelope.params == .object([:]))
        #expect(responseEnvelope.result == .object(["capabilities": .array([.string("file.upload.v2"), .string("terminal.artifact.v1")])]))
        #expect(try responseEnvelope.decodeResult(HostCapabilitiesResult.self) == result)
    }

    @Test func uploadMethodsRoundTripExactSnakeCaseKeys() throws {
        let begin = ChunkUploadBeginRequest(
            batchId: "11111111-2222-3333-4444-555555555555",
            filename: "archive.zip",
            mimeType: "application/zip",
            bytes: 100 * 1024 * 1024,
            sha256: String(repeating: "a", count: 64),
            batchFileCount: 10,
            batchBytes: 250 * 1024 * 1024
        )
        let chunk = ChunkUploadChunkRequest(uploadId: "u-1", offset: 512 * 1024, dataBase64: Data(repeating: 7, count: 4).base64EncodedString())
        let commit = ChunkUploadCommitRequest(uploadId: "u-1")
        let cancel = ChunkUploadCancelRequest(uploadId: "u-1")

        let beginJSON = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(begin)) as? [String: Any]
        let chunkJSON = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(chunk)) as? [String: Any]
        let beginKeys = beginJSON.map { Array($0.keys) } ?? []
        let chunkKeys = chunkJSON.map { Array($0.keys) } ?? []
        #expect(Set(beginKeys) == ["batch_id", "filename", "mime_type", "bytes", "sha256", "batch_file_count", "batch_bytes"])
        #expect(Set(chunkKeys) == ["upload_id", "offset", "data_base64"])
        #expect(try JSONDecoder().decode(ChunkUploadBeginRequest.self, from: JSONEncoder().encode(begin)) == begin)
        #expect(try JSONDecoder().decode(ChunkUploadChunkRequest.self, from: JSONEncoder().encode(chunk)) == chunk)
        #expect(try JSONDecoder().decode(ChunkUploadCommitRequest.self, from: JSONEncoder().encode(commit)) == commit)
        #expect(try JSONDecoder().decode(ChunkUploadCancelRequest.self, from: JSONEncoder().encode(cancel)) == cancel)

        let envelope = try RPCRequest(id: "req-1", method: RemoteRPCMethod.uploadBegin.rawValue, payload: begin)
        #expect(envelope.method == "file.upload.begin")
        let expectedBeginParams: JSONValue = .object([
            "batch_id": .string("11111111-2222-3333-4444-555555555555"),
            "filename": .string("archive.zip"), "mime_type": .string("application/zip"),
            "bytes": .int(100 * 1024 * 1024), "sha256": .string(String(repeating: "a", count: 64)),
            "batch_file_count": .int(10), "batch_bytes": .int(250 * 1024 * 1024),
        ])
        #expect(envelope.params == expectedBeginParams)

        let beginResult = ChunkUploadBeginResult(
            uploadId: "u-1",
            batchId: "11111111-2222-3333-4444-555555555555"
        )
        let chunkResult = ChunkUploadChunkResult(uploadId: "u-1", nextOffset: 4, receivedBytes: 4)
        let commitResult = ChunkUploadCommitResult(
            uploadId: "u-1", filename: "archive.zip", path: "/Users/test/Downloads/archive.zip",
            bytes: 100 * 1024 * 1024, mimeType: "application/zip", sha256: String(repeating: "a", count: 64)
        )
        let cancelResult = ChunkUploadCancelResult(uploadId: "u-1")
        try assertResponseRoundTrip(beginResult, id: "begin", resultKeys: ["upload_id", "batch_id", "chunk_bytes"])
        try assertResponseRoundTrip(chunkResult, id: "chunk", resultKeys: ["upload_id", "next_offset", "received_bytes"])
        try assertResponseRoundTrip(commitResult, id: "commit", resultKeys: ["upload_id", "filename", "path", "bytes", "mime_type", "sha256"])
        try assertResponseRoundTrip(cancelResult, id: "cancel", resultKeys: ["upload_id", "cancelled"])

        let requests = [
            try RPCRequest(id: "begin", method: RemoteRPCMethod.uploadBegin.rawValue, payload: begin),
            try RPCRequest(id: "chunk", method: RemoteRPCMethod.uploadChunk.rawValue, payload: chunk),
            try RPCRequest(id: "commit", method: RemoteRPCMethod.uploadCommit.rawValue, payload: commit),
            try RPCRequest(id: "cancel", method: RemoteRPCMethod.uploadCancel.rawValue, payload: cancel),
        ]
        #expect(requests.map(\.method) == ["file.upload.begin", "file.upload.chunk", "file.upload.commit", "file.upload.cancel"])
        #expect(requests.map(\.params).map(\.objectKeys) == [
            ["batch_id", "filename", "mime_type", "bytes", "sha256", "batch_file_count", "batch_bytes"],
            ["upload_id", "offset", "data_base64"], ["upload_id"], ["upload_id"],
        ])

        #expect(RemoteRPCMethod.uploadBegin.rawValue == "file.upload.begin")
        #expect(RemoteRPCMethod.uploadChunk.rawValue == "file.upload.chunk")
        #expect(RemoteRPCMethod.uploadCommit.rawValue == "file.upload.commit")
        #expect(RemoteRPCMethod.uploadCancel.rawValue == "file.upload.cancel")
    }

    @Test func artifactMethodsRoundTripExactSnakeCaseKeys() throws {
        let scan = TerminalArtifactScanRequest(workspaceId: "w-1", surfaceId: "s-1")
        let stat = TerminalArtifactStatRequest(artifactId: "a-1")
        let fetch = TerminalArtifactFetchRequest(artifactId: "a-1", offset: 3 * 1024 * 1024)
        let thumbnail = TerminalArtifactThumbnailRequest(artifactId: "a-1", dimension: 512)
        let item = TerminalArtifact(
            artifactId: "a-1", filename: "photo.png", mimeType: "image/png", bytes: 128,
            revision: "r-1", isImage: true
        )
        let scanResult = TerminalArtifactScanResult(generation: 2, artifacts: [item])
        let statResult = TerminalArtifactStatResult(artifactId: "a-1", filename: "photo.png", mimeType: "image/png", bytes: 128, revision: "r-1", width: 64, height: 32)
        let fetchResult = TerminalArtifactFetchResult(artifactId: "a-1", offset: 0, totalBytes: 8, revision: "r-1", dataBase64: "aGVsbG8=", eof: true)
        let thumbnailResult = TerminalArtifactThumbnailResult(artifactId: "a-1", revision: "r-1", dimension: 512, width: 512, height: 256, mimeType: "image/jpeg", dataBase64: "/9j/")
        try assertResponseRoundTrip(scanResult, id: "scan", resultKeys: ["generation", "artifacts"])
        try assertResponseRoundTrip(statResult, id: "stat", resultKeys: ["artifact_id", "filename", "mime_type", "bytes", "revision", "width", "height"])
        try assertResponseRoundTrip(fetchResult, id: "fetch", resultKeys: ["artifact_id", "offset", "total_bytes", "revision", "data_base64", "eof"])
        try assertResponseRoundTrip(thumbnailResult, id: "thumbnail", resultKeys: ["artifact_id", "revision", "dimension", "width", "height", "mime_type", "data_base64"])

        let scanKeys = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(scan)) as? [String: Any]
        let statKeys = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(stat)) as? [String: Any]
        let fetchKeys = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(fetch)) as? [String: Any]
        let thumbnailKeys = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(thumbnail)) as? [String: Any]
        #expect(Set(scanKeys.map { Array($0.keys) } ?? []) == ["workspace_id", "surface_id"])
        #expect(Set(statKeys.map { Array($0.keys) } ?? []) == ["artifact_id"])
        #expect(Set(fetchKeys.map { Array($0.keys) } ?? []) == ["artifact_id", "offset"])
        #expect(Set(thumbnailKeys.map { Array($0.keys) } ?? []) == ["artifact_id", "dimension"])

        for value in [
            try JSONEncoder().encode(scan),
            try JSONEncoder().encode(stat),
            try JSONEncoder().encode(fetch),
            try JSONEncoder().encode(thumbnail),
            try JSONEncoder().encode(item),
            try JSONEncoder().encode(scanResult),
            try JSONEncoder().encode(statResult),
        ] {
            #expect((try JSONSerialization.jsonObject(with: value)) is [String: Any])
        }
        #expect(try JSONDecoder().decode(TerminalArtifactScanRequest.self, from: JSONEncoder().encode(scan)) == scan)
        #expect(try JSONDecoder().decode(TerminalArtifactStatRequest.self, from: JSONEncoder().encode(stat)) == stat)
        #expect(try JSONDecoder().decode(TerminalArtifactFetchRequest.self, from: JSONEncoder().encode(fetch)) == fetch)
        #expect(try JSONDecoder().decode(TerminalArtifactThumbnailRequest.self, from: JSONEncoder().encode(thumbnail)) == thumbnail)
        #expect(try JSONDecoder().decode(TerminalArtifact.self, from: JSONEncoder().encode(item)) == item)
        #expect(try JSONDecoder().decode(TerminalArtifactScanResult.self, from: JSONEncoder().encode(scanResult)) == scanResult)
        #expect(try JSONDecoder().decode(TerminalArtifactStatResult.self, from: JSONEncoder().encode(statResult)) == statResult)
        #expect(RemoteRPCMethod.artifactScan.rawValue == "terminal.artifact.scan")
        #expect(RemoteRPCMethod.artifactStat.rawValue == "terminal.artifact.stat")
        #expect(RemoteRPCMethod.artifactFetch.rawValue == "terminal.artifact.fetch")
        let artifactRequests = [
            try RPCRequest(id: "scan", method: RemoteRPCMethod.artifactScan.rawValue, payload: scan),
            try RPCRequest(id: "stat", method: RemoteRPCMethod.artifactStat.rawValue, payload: stat),
            try RPCRequest(id: "fetch", method: RemoteRPCMethod.artifactFetch.rawValue, payload: fetch),
            try RPCRequest(id: "thumbnail", method: RemoteRPCMethod.artifactThumbnail.rawValue, payload: thumbnail),
        ]
        #expect(artifactRequests.map(\.method) == ["terminal.artifact.scan", "terminal.artifact.stat", "terminal.artifact.fetch", "terminal.artifact.thumbnail"])
        #expect(artifactRequests.map(\.params).map(\.objectKeys) == [
            ["workspace_id", "surface_id"], ["artifact_id"], ["artifact_id", "offset"], ["artifact_id", "dimension"],
        ])
        #expect(RemoteRPCMethod.artifactThumbnail.rawValue == "terminal.artifact.thumbnail")
    }

    @Test func surfaceDocumentContractRoundTripsWithoutPathFields() throws {
        let request = SurfaceDocumentOpenRequest(
            workspaceId: "56D5FC9A-0897-418B-8811-82FB5388B38F",
            surfaceId: "FB3FCE15-51F7-4606-860D-22AFAFEC6C3B"
        )
        let envelope = try RPCRequest(id: "doc", method: RemoteRPCMethod.surfaceDocumentOpen.rawValue, payload: request)

        #expect(RemoteRPCMethod.surfaceDocumentOpen.rawValue == "surface.document.open")
        #expect(RemoteRPCMethod(rawValue: "surface.document.open") == .surfaceDocumentOpen)
        #expect(envelope.params == .object([
            "workspace_id": .string("56D5FC9A-0897-418B-8811-82FB5388B38F"),
            "surface_id": .string("FB3FCE15-51F7-4606-860D-22AFAFEC6C3B"),
        ]))
        let snakeData = try SharedKitJSON.snakeCaseEncoder.encode(request)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(SurfaceDocumentOpenRequest.self, from: snakeData) == request)
        #expect(try JSONDecoder().decode(SurfaceDocumentOpenRequest.self, from: JSONEncoder().encode(request)) == request)

        let withClientPath = Data(#"{"workspace_id":"w","surface_id":"s","path":"/etc/hosts","file_path":"/etc/hosts","filename":"hosts"}"#.utf8)
        let decoded = try SharedKitJSON.snakeCaseDecoder.decode(SurfaceDocumentOpenRequest.self, from: withClientPath)
        #expect(decoded == SurfaceDocumentOpenRequest(workspaceId: "w", surfaceId: "s"))
        let reencoded = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(decoded)) as? [String: Any]
        #expect(Set(reencoded?.keys.map { $0 } ?? []) == ["workspace_id", "surface_id"])

        #expect(HostCapabilities.surfaceDocumentV1 == "surface.document.v1")
        #expect(HostCapabilitiesResult.surfaceDocumentV1Capability == "surface.document.v1")
        #expect(HostCapabilitiesResult(capabilities: ["surface.document.v1"]).supportsSurfaceDocumentV1)
        #expect(!HostCapabilitiesResult(capabilities: ["terminal.artifact.v1"]).supportsSurfaceDocumentV1)

        #expect(RemoteErrorCode.surfaceNotDocument.rawValue == "surface_not_document")
        #expect(RemoteErrorCode(rawValue: "surface_not_document") == .surfaceNotDocument)
        let encodedCode = try JSONEncoder().encode(RemoteErrorCode.surfaceNotDocument)
        #expect(String(decoding: encodedCode, as: UTF8.self) == #""surface_not_document""#)
        #expect(try JSONDecoder().decode(RemoteErrorCode.self, from: encodedCode) == .surfaceNotDocument)
    }

    @Test func surfaceBrowserContractRoundTripsWithoutPathFields() throws {
        let request = SurfaceBrowserCaptureRequest(
            workspaceId: "2DA27856-DDA7-4D11-B985-D07CAC87864F",
            surfaceId: "67DA7B9E-B834-4DBF-980F-3971E14B2F60"
        )
        let envelope = try RPCRequest(id: "cap", method: RemoteRPCMethod.surfaceBrowserCapture.rawValue, payload: request)

        #expect(RemoteRPCMethod.surfaceBrowserCapture.rawValue == "surface.browser.capture")
        #expect(RemoteRPCMethod(rawValue: "surface.browser.capture") == .surfaceBrowserCapture)
        #expect(envelope.params == .object([
            "workspace_id": .string("2DA27856-DDA7-4D11-B985-D07CAC87864F"),
            "surface_id": .string("67DA7B9E-B834-4DBF-980F-3971E14B2F60"),
        ]))
        let snakeData = try SharedKitJSON.snakeCaseEncoder.encode(request)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureRequest.self, from: snakeData) == request)
        #expect(try JSONDecoder().decode(SurfaceBrowserCaptureRequest.self, from: JSONEncoder().encode(request)) == request)

        let withClientPath = Data(#"{"workspace_id":"w","surface_id":"s","path":"/tmp/x.png","url":"https://example.com/"}"#.utf8)
        let decoded = try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureRequest.self, from: withClientPath)
        #expect(decoded == SurfaceBrowserCaptureRequest(workspaceId: "w", surfaceId: "s"))
        let reencoded = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(decoded)) as? [String: Any]
        #expect(Set(reencoded?.keys.map { $0 } ?? []) == ["workspace_id", "surface_id"])

        #expect(HostCapabilities.surfaceBrowserV1 == "surface.browser.v1")
        #expect(HostCapabilitiesResult.surfaceBrowserV1Capability == "surface.browser.v1")
        #expect(HostCapabilitiesResult(capabilities: ["surface.browser.v1"]).supportsSurfaceBrowserV1)
        #expect(!HostCapabilitiesResult(capabilities: ["surface.document.v1"]).supportsSurfaceBrowserV1)

        #expect(RemoteErrorCode.surfaceNotBrowser.rawValue == "surface_not_browser")
        #expect(RemoteErrorCode(rawValue: "surface_not_browser") == .surfaceNotBrowser)
        let encodedCode = try JSONEncoder().encode(RemoteErrorCode.surfaceNotBrowser)
        #expect(String(decoding: encodedCode, as: UTF8.self) == #""surface_not_browser""#)
        #expect(try JSONDecoder().decode(RemoteErrorCode.self, from: encodedCode) == .surfaceNotBrowser)

        #expect(SurfaceBrowserCaptureLimits.maxDimension == 1600)
        #expect(SurfaceBrowserCaptureLimits.maxImageBytes == 737_280)
        #expect(SurfaceBrowserCaptureLimits.recommendedRefreshSeconds == 2)
    }

    @Test func surfaceBrowserResultRoundTripsAndOmitsMissingOptionals() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let full = SurfaceBrowserCaptureResult(
            imageBase64: jpeg.base64EncodedString(), mimeType: "image/jpeg", width: 1405, height: 1600,
            sourceWidth: 2318, sourceHeight: 2640, url: "https://example.com/", title: "Example Domain",
            capturedAt: 1_794_240_000_000
        )
        let fullData = try SharedKitJSON.snakeCaseEncoder.encode(full)
        let fullKeys = try JSONSerialization.jsonObject(with: fullData) as? [String: Any]
        #expect(Set(fullKeys?.keys.map { $0 } ?? []) == [
            "image_base64", "mime_type", "width", "height", "source_width", "source_height",
            "url", "title", "captured_at",
        ])
        #expect(fullKeys?["captured_at"] as? Int64 == 1_794_240_000_000)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureResult.self, from: fullData) == full)
        #expect(try JSONDecoder().decode(SurfaceBrowserCaptureResult.self, from: JSONEncoder().encode(full)) == full)
        #expect(try full.decodedImage() == jpeg)

        var bare = full
        bare.url = nil
        bare.title = nil
        let bareData = try SharedKitJSON.snakeCaseEncoder.encode(bare)
        let bareKeys = try JSONSerialization.jsonObject(with: bareData) as? [String: Any]
        #expect(Set(bareKeys?.keys.map { $0 } ?? []) == [
            "image_base64", "mime_type", "width", "height", "source_width", "source_height", "captured_at",
        ])
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureResult.self, from: bareData) == bare)

        let response = RPCResponse(id: "cap", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: fullData))
        #expect(try response.decodeResult(SurfaceBrowserCaptureResult.self) == full)
    }

    @Test(arguments: [
        (#"{"mime_type":"image/jpeg","width":10,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.missingField("image_base64")),
        (#"{"image_base64":"","mime_type":"image/jpeg","width":10,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.missingField("image_base64")),
        (#"{"image_base64":"AA==","width":10,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.missingField("mime_type")),
        (#"{"image_base64":"AA==","mime_type":"image/png","width":10,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("mime_type")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":0,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("width")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":1601,"height":10,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("width")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":1601,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("height")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":-1,"source_width":10,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("height")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":10,"source_width":0,"source_height":10,"captured_at":1}"#, RemoteProtocolError.invalidField("source_width")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":10,"source_width":10,"source_height":0,"captured_at":1}"#, RemoteProtocolError.invalidField("source_height")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":10,"source_width":10,"source_height":10}"#, RemoteProtocolError.invalidField("captured_at")),
        (#"{"image_base64":"AA==","mime_type":"image/jpeg","width":10,"height":10,"source_width":10,"source_height":10,"captured_at":"2026-11-09T00:00:00Z"}"#, RemoteProtocolError.invalidField("captured_at")),
    ])
    func surfaceBrowserResultRejectsInvalidPayloads(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) {
            try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureResult.self, from: Data(json.utf8))
        }
    }

    @Test func surfaceBrowserResultImageRejectsNonCanonicalAndOversizedBase64() {
        let base = SurfaceBrowserCaptureResult(
            imageBase64: "A A==", mimeType: "image/jpeg", width: 10, height: 10,
            sourceWidth: 10, sourceHeight: 10, url: nil, title: nil, capturedAt: 1
        )
        #expect(throws: RemoteProtocolError.invalidBase64) { try base.decodedImage() }

        var oversized = base
        oversized.imageBase64 = Data(count: SurfaceBrowserCaptureLimits.maxImageBytes + 1).base64EncodedString()
        #expect(throws: RemoteProtocolError.chunkTooLarge(maxBytes: 737_280)) { try oversized.decodedImage() }

        var atLimit = base
        atLimit.imageBase64 = Data(count: SurfaceBrowserCaptureLimits.maxImageBytes).base64EncodedString()
        #expect((try? atLimit.decodedImage().count) == 737_280)
    }

    @Test func lockedBoundaryConstantsAreExact() {
        #expect(ChunkUploadLimits.rawChunkBytes == 512 * 1024)
        #expect(ChunkUploadLimits.maxFileBytes == 100 * 1024 * 1024)
        #expect(ChunkUploadLimits.maxBatchFiles == 10)
        #expect(ChunkUploadLimits.maxBatchBytes == 250 * 1024 * 1024)
        #expect(ChunkUploadLimits.abandonedUploadTTLSeconds == 60 * 60)
        #expect(TerminalArtifactLimits.maxScanItems == 200)
        #expect(TerminalArtifactLimits.authorizationTTLSeconds == 10 * 60)
        #expect(TerminalArtifactLimits.generationsPerSurface == 4)
        #expect(TerminalArtifactLimits.retainedSurfaces == 64)
        #expect(TerminalArtifactLimits.fetchChunkBytes == 3 * 1024 * 1024)
        #expect(TerminalArtifactLimits.maxImageBytes == 32 * 1024 * 1024)
        #expect(TerminalArtifactLimits.maxImagePixels == 40_000_000)
        #expect(TerminalArtifactLimits.defaultThumbnailDimension == 512)
        #expect(TerminalArtifactLimits.maxThumbnailDimension == 1024)
        #expect(TerminalArtifactLimits.maxThumbnailBytes == 4 * 1024 * 1024)
    }

    @Test func malformedAndMissingFieldsProduceTypedErrors() throws {
        let decoder = SharedKitJSON.snakeCaseDecoder
        let missingBatchID = Data(#"{"filename":"x"}"#.utf8)
        #expect(throws: RemoteProtocolError.missingField("batch_id")) {
            try decoder.decode(ChunkUploadBeginRequest.self, from: missingBatchID)
        }

        let invalidBatchID = Data(#"{"batch_id":" bad","filename":"x","mime_type":"application/octet-stream","bytes":0,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","batch_file_count":1,"batch_bytes":0}"#.utf8)
        #expect(throws: RemoteProtocolError.invalidField("batch_id")) {
            try decoder.decode(ChunkUploadBeginRequest.self, from: invalidBatchID)
        }

        let missing = Data(#"{"batch_id":"11111111-2222-3333-4444-555555555555","filename":"x"}"#.utf8)
        #expect(throws: RemoteProtocolError.missingField("mime_type")) {
            try decoder.decode(ChunkUploadBeginRequest.self, from: missing)
        }

        let missingBytes = Data(#"{"batch_id":"11111111-2222-3333-4444-555555555555","filename":"x","mime_type":"application/octet-stream","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","batch_file_count":1,"batch_bytes":0}"#.utf8)
        #expect(throws: RemoteProtocolError.missingField("bytes")) {
            try decoder.decode(ChunkUploadBeginRequest.self, from: missingBytes)
        }

        let negative = Data(#"{"upload_id":"u","offset":-1,"data_base64":"AA=="}"#.utf8)
        #expect(throws: RemoteProtocolError.negativeOffset) {
            try decoder.decode(ChunkUploadChunkRequest.self, from: negative)
        }
        let missingArtifactField = Data(#"{"offset":0}"#.utf8)
        #expect(throws: RemoteProtocolError.missingField("artifact_id")) {
            try decoder.decode(TerminalArtifactFetchRequest.self, from: missingArtifactField)
        }
        let invalidDimension = Data(#"{"artifact_id":"a","dimension":32}"#.utf8)
        #expect(throws: RemoteProtocolError.invalidThumbnailDimension) {
            try decoder.decode(TerminalArtifactThumbnailRequest.self, from: invalidDimension)
        }

        let oversizedJSON = "{\"upload_id\":\"u\",\"offset\":0,\"data_base64\":\"\(Data(repeating: 0, count: ChunkUploadLimits.rawChunkBytes + 1).base64EncodedString())\"}"
        let oversized = Data(oversizedJSON.utf8)
        #expect(throws: RemoteProtocolError.chunkTooLarge(maxBytes: ChunkUploadLimits.rawChunkBytes)) {
            try decoder.decode(ChunkUploadChunkRequest.self, from: oversized)
        }
    }

    @Test func structuredUnknownErrorCodeIsRetained() throws {
        let response = try JSONDecoder().decode(
            RPCResponse.self,
            from: Data(#"{"id":"1","ok":false,"error":{"code":"future_code","message":"not understood","data":{"field":"offset"}}}"#.utf8)
        )
        let error = try #require(response.error)
        #expect(RemoteErrorCode(rawValue: error.code) == .unknown("future_code"))
        #expect(error.data == .object(["field": .string("offset")]))
        #expect(RemoteErrorCode(rawValue: "upload_conflict") == .uploadConflict)
        #expect(RemoteErrorCode(rawValue: "upload_not_found") == .uploadNotFound)
        #expect(RemoteErrorCode(rawValue: "invalid_base64") == .invalidBase64)
        #expect(RemoteErrorCode(rawValue: "invalid_hash") == .invalidHash)
        #expect(RemoteErrorCode(rawValue: "expired") == .expired)
        #expect(RemoteErrorCode(rawValue: "unsupported_media") == .unsupportedMedia)
        #expect(RemoteErrorCode(rawValue: "future_code") == .unknown("future_code"))
    }

    @Test func imageArtifactAndResponsesRoundTrip() throws {
        let fetch = TerminalArtifactFetchResult(
            artifactId: "a-1", offset: 0, totalBytes: 8, revision: "r-1",
            dataBase64: Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString(), eof: true
        )
        let thumbnail = TerminalArtifactThumbnailResult(
            artifactId: "a-1", revision: "r-1", dimension: 512, width: 512, height: 256,
            mimeType: "image/jpeg", dataBase64: Data([255, 216, 255]).base64EncodedString()
        )
        #expect(try JSONDecoder().decode(TerminalArtifactFetchResult.self, from: JSONEncoder().encode(fetch)) == fetch)
        #expect(try JSONDecoder().decode(TerminalArtifactThumbnailResult.self, from: JSONEncoder().encode(thumbnail)) == thumbnail)
    }

    @Test func responseDecodeResultUsesSnakeCaseWireKeys() throws {
        let beginResponse = RPCResponse(id: "begin", ok: true, result: .object([
            "upload_id": .string("u-1"),
            "batch_id": .string("11111111-2222-3333-4444-555555555555"),
            "chunk_bytes": .int(Int64(ChunkUploadLimits.rawChunkBytes)),
        ]))
        let begin = try beginResponse.decodeResult(ChunkUploadBeginResult.self)
        #expect(begin == ChunkUploadBeginResult(
            uploadId: "u-1",
            batchId: "11111111-2222-3333-4444-555555555555"
        ))

        let fetchResponse = RPCResponse(id: "fetch", ok: true, result: .object([
            "artifact_id": .string("a-1"), "offset": .int(0), "total_bytes": .int(1),
            "revision": .string("r-1"), "data_base64": .string("YQ=="), "eof": .bool(true),
        ]))
        let fetch = try fetchResponse.decodeResult(TerminalArtifactFetchResult.self)
        #expect(fetch == TerminalArtifactFetchResult(artifactId: "a-1", offset: 0, totalBytes: 1, revision: "r-1", dataBase64: "YQ==", eof: true))
    }

    @Test func artifactResponseIsNotAFlawedPushFrame() throws {
        let response = RPCResponse(
            id: "artifact-1", ok: true,
            result: .object(["artifact_id": .string("a-1"), "eof": .bool(true)]),
            error: nil
        )
        let data = try JSONEncoder().encode(response)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(PushFrame.self, from: data)
        }
    }
}

private extension RemoteFileProtocolTests {
    func assertResponseRoundTrip<Payload: Codable & Equatable>(
        _ payload: Payload,
        id: String,
        resultKeys: Set<String>
    ) throws {
        let payloadData = try SharedKitJSON.snakeCaseEncoder.encode(payload)
        let result = try JSONDecoder().decode(JSONValue.self, from: payloadData)
        let response = RPCResponse(id: id, ok: true, result: result)
        let envelopeData = try SharedKitJSON.snakeCaseEncoder.encode(response)
        let envelopeObject = try #require(JSONSerialization.jsonObject(with: envelopeData) as? [String: Any])
        #expect(Set(envelopeObject.keys) == ["id", "ok", "result"])
        #expect(result.objectKeys == resultKeys)
        #expect(try response.decodeResult(Payload.self) == payload)
    }
}

private extension JSONValue {
    var objectKeys: Set<String> {
        guard case .object(let object) = self else { return [] }
        return Set(object.keys)
    }
}
