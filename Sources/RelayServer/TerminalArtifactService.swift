import CoreGraphics
import Crypto
import Darwin
import Foundation
import ImageIO
import SharedKit
import UniformTypeIdentifiers

/// Coordinates native cmux artifact RPCs with a secure relay-local fallback.
actor TerminalArtifactService {
    typealias Scope = ArtifactAuthorizationStore.Scope
    typealias Source = ArtifactAuthorizationStore.Source

    static let minimumFetchBytes = 1 * 1_024 * 1_024
    static let maximumFetchBytes = 3 * 1_024 * 1_024
    static let maximumImageBytes: Int64 = 32 * 1_024 * 1_024
    static let maximumImagePixels: Int64 = 40_000_000
    static let maximumThumbnailBytes = 4 * 1_024 * 1_024

    enum Error: Swift.Error, Sendable, Equatable {
        case forbidden
        case expired
        case fileChanged
        case fileNotFound
        case invalidParams
        case unsupportedMedia
        case native(String)
    }

    enum NativeResult: Sendable, Equatable {
        case success(JSONValue)
        case failure(code: String)
    }

    struct Artifact: Sendable, Equatable {
        let id: String
        let displayName: String
        let kind: String
        let size: Int64
        let mimeType: String?
        let revision: String
    }

    struct ScanResult: Sendable, Equatable {
        let generation: Int
        let source: Source
        let artifacts: [Artifact]
    }

    struct StatResult: Sendable, Equatable {
        let displayName: String
        let kind: String
        let size: Int64
        let mimeType: String?
        let revision: String
    }

    struct FetchChunk: Sendable, Equatable {
        let data: Data
        let offset: Int64
        let totalSize: Int64
        let revision: String
        let eof: Bool
    }

    struct Thumbnail: Sendable, Equatable {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let revision: String
    }

    /// Injectable synchronous filesystem operations, executed off the service actor.
    struct FileSystem: Sendable {
        struct Inspected: Sendable {
            let canonicalPath: String
            let displayName: String
            let kind: String
            let mimeType: String?
            let identity: ArtifactAuthorizationStore.FileIdentity
        }

        enum Failure: Swift.Error {
            case fileNotFound
            case fileChanged
            case unsupportedMedia
            case invalidOffset
        }

        enum LiveOperation: Sendable, Equatable {
            case inspect
            case read
            case thumbnail
            case confirmation
        }

        enum LiveCheckpoint: Sendable, Equatable {
            case beforeLeafAccess(operation: LiveOperation, path: String)
        }

        fileprivate let inspectOperation: @Sendable (String, String?) throws -> Inspected
        fileprivate let readOperation: @Sendable (
            String, ArtifactAuthorizationStore.FileIdentity, Int64, Int
        ) throws -> Data
        fileprivate let thumbnailOperation: @Sendable (
            String, ArtifactAuthorizationStore.FileIdentity, Int
        ) throws -> (Data, Int, Int)

        init() {
            self.init(liveCheckpoint: { _ in })
        }

        init(liveCheckpoint: @escaping @Sendable (LiveCheckpoint) -> Void) {
            self.inspectOperation = {
                try FileSystem.inspectLive(candidate: $0, cwd: $1, checkpoint: liveCheckpoint)
            }
            self.readOperation = {
                try FileSystem.readLive(
                    path: $0, expected: $1, offset: $2, length: $3, checkpoint: liveCheckpoint
                )
            }
            self.thumbnailOperation = {
                try FileSystem.thumbnailLive(
                    path: $0, expected: $1, maxDimension: $2, checkpoint: liveCheckpoint
                )
            }
        }

        init(
            inspect: @escaping @Sendable (String, String?) throws -> Inspected,
            read: @escaping @Sendable (
                String, ArtifactAuthorizationStore.FileIdentity, Int64, Int
            ) throws -> Data,
            thumbnail: @escaping @Sendable (
                String, ArtifactAuthorizationStore.FileIdentity, Int
            ) throws -> (Data, Int, Int)
        ) {
            self.inspectOperation = inspect
            self.readOperation = read
            self.thumbnailOperation = thumbnail
        }

        private struct OpenedRegularFile {
            let descriptor: Int32
            let status: Darwin.stat
            let identity: ArtifactAuthorizationStore.FileIdentity
        }

        private static func inspectLive(
            candidate: String,
            cwd: String?,
            checkpoint: @Sendable (LiveCheckpoint) -> Void
        ) throws -> Inspected {
            let path = try normalizedAbsolutePath(candidate: candidate, cwd: cwd)
            return try withVerifiedRegularFile(
                path: path, expected: nil, operation: .inspect, checkpoint: checkpoint
            ) { _, status, fileIdentity in
                let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
                let kind: String
                if type?.conforms(to: .image) == true { kind = "image" }
                else if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
                    kind = "text"
                } else { kind = "binary" }
                return Inspected(
                    canonicalPath: path,
                    displayName: URL(fileURLWithPath: path).lastPathComponent,
                    kind: kind,
                    mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                    identity: fileIdentity
                )
            }
        }

        private static func readLive(
            path: String,
            expected: ArtifactAuthorizationStore.FileIdentity,
            offset: Int64,
            length: Int,
            checkpoint: @Sendable (LiveCheckpoint) -> Void
        ) throws -> Data {
            guard offset >= 0, offset <= expected.size else { throw Failure.invalidOffset }
            let requested = min(length, Int(expected.size - offset))
            return try withVerifiedRegularFile(
                path: path, expected: expected, operation: .read, checkpoint: checkpoint
            ) { descriptor, _, _ in
                var data = Data(count: max(0, requested))
                var bytesRead = 0
                while bytesRead < requested {
                    let count = data.withUnsafeMutableBytes { buffer -> Int in
                        guard let base = buffer.baseAddress else { return 0 }
                        return preadRetryingEINTR(
                            descriptor: descriptor,
                            buffer: base.advanced(by: bytesRead),
                            count: requested - bytesRead,
                            offset: off_t(offset + Int64(bytesRead))
                        )
                    }
                    guard count > 0 else { throw Failure.fileChanged }
                    bytesRead += count
                }
                return data
            }
        }

        private static func thumbnailLive(
            path: String,
            expected: ArtifactAuthorizationStore.FileIdentity,
            maxDimension: Int,
            checkpoint: @Sendable (LiveCheckpoint) -> Void
        ) throws -> (Data, Int, Int) {
            guard expected.size >= 0,
                  expected.size <= TerminalArtifactService.maximumImageBytes,
                  expected.size <= Int64(Int.max) else { throw Failure.unsupportedMedia }
            return try withVerifiedRegularFile(
                path: path, expected: expected, operation: .thumbnail, checkpoint: checkpoint
            ) { descriptor, _, _ in
                let sourceByteCount = Int(expected.size)
                var sourceData = Data(count: sourceByteCount)
                var bytesRead = 0
                while bytesRead < sourceByteCount {
                    let count = sourceData.withUnsafeMutableBytes { buffer -> Int in
                        guard let base = buffer.baseAddress else { return 0 }
                        return preadRetryingEINTR(
                            descriptor: descriptor,
                            buffer: base.advanced(by: bytesRead),
                            count: sourceByteCount - bytesRead,
                            offset: off_t(bytesRead)
                        )
                    }
                    guard count > 0 else { throw Failure.fileChanged }
                    bytesRead += count
                }
                return try encodedThumbnail(sourceData: sourceData, maxDimension: maxDimension)
            }
        }

        private static func encodedThumbnail(
            sourceData: Data,
            maxDimension: Int
        ) throws -> (Data, Int, Int) {
            guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
                  width > 0, height > 0,
                  width <= TerminalArtifactService.maximumImagePixels / height,
                  width * height <= TerminalArtifactService.maximumImagePixels
            else { throw Failure.unsupportedMedia }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw Failure.unsupportedMedia
            }
            for quality in [0.82, 0.65, 0.45, 0.30] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil
                ) else { throw Failure.unsupportedMedia }
                CGImageDestinationAddImage(destination, image, [
                    kCGImageDestinationLossyCompressionQuality: quality,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw Failure.unsupportedMedia }
                let encoded = output as Data
                if encoded.count <= TerminalArtifactService.maximumThumbnailBytes {
                    return (encoded, image.width, image.height)
                }
            }
            throw Failure.unsupportedMedia
        }

        private static func withVerifiedRegularFile<Result>(
            path: String,
            expected: ArtifactAuthorizationStore.FileIdentity?,
            operation: LiveOperation,
            checkpoint: @Sendable (LiveCheckpoint) -> Void,
            body: (Int32, Darwin.stat, ArtifactAuthorizationStore.FileIdentity) throws -> Result
        ) throws -> Result {
            let opened = try openVerifiedRegularFile(
                path: path, expected: expected, operation: operation, checkpoint: checkpoint
            )
            defer { _ = Darwin.close(opened.descriptor) }
            let result = try body(opened.descriptor, opened.status, opened.identity)
            try verify(descriptor: opened.descriptor, expected: opened.identity)

            let confirmation = try openVerifiedRegularFile(
                path: path, expected: opened.identity, operation: .confirmation, checkpoint: checkpoint
            )
            _ = Darwin.close(confirmation.descriptor)
            return result
        }

        private static func openVerifiedRegularFile(
            path: String,
            expected: ArtifactAuthorizationStore.FileIdentity?,
            operation: LiveOperation,
            checkpoint: @Sendable (LiveCheckpoint) -> Void
        ) throws -> OpenedRegularFile {
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { throw expected == nil ? Failure.fileNotFound : Failure.fileChanged }

            var directoryDescriptor = openRetryingEINTR(
                directory: nil, component: "/", flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directoryDescriptor >= 0 else {
                throw expected == nil ? Failure.fileNotFound : Failure.fileChanged
            }
            defer { _ = Darwin.close(directoryDescriptor) }

            for component in components.dropLast() {
                let next = openRetryingEINTR(
                    directory: directoryDescriptor,
                    component: component,
                    flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else { throw expected == nil ? Failure.fileNotFound : Failure.fileChanged }
                do {
                    var directoryStatus = Darwin.stat()
                    guard fstatRetryingEINTR(next, &directoryStatus) == 0,
                          (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
                        throw expected == nil ? Failure.unsupportedMedia : Failure.fileChanged
                    }
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(directoryDescriptor)
                directoryDescriptor = next
            }

            checkpoint(.beforeLeafAccess(operation: operation, path: path))
            let leaf = components[components.count - 1]
            var entryStatus = Darwin.stat()
            let entryResult = leaf.withCString {
                fstatatRetryingEINTR(directoryDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard entryResult == 0 else { throw expected == nil ? Failure.fileNotFound : Failure.fileChanged }
            guard (entryStatus.st_mode & S_IFMT) == S_IFREG else {
                throw expected == nil ? Failure.unsupportedMedia : Failure.fileChanged
            }

            let descriptor = openRetryingEINTR(
                directory: directoryDescriptor,
                component: leaf,
                flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw expected == nil ? Failure.fileNotFound : Failure.fileChanged }
            do {
                var openedStatus = Darwin.stat()
                guard fstatRetryingEINTR(descriptor, &openedStatus) == 0,
                      (openedStatus.st_mode & S_IFMT) == S_IFREG else {
                    throw expected == nil ? Failure.unsupportedMedia : Failure.fileChanged
                }
                let entryIdentity = identity(from: entryStatus)
                let openedIdentity = identity(from: openedStatus)
                guard entryIdentity == openedIdentity,
                      expected == nil || openedIdentity == expected else { throw Failure.fileChanged }
                return OpenedRegularFile(
                    descriptor: descriptor, status: openedStatus, identity: openedIdentity
                )
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }

        private static func normalizedAbsolutePath(candidate: String, cwd: String?) throws -> String {
            guard !candidate.isEmpty,
                  candidate.utf8.count <= 4_096,
                  !candidate.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw Failure.fileNotFound
            }
            let rawPath: String
            if candidate.hasPrefix("/") {
                rawPath = candidate
            } else {
                guard let cwd, cwd.hasPrefix("/") else { throw Failure.fileNotFound }
                rawPath = cwd + (cwd.hasSuffix("/") ? "" : "/") + candidate
            }

            var components: [Substring] = []
            for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
                if component == "." { continue }
                if component == ".." {
                    if !components.isEmpty { components.removeLast() }
                } else {
                    components.append(component)
                }
            }
            guard !components.isEmpty else { throw Failure.fileNotFound }
            var path = "/" + components.joined(separator: "/")
            if path == "/var" || path.hasPrefix("/var/") ||
                path == "/tmp" || path.hasPrefix("/tmp/") ||
                path == "/etc" || path.hasPrefix("/etc/") {
                path = "/private" + path
            }
            guard path.utf8.count <= 4_096 else { throw Failure.fileNotFound }
            return path
        }

        private static func openRetryingEINTR(
            directory: Int32?,
            component: String,
            flags: Int32
        ) -> Int32 {
            var result: Int32
            repeat {
                result = component.withCString {
                    if let directory { return Darwin.openat(directory, $0, flags) }
                    return Darwin.open($0, flags)
                }
            } while result < 0 && errno == EINTR
            return result
        }

        private static func fstatRetryingEINTR(_ descriptor: Int32, _ status: inout Darwin.stat) -> Int32 {
            var result: Int32
            repeat { result = Darwin.fstat(descriptor, &status) } while result < 0 && errno == EINTR
            return result
        }

        private static func fstatatRetryingEINTR(
            _ directory: Int32,
            _ component: UnsafePointer<CChar>,
            _ status: inout Darwin.stat,
            _ flags: Int32
        ) -> Int32 {
            var result: Int32
            repeat {
                result = Darwin.fstatat(directory, component, &status, flags)
            } while result < 0 && errno == EINTR
            return result
        }

        private static func preadRetryingEINTR(
            descriptor: Int32,
            buffer: UnsafeMutableRawPointer,
            count: Int,
            offset: off_t
        ) -> Int {
            var result: Int
            repeat {
                result = Darwin.pread(descriptor, buffer, count, offset)
            } while result < 0 && errno == EINTR
            return result
        }

        private static func verify(
            descriptor: Int32,
            expected: ArtifactAuthorizationStore.FileIdentity
        ) throws {
            var status = Darwin.stat()
            guard fstatRetryingEINTR(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  identity(from: status) == expected else { throw Failure.fileChanged }
        }

        private static func identity(from status: Darwin.stat) -> ArtifactAuthorizationStore.FileIdentity {
            let device = UInt64(status.st_dev)
            let inode = UInt64(status.st_ino)
            let size = Int64(status.st_size)
            let modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            let modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            let material = "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)"
            let revision = SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return .init(
                device: device,
                inode: inode,
                size: size,
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: modifiedNanoseconds,
                revision: revision
            )
        }
    }

    private let dispatchNative: @Sendable (String, JSONValue) async -> NativeResult
    private let fileSystem: FileSystem
    private let detector = ArtifactPathDetector()
    private let authorizations: ArtifactAuthorizationStore

    init(
        dispatchNative: @escaping @Sendable (String, JSONValue) async -> NativeResult,
        fileSystem: FileSystem = FileSystem(),
        now: @escaping @Sendable () async -> TimeInterval = { Date().timeIntervalSince1970 },
        makeID: @escaping @Sendable () async -> String = { UUID().uuidString }
    ) {
        self.dispatchNative = dispatchNative
        self.fileSystem = fileSystem
        self.authorizations = ArtifactAuthorizationStore(now: now, makeID: makeID)
    }

    func scan(
        scope: Scope,
        advertisedCapabilities: Set<String>? = nil,
        trustedUploadedPaths: [String] = []
    ) async throws -> ScanResult {
        let uploadedCandidates = await trustedUploadCandidates(paths: trustedUploadedPaths)
        let nativeAdvertised = advertisedCapabilities.map {
            $0.contains("terminal.artifact.v1") || $0.contains("terminal.artifact.list.v1")
        }
        if nativeAdvertised != false {
            let response = await dispatchNative(
                "mobile.terminal.artifact.scan",
                .object([
                    "workspace_id": .string(scope.workspaceID),
                    "surface_id": .string(scope.surfaceID),
                    "visible_only": .bool(true),
                ])
            )
            switch response {
            case .success(let value):
                return try await recordNativeScan(
                    value,
                    scope: scope,
                    uploadedCandidates: uploadedCandidates
                )
            case .failure(let code) where code == "method_not_found":
                break
            case .failure(let code):
                throw Error.native(code)
            }
        }
        return try await fallbackScan(
            scope: scope,
            uploadedCandidates: uploadedCandidates
        )
    }

    func stat(deviceID: String, artifactID: String) async throws -> StatResult {
        let located = try await locate(deviceID: deviceID, artifactID: artifactID)
        return try await stat(
            scope: located.scope,
            generation: located.generationNumber,
            artifactID: artifactID
        )
    }

    func stat(scope: Scope, generation: Int, artifactID: String) async throws -> StatResult {
        let authorization = try await resolveAndRevalidate(
            scope: scope, generation: generation, artifactID: artifactID, revision: nil
        )
        if authorization.source == .native {
            let response = await dispatchNative(
                "mobile.terminal.artifact.stat",
                nativePathParams(scope: scope, path: authorization.canonicalPath)
            )
            switch response {
            case .success:
                break
            case .failure(let code) where permitsRelayFallback(code):
                break
            case .failure(let code):
                throw Error.native(code)
            }
            try await revalidate(authorization)
        }
        return StatResult(
            displayName: authorization.displayName,
            kind: authorization.kind,
            size: authorization.identity.size,
            mimeType: authorization.mimeType,
            revision: authorization.identity.revision
        )
    }

    func fetch(
        deviceID: String,
        artifactID: String,
        offset: Int64,
        length: Int = TerminalArtifactService.maximumFetchBytes
    ) async throws -> FetchChunk {
        let located = try await locate(deviceID: deviceID, artifactID: artifactID)
        return try await fetch(
            scope: located.scope,
            generation: located.generationNumber,
            artifactID: artifactID,
            revision: located.authorization.identity.revision,
            offset: offset,
            length: length
        )
    }

    func fetch(
        scope: Scope,
        generation: Int,
        artifactID: String,
        revision: String,
        offset: Int64,
        length: Int
    ) async throws -> FetchChunk {
        guard length >= Self.minimumFetchBytes, length <= Self.maximumFetchBytes, offset >= 0 else {
            throw Error.invalidParams
        }
        let authorization = try await resolveAndRevalidate(
            scope: scope, generation: generation, artifactID: artifactID, revision: revision
        )
        guard offset <= authorization.identity.size else { throw Error.invalidParams }

        if authorization.source == .native {
            var params = nativePathDictionary(scope: scope, path: authorization.canonicalPath)
            params["offset"] = .int(offset)
            params["length"] = .int(Int64(length))
            let response = await dispatchNative("mobile.terminal.artifact.fetch", .object(params))
            switch response {
            case .success:
                let chunk = try nativeFetchChunk(
                    response, expectedOffset: offset, maximumLength: length,
                    identity: authorization.identity
                )
                let trusted = try await fallbackFetch(
                    authorization: authorization, offset: offset, length: chunk.data.count
                )
                guard trusted.data == chunk.data else { throw Error.fileChanged }
                try await revalidate(authorization)
                return chunk
            case .failure(let code) where permitsRelayFallback(code):
                break
            case .failure(let code):
                throw Error.native(code)
            }
        }
        return try await fallbackFetch(
            authorization: authorization, offset: offset, length: length
        )
    }

    func thumbnail(
        deviceID: String,
        artifactID: String,
        maxDimension: Int = 512
    ) async throws -> Thumbnail {
        let located = try await locate(deviceID: deviceID, artifactID: artifactID)
        return try await thumbnail(
            scope: located.scope,
            generation: located.generationNumber,
            artifactID: artifactID,
            revision: located.authorization.identity.revision,
            maxDimension: maxDimension
        )
    }

    func thumbnail(
        scope: Scope,
        generation: Int,
        artifactID: String,
        revision: String,
        maxDimension: Int = 512
    ) async throws -> Thumbnail {
        let authorization = try await resolveAndRevalidate(
            scope: scope, generation: generation, artifactID: artifactID, revision: revision
        )
        let dimension = min(max(maxDimension, 64), 1_024)
        if authorization.source == .native {
            var params = nativePathDictionary(scope: scope, path: authorization.canonicalPath)
            params["max_dimension"] = .int(Int64(dimension))
            let response = await dispatchNative("mobile.terminal.artifact.thumbnail", .object(params))
            switch response {
            case .success:
                let native = try nativeThumbnail(
                    response, revision: authorization.identity.revision
                )
                let trusted = try await fallbackThumbnail(
                    authorization: authorization, dimension: dimension
                )
                guard native.pixelWidth == trusted.pixelWidth,
                      native.pixelHeight == trusted.pixelHeight else { throw Error.fileChanged }
                try await revalidate(authorization)
                return trusted
            case .failure(let code) where permitsRelayFallback(code):
                break
            case .failure(let code):
                throw Error.native(code)
            }
        }
        return try await fallbackThumbnail(
            authorization: authorization, dimension: dimension
        )
    }

    private func fallbackScan(
        scope: Scope,
        uploadedCandidates: [ArtifactAuthorizationStore.Candidate]
    ) async throws -> ScanResult {
        async let textResponse = dispatchNative(
            "surface.read_text",
            .object([
                "workspace_id": .string(scope.workspaceID),
                "surface_id": .string(scope.surfaceID),
                "lines": .int(200),
            ])
        )
        async let surfacesResponse = dispatchNative(
            "surface.list", .object(["workspace_id": .string(scope.workspaceID)])
        )
        let terminalText = try terminalText(from: await textResponse)
        let cwd = workingDirectory(from: await surfacesResponse, surfaceID: scope.surfaceID)
        let detected = detector.paths(in: terminalText)
        var seen = Set(uploadedCandidates.map(\.canonicalPath))
        var candidates = Array(uploadedCandidates.prefix(200))
        candidates.reserveCapacity(min(detected.count, 200))
        for path in detected {
            guard candidates.count < 200 else { break }
            guard let inspected = try? await inspect(path: path, cwd: cwd),
                  seen.insert(inspected.canonicalPath).inserted else { continue }
            candidates.append(candidate(from: inspected, source: .relayFallback))
        }
        return await record(scope: scope, candidates: candidates, source: .relayFallback)
    }

    private func recordNativeScan(
        _ value: JSONValue,
        scope: Scope,
        uploadedCandidates: [ArtifactAuthorizationStore.Candidate]
    ) async throws -> ScanResult {
        guard case .object(let object) = value,
              case .array(let artifacts)? = object["artifacts"] else { throw Error.native("invalid_response") }
        var seen = Set(uploadedCandidates.map(\.canonicalPath))
        var candidates = Array(uploadedCandidates.prefix(200))
        for artifact in artifacts.prefix(200) {
            guard candidates.count < 200 else { break }
            guard case .object(let fields) = artifact,
                  case .string(let path)? = fields["path"],
                  let inspected = try? await inspect(path: path, cwd: nil),
                  seen.insert(inspected.canonicalPath).inserted else { continue }
            candidates.append(candidate(from: inspected, source: .native))
        }
        return await record(scope: scope, candidates: candidates, source: .native)
    }

    private func trustedUploadCandidates(
        paths: [String]
    ) async -> [ArtifactAuthorizationStore.Candidate] {
        var seen: Set<String> = []
        var candidates: [ArtifactAuthorizationStore.Candidate] = []
        candidates.reserveCapacity(min(paths.count, 200))
        for path in paths.prefix(200) {
            guard let inspected = try? await inspect(path: path, cwd: nil),
                  seen.insert(inspected.canonicalPath).inserted else { continue }
            candidates.append(candidate(from: inspected, source: .relayFallback))
        }
        return candidates
    }

    private func record(
        scope: Scope,
        candidates: [ArtifactAuthorizationStore.Candidate],
        source: Source
    ) async -> ScanResult {
        let generation = await authorizations.record(scope: scope, candidates: candidates, source: source)
        return ScanResult(
            generation: generation.number,
            source: generation.source,
            artifacts: generation.items.map {
                Artifact(
                    id: $0.id,
                    displayName: $0.displayName,
                    kind: $0.kind,
                    size: $0.size,
                    mimeType: $0.mimeType,
                    revision: $0.revision
                )
            }
        )
    }

    private func locate(
        deviceID: String,
        artifactID: String
    ) async throws -> ArtifactAuthorizationStore.LocatedAuthorization {
        do {
            return try await authorizations.locate(deviceID: deviceID, artifactID: artifactID)
        } catch ArtifactAuthorizationStore.LookupError.expired {
            throw Error.expired
        } catch {
            throw Error.forbidden
        }
    }

    private func inspect(path: String, cwd: String?) async throws -> FileSystem.Inspected {
        let fileSystem = self.fileSystem
        return try await Task.detached { try fileSystem.inspectOperation(path, cwd) }.value
    }

    private func candidate(
        from inspected: FileSystem.Inspected,
        source: Source
    ) -> ArtifactAuthorizationStore.Candidate {
        .init(
            canonicalPath: inspected.canonicalPath,
            displayName: inspected.displayName,
            kind: inspected.kind,
            mimeType: inspected.mimeType,
            identity: inspected.identity,
            source: source
        )
    }

    private func resolveAndRevalidate(
        scope: Scope,
        generation: Int,
        artifactID: String,
        revision: String?
    ) async throws -> ArtifactAuthorizationStore.Authorization {
        let authorization: ArtifactAuthorizationStore.Authorization
        do {
            authorization = try await authorizations.resolve(
                scope: scope, generationNumber: generation, artifactID: artifactID
            )
        } catch ArtifactAuthorizationStore.LookupError.expired { throw Error.expired }
        catch { throw Error.forbidden }
        if let revision, revision != authorization.identity.revision { throw Error.fileChanged }
        try await revalidate(authorization)
        return authorization
    }

    private func revalidate(
        _ authorization: ArtifactAuthorizationStore.Authorization
    ) async throws {
        do {
            let current = try await inspect(path: authorization.canonicalPath, cwd: nil)
            guard current.canonicalPath == authorization.canonicalPath,
                  current.identity == authorization.identity else { throw Error.fileChanged }
        } catch let error as Error { throw error }
        catch { throw Error.fileChanged }
    }

    private func fallbackFetch(
        authorization: ArtifactAuthorizationStore.Authorization,
        offset: Int64,
        length: Int
    ) async throws -> FetchChunk {
        let fileSystem = self.fileSystem
        let data: Data
        do {
            data = try await Task.detached {
                try fileSystem.readOperation(
                    authorization.canonicalPath, authorization.identity, offset, length
                )
            }.value
        } catch { throw mapFileSystemFailure(error, changedAfterAuthorization: true) }
        return FetchChunk(
            data: data,
            offset: offset,
            totalSize: authorization.identity.size,
            revision: authorization.identity.revision,
            eof: offset + Int64(data.count) == authorization.identity.size
        )
    }

    private func fallbackThumbnail(
        authorization: ArtifactAuthorizationStore.Authorization,
        dimension: Int
    ) async throws -> Thumbnail {
        let fileSystem = self.fileSystem
        let generated: (Data, Int, Int)
        do {
            generated = try await Task.detached {
                try fileSystem.thumbnailOperation(
                    authorization.canonicalPath, authorization.identity, dimension
                )
            }.value
        } catch { throw mapFileSystemFailure(error, changedAfterAuthorization: true) }
        guard generated.0.count <= Self.maximumThumbnailBytes else { throw Error.unsupportedMedia }
        return Thumbnail(
            data: generated.0,
            pixelWidth: generated.1,
            pixelHeight: generated.2,
            revision: authorization.identity.revision
        )
    }

    private func terminalText(from response: NativeResult) throws -> String {
        switch response {
        case .success(.object(let object)):
            guard case .string(let text)? = object["text"] else { throw Error.native("invalid_response") }
            return text
        case .success: throw Error.native("invalid_response")
        case .failure(let code): throw Error.native(code)
        }
    }

    private func workingDirectory(from response: NativeResult, surfaceID: String) -> String? {
        guard case .success(.object(let object)) = response,
              case .array(let surfaces)? = object["surfaces"] else { return nil }
        for surface in surfaces {
            guard case .object(let fields) = surface,
                  case .string(let id)? = fields["id"], id == surfaceID else { continue }
            for key in ["working_directory", "current_directory", "requested_working_directory", "directory"] {
                if case .string(let value)? = fields[key], value.hasPrefix("/") { return value }
            }
        }
        return nil
    }

    private func nativePathDictionary(scope: Scope, path: String) -> [String: JSONValue] {
        [
            "workspace_id": .string(scope.workspaceID),
            "surface_id": .string(scope.surfaceID),
            "path": .string(path),
        ]
    }

    private func nativePathParams(scope: Scope, path: String) -> JSONValue {
        .object(nativePathDictionary(scope: scope, path: path))
    }

    private func permitsRelayFallback(_ code: String) -> Bool {
        code == "method_not_found" || code == "capability_absent"
    }

    private func nativeFetchChunk(
        _ response: NativeResult,
        expectedOffset: Int64,
        maximumLength: Int,
        identity: ArtifactAuthorizationStore.FileIdentity
    ) throws -> FetchChunk {
        guard case .success(.object(let fields)) = response else {
            if case .failure(let code) = response { throw Error.native(code) }
            throw Error.native("invalid_response")
        }
        guard case .string(let encoded)? = fields["data_b64"],
              let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded,
              case .int(let offset)? = fields["offset"], offset == expectedOffset,
              case .int(let total)? = fields["total_size"], total == identity.size,
              case .bool(let eof)? = fields["eof"],
              (eof || !data.isEmpty),
              data.count <= maximumLength,
              expectedOffset + Int64(data.count) <= total,
              eof == (expectedOffset + Int64(data.count) == total)
        else { throw Error.native("invalid_response") }
        return FetchChunk(
            data: data,
            offset: offset,
            totalSize: total,
            revision: identity.revision,
            eof: eof
        )
    }

    private func nativeThumbnail(_ response: NativeResult, revision: String) throws -> Thumbnail {
        guard case .success(.object(let fields)) = response else {
            if case .failure(let code) = response { throw Error.native(code) }
            throw Error.native("invalid_response")
        }
        guard case .string(let encoded)? = fields["data_b64"],
              let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded,
              data.count <= Self.maximumThumbnailBytes,
              data.starts(with: [0xFF, 0xD8]),
              case .int(let width)? = fields["pixel_width"], width > 0, width <= 1_024,
              case .int(let height)? = fields["pixel_height"], height > 0, height <= 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Int(width), image.height == Int(height)
        else { throw Error.native("invalid_response") }
        return Thumbnail(
            data: data,
            pixelWidth: image.width,
            pixelHeight: image.height,
            revision: revision
        )
    }

    private func mapFileSystemFailure(_ failure: Swift.Error, changedAfterAuthorization: Bool) -> Error {
        guard let failure = failure as? FileSystem.Failure else { return .unsupportedMedia }
        switch failure {
        case .fileChanged, .fileNotFound:
            return changedAfterAuthorization ? .fileChanged : .fileNotFound
        case .unsupportedMedia: return .unsupportedMedia
        case .invalidOffset: return .invalidParams
        }
    }
}
