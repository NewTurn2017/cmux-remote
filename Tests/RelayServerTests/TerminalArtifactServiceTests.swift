import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SharedKit
import Testing
import UniformTypeIdentifiers
@testable import RelayServer

@Suite("TerminalArtifactService", .serialized)
struct TerminalArtifactServiceTests {
    actor TestClock {
        private var value: TimeInterval = 1_000

        func now() -> TimeInterval { value }
        func advance(by interval: TimeInterval) { value += interval }
    }

    actor Dispatcher {
        struct Call: Sendable, Equatable {
            let method: String
            let params: JSONValue
        }

        private var nativeScan: TerminalArtifactService.NativeResult
        private var nativeOperations: [String: TerminalArtifactService.NativeResult]
        private var terminalText: String
        private var cwd: String?
        private var calls: [Call] = []
        private var terminalGrid: [String]
        private var terminalRevision: Int
        private let operationHook: @Sendable (String) -> Void
        private let workspaceList: TerminalArtifactService.NativeResult?

        init(
            nativeScan: TerminalArtifactService.NativeResult = .failure(code: "method_not_found"),
            nativeOperations: [String: TerminalArtifactService.NativeResult] = [:],
            workspaceList: TerminalArtifactService.NativeResult? = nil,
            terminalText: String,
            cwd: String?,
            grid: [String]? = nil,
            revision: Int = 41,
            operationHook: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.nativeScan = nativeScan
            self.nativeOperations = nativeOperations
            self.workspaceList = workspaceList
            self.terminalText = terminalText
            self.cwd = cwd
            self.terminalGrid = grid ?? terminalText.split(separator: "\n").map(String.init)
            self.terminalRevision = revision
            self.operationHook = operationHook
        }

        func dispatch(method: String, params: JSONValue) -> TerminalArtifactService.NativeResult {
            calls.append(.init(method: method, params: params))
            operationHook(method)
            if ["surface.send_text", "surface.send_key", "terminal.input"].contains(method) {
                terminalGrid.append("unexpected mutation")
                terminalRevision &+= 1
            }
            if method == "mobile.terminal.artifact.scan" { return nativeScan }
            if method == "mobile.workspace.list", let workspaceList { return workspaceList }
            if let response = nativeOperations[method] { return response }
            if method == "surface.read_text" {
                return .success(.object(["text": .string(terminalText)]))
            }
            if method == "surface.list" {
                var surface: [String: JSONValue] = ["id": .string("surface")]
                if let cwd { surface["requested_working_directory"] = .string(cwd) }
                return .success(.object(["surfaces": .array([.object(surface)])]))
            }
            return .failure(code: "method_not_found")
        }

        func snapshotCalls() -> [Call] { calls }
        func snapshotTerminalState() -> (grid: [String], revision: Int) {
            (terminalGrid, terminalRevision)
        }
    }

    @Test("fallback strips terminal controls and detects every approved path shape in canonical order")
    func fallbackPathDetectionVariants() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let absolute = try write(Data("a".utf8), named: "absolute.png", in: root)
        let quoted = try write(Data("b".utf8), named: "quoted file.png", in: root)
        let escaped = try write(Data("c".utf8), named: "escaped file.png", in: root)
        let relative = try write(Data("d".utf8), named: "relative.png", in: root)
        let parent = try write(Data("e".utf8), named: "parent.png", in: root.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: parent) }
        let compiler = try write(Data("f".utf8), named: "source.swift", in: root)
        let fileURL = absolute.absoluteString
        let text = """
        \u{1B}]0;hidden /tmp/not-visible.png\u{7}\u{1B}[31m\(absolute.path)\u{1B}[0m
        '\(quoted.path)' \(escaped.path.replacingOccurrences(of: " ", with: "\\ "))
        ./relative.png ../\(parent.lastPathComponent) \(fileURL) \(compiler.path):12:9
        https://example.invalid/never.png
        """
        let dispatcher = Dispatcher(terminalText: text, cwd: root.path)
        let service = makeService(dispatcher: dispatcher)

        let scan = try await service.scan(scope: scope())

        #expect(scan.source == .relayFallback)
        #expect(scan.artifacts.map(\.displayName) == [
            absolute.lastPathComponent,
            quoted.lastPathComponent,
            escaped.lastPathComponent,
            relative.lastPathComponent,
            parent.lastPathComponent,
            compiler.lastPathComponent,
        ])
        #expect(Set(scan.artifacts.map(\.id)).count == scan.artifacts.count)
        #expect(scan.artifacts.allSatisfy { !$0.id.contains(root.path) })
    }

    @Test("relative paths require surface cwd while absolute paths remain eligible")
    func relativePathsRequireWorkingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let absolute = try write(Data([1]), named: "absolute.bin", in: root)
        _ = try write(Data([2]), named: "relative.bin", in: root)
        let dispatcher = Dispatcher(
            terminalText: "\(absolute.path) ./relative.bin",
            cwd: nil
        )

        let scan = try await makeService(dispatcher: dispatcher).scan(scope: scope())

        #expect(scan.artifacts.map(\.displayName) == ["absolute.bin"])
    }

    @Test("fallback rejects unshown files, directories, symlinks, special files, HTTP, and long paths without blocking")
    func fallbackSecurityRejectionsAndFIFO() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = try write(Data([7]), named: "shown.bin", in: root)
        let hidden = try write(Data([8]), named: "hidden.bin", in: root)
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let symlink = root.appendingPathComponent("escape.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: hidden)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let throughSymlink = try write(Data([9]), named: "nested.bin", in: realDirectory)
        let directorySymlink = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directorySymlink, withDestinationURL: realDirectory)
        let escapedDescendant = directorySymlink.appendingPathComponent(throughSymlink.lastPathComponent)
        let fifo = root.appendingPathComponent("pipe")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let overlong = "/" + String(repeating: "x", count: 4_097)
        let dispatcher = Dispatcher(
            terminalText: "\(shown.path) \(directory.path) \(symlink.path) \(escapedDescendant.path) \(fifo.path) https://host/a \(overlong)",
            cwd: root.path
        )
        let service = makeService(dispatcher: dispatcher)

        let scan = try await service.scan(scope: scope())

        #expect(scan.artifacts.map(\.displayName) == ["shown.bin"])
        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(scope: scope(), generation: scan.generation, artifactID: hidden.path)
        }
    }

    @Test("scan-time intermediate swap cannot authorize the symlink target")
    func scanTimeIntermediateSwapCannotAuthorizeSecret() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let visibleDirectory = root.appendingPathComponent("visible", isDirectory: true)
        let displacedDirectory = root.appendingPathComponent("visible-displaced", isDirectory: true)
        let secretDirectory = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: visibleDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: false)
        let shown = try write(Data("shown".utf8), named: "artifact.bin", in: visibleDirectory)
        _ = try write(Data("secret".utf8), named: "artifact.bin", in: secretDirectory)
        let fileSystem = TerminalArtifactService.FileSystem(liveCheckpoint: { checkpoint in
            guard case .beforeLeafAccess(operation: .inspect, let path) = checkpoint,
                  path.hasSuffix("/visible/artifact.bin") else { return }
            try! FileManager.default.moveItem(at: visibleDirectory, to: displacedDirectory)
            try! FileManager.default.createSymbolicLink(at: visibleDirectory, withDestinationURL: secretDirectory)
        })
        let service = makeService(
            dispatcher: Dispatcher(terminalText: shown.path, cwd: root.path),
            fileSystem: fileSystem
        )

        let scan = try await service.scan(scope: scope())

        #expect(scan.artifacts.isEmpty)
    }

    @Test("native success probes exact immutable methods and never exposes native paths")
    func nativeSuccessUsesExactMethods() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writePNG(width: 8, height: 4, named: "native.png", in: root)
        let bytes = try Data(contentsOf: png)
        let nativeThumbnail = try jpegData(from: png)
        let nativeScan: TerminalArtifactService.NativeResult = .success(.object([
            "artifacts": .array([.object([
                "path": .string(png.path),
                "kind": .string("image"),
                "display_name": .string("native.png"),
                "size": .int(Int64(bytes.count)),
            ])]),
        ]))
        let nativeOperations: [String: TerminalArtifactService.NativeResult] = [
            "mobile.terminal.artifact.stat": .success(.object([
                "exists": .bool(true), "is_directory": .bool(false),
                "size": .int(Int64(bytes.count)), "kind": .string("image"),
                "modified_at": .double(1_000), "mime_type": .string("image/png"),
            ])),
            "mobile.terminal.artifact.fetch": .success(.object([
                "data_b64": .string(bytes.base64EncodedString()), "offset": .int(0),
                "total_size": .int(Int64(bytes.count)), "eof": .bool(true),
            ])),
            "mobile.terminal.artifact.thumbnail": .success(.object([
                "data_b64": .string(nativeThumbnail.base64EncodedString()),
                "pixel_width": .int(8), "pixel_height": .int(4),
            ])),
        ]
        let dispatcher = Dispatcher(
            nativeScan: nativeScan,
            nativeOperations: nativeOperations,
            terminalText: "must not be read",
            cwd: nil
        )
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope(), advertisedCapabilities: ["terminal.artifact.v1"])
        let item = try #require(scan.artifacts.first)

        _ = try await service.stat(scope: scope(), generation: scan.generation, artifactID: item.id)
        let chunk = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
        )
        _ = try await service.thumbnail(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, maxDimension: 512
        )

        #expect(scan.source == .native)
        #expect(!item.id.contains(png.path))
        #expect(chunk.data == bytes)
        #expect(await dispatcher.snapshotCalls().map(\.method) == [
            "mobile.terminal.artifact.scan",
            "mobile.terminal.artifact.stat",
            "mobile.terminal.artifact.fetch",
            "mobile.terminal.artifact.thumbnail",
        ])
        let fetchParams = await dispatcher.snapshotCalls().first { $0.method == "mobile.terminal.artifact.fetch" }?.params
        guard case .object(let fetchFields)? = fetchParams else {
            Issue.record("native fetch was not called with object params")
            return
        }
        #expect(fetchFields["length"] == .int(Int64(TerminalArtifactService.maximumFetchBytes)))
    }

    @Test("method_not_found and capability absence fall back, but forbidden never does")
    func fallbackPolicyIsNarrow() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data([1]), named: "shown.bin", in: root)

        let missing = Dispatcher(terminalText: file.path, cwd: root.path)
        let missingScan = try await makeService(dispatcher: missing).scan(scope: scope())
        #expect(missingScan.source == .relayFallback)
        #expect(await missing.snapshotCalls().map(\.method).first == "mobile.terminal.artifact.scan")

        let absent = Dispatcher(terminalText: file.path, cwd: root.path)
        let absentScan = try await makeService(dispatcher: absent).scan(
            scope: scope(), advertisedCapabilities: []
        )
        #expect(absentScan.source == .relayFallback)
        #expect(!(await absent.snapshotCalls()).map(\.method).contains("mobile.terminal.artifact.scan"))

        let forbidden = Dispatcher(
            nativeScan: .failure(code: "forbidden"),
            terminalText: file.path,
            cwd: root.path
        )
        await #expect(throws: TerminalArtifactService.Error.native("forbidden")) {
            _ = try await makeService(dispatcher: forbidden).scan(scope: scope())
        }
        #expect(await forbidden.snapshotCalls().map(\.method) == ["mobile.terminal.artifact.scan"])
    }

    @Test("authorization expires, keeps four generations, and binds device workspace and surface")
    func authorizationTTLGenerationAndIdentityBinding() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data([1]), named: "shown.bin", in: root)
        let clock = TestClock()
        let dispatcher = Dispatcher(terminalText: file.path, cwd: root.path)
        let service = makeService(dispatcher: dispatcher, clock: clock)
        var scans: [TerminalArtifactService.ScanResult] = []
        for _ in 0..<5 { scans.append(try await service.scan(scope: scope())) }
        let oldest = scans[0]
        let newest = scans[4]
        let oldItem = try #require(oldest.artifacts.first)
        let newItem = try #require(newest.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(scope: scope(), generation: oldest.generation, artifactID: oldItem.id)
        }
        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(
                scope: .init(deviceID: "other", workspaceID: "workspace", surfaceID: "surface"),
                generation: newest.generation, artifactID: newItem.id
            )
        }
        await clock.advance(by: 600)
        await #expect(throws: TerminalArtifactService.Error.expired) {
            _ = try await service.stat(scope: scope(), generation: newest.generation, artifactID: newItem.id)
        }
    }

    @Test("authorization retains only 64 least-recently-used surface scopes")
    func authorizationSurfaceLRU() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data([1]), named: "shown.bin", in: root)
        let dispatcher = Dispatcher(terminalText: file.path, cwd: root.path)
        let service = makeService(dispatcher: dispatcher)
        let firstScope = scope(surfaceID: "surface-0")
        let first = try await service.scan(scope: firstScope)
        let firstItem = try #require(first.artifacts.first)
        for index in 1...64 {
            _ = try await service.scan(scope: scope(surfaceID: "surface-\(index)"))
        }

        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(
                scope: firstScope, generation: first.generation, artifactID: firstItem.id
            )
        }
    }

    @Test("scan caps one generation at 200 canonical deduplicated files")
    func generationItemCapAndCanonicalDeduplication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var paths: [String] = []
        for index in 0..<201 {
            paths.append(try write(Data([UInt8(index % 255)]), named: "f\(index).bin", in: root).path)
        }
        let text = ([paths[0], root.appendingPathComponent("./f0.bin").path] + paths).joined(separator: "\n")
        let dispatcher = Dispatcher(terminalText: text, cwd: root.path)

        let scan = try await makeService(dispatcher: dispatcher).scan(scope: scope())

        #expect(scan.artifacts.count == 200)
        #expect(scan.artifacts.first?.displayName == "f0.bin")
        #expect(scan.artifacts.last?.displayName == "f199.bin")
    }

    @Test("revision revalidation detects inode replacement and repeated replacement")
    func replacementInvalidatesAuthorization() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data("old".utf8), named: "shown.bin", in: root)
        let dispatcher = Dispatcher(terminalText: file.path, cwd: root.path)
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        for replacement in ["new-1", "new-2"] {
            let moved = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: file, to: moved)
            try Data(replacement.utf8).write(to: file)
            await #expect(throws: TerminalArtifactService.Error.fileChanged) {
                _ = try await service.fetch(
                    scope: scope(), generation: scan.generation, artifactID: item.id,
                    revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
                )
            }
            try? FileManager.default.removeItem(at: moved)
        }
    }

    @Test("fetch requires exact revision and offset and caps request chunks at 720 KiB")
    func exactFetchChunks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<(1 * 1_024 * 1_024 + 17)).map { UInt8($0 % 251) })
        let file = try write(bytes, named: "payload.bin", in: root)
        let service = makeService(dispatcher: Dispatcher(terminalText: file.path, cwd: root.path))
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        let first = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
        )
        let second = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: Int64(first.data.count), length: 1 * 1_024 * 1_024
        )

        let oversized = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: 1, length: 3 * 1_024 * 1_024 + 1
        )

        #expect(first.offset == 0 && !first.eof)
        #expect(first.data.count == TerminalArtifactService.maximumFetchBytes)
        #expect(second.offset == Int64(first.data.count) && second.eof)
        #expect(first.data + second.data == bytes)
        #expect(oversized.offset == 1 && !oversized.eof)
        #expect(oversized.data == bytes[1..<(1 + TerminalArtifactService.maximumFetchBytes)])
        for (offset, length) in [(Int64(0), 0), (Int64(-1), 1_024), (Int64(bytes.count + 1), 1_024)] {
            await #expect(throws: TerminalArtifactService.Error.invalidParams) {
                _ = try await service.fetch(
                    scope: scope(), generation: scan.generation, artifactID: item.id,
                    revision: item.revision, offset: offset, length: length
                )
            }
        }
        await #expect(throws: TerminalArtifactService.Error.fileChanged) {
            _ = try await service.fetch(
                scope: scope(), generation: scan.generation, artifactID: item.id,
                revision: "stale", offset: 0, length: 1 * 1_024 * 1_024
            )
        }
    }

    @Test("oversized length requests read the file in 720 KiB chunks through eof")
    func chunkedFetchReachesEOFAt720KiB() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        let file = try write(bytes, named: "large.bin", in: root)
        let service = makeService(dispatcher: Dispatcher(terminalText: file.path, cwd: root.path))
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        var chunks: [TerminalArtifactService.FetchChunk] = []
        var offset: Int64 = 0
        while chunks.count < 8 {
            let chunk = try await service.fetch(
                scope: scope(), generation: scan.generation, artifactID: item.id,
                revision: item.revision, offset: offset, length: 3 * 1_024 * 1_024
            )
            chunks.append(chunk)
            offset += Int64(chunk.data.count)
            if chunk.eof { break }
        }

        #expect(chunks.map(\.data.count) == [737_280, 737_280, 622_592])
        #expect(chunks.map(\.offset) == [0, 737_280, 1_474_560])
        #expect(chunks.map(\.eof) == [false, false, true])
        #expect(chunks.allSatisfy { $0.revision == item.revision && $0.totalSize == Int64(bytes.count) })
        #expect(chunks.reduce(Data()) { $0 + $1.data } == bytes)
    }

    @Test("a 1024 px noise thumbnail fits the 720 KiB response budget, even when cmux's own is larger")
    func largeThumbnailFitsTheResponseBudget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let noise = try write(
            BrowserCaptureTestImages.png(width: 1_024, height: 1_024, noise: true), named: "noise.png", in: root
        )
        let relayService = makeService(dispatcher: Dispatcher(terminalText: noise.path, cwd: root.path))
        let relayScan = try await relayService.scan(scope: scope())
        let relayItem = try #require(relayScan.artifacts.first)
        let relayThumbnail = try await relayService.thumbnail(
            scope: scope(), generation: relayScan.generation, artifactID: relayItem.id,
            revision: relayItem.revision, maxDimension: 1_024
        )

        let noiseBytes = try Data(contentsOf: noise)
        let nativeJPEG = try BrowserCaptureImageEncoder.encode(
            png: noiseBytes, maxImageBytes: .max, ladder: [.init(maxDimension: 1_024, quality: 0.95)]
        ).jpeg
        let nativeDispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: noise.path, size: noiseBytes.count),
            nativeOperations: ["mobile.terminal.artifact.thumbnail": nativeThumbnailResponse(
                data: nativeJPEG, width: 1_024, height: 1_024
            )],
            terminalText: "must not be read", cwd: nil
        )
        let nativeService = makeService(dispatcher: nativeDispatcher)
        let nativeScan = try await nativeService.scan(scope: scope())
        let nativeItem = try #require(nativeScan.artifacts.first)
        let nativeResult = try await nativeService.thumbnail(
            scope: scope(), generation: nativeScan.generation, artifactID: nativeItem.id,
            revision: nativeItem.revision, maxDimension: 1_024
        )

        #expect(relayThumbnail.data.starts(with: [0xFF, 0xD8]))
        #expect(relayThumbnail.pixelWidth == 1_024 && relayThumbnail.pixelHeight == 1_024)
        #expect(relayThumbnail.data.count <= 737_280)
        #expect(nativeJPEG.count > TerminalArtifactService.maximumThumbnailBytes)
        #expect(nativeJPEG.count <= TerminalArtifactService.maximumNativeThumbnailBytes)
        #expect(nativeResult.pixelWidth == 1_024 && nativeResult.pixelHeight == 1_024)
        #expect(nativeResult.data.count <= 737_280)
    }

    @Test("real PNG thumbnail is bounded JPEG with expected dimensions and leaves terminal state unchanged")
    func realSurfaceThumbnailAndFetch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writePNG(width: 80, height: 40, named: "visible.png", in: root)
        let original = try Data(contentsOf: png)
        let dispatcher = Dispatcher(
            terminalText: "visible image: \(png.path)", cwd: root.path,
            grid: ["visible image: \(png.path)"], revision: 77
        )
        let before = await dispatcher.snapshotTerminalState()
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)
        let thumbnail = try await service.thumbnail(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, maxDimension: 64
        )
        let fetched = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
        )
        let after = await dispatcher.snapshotTerminalState()

        #expect(scan.source == .relayFallback)
        #expect(thumbnail.data.starts(with: [0xFF, 0xD8]))
        #expect(thumbnail.pixelWidth == 64)
        #expect(thumbnail.pixelHeight == 32)
        #expect(thumbnail.data.count <= TerminalArtifactService.maximumThumbnailBytes)
        #expect(fetched.data == original && fetched.eof)
        #expect(before.grid == after.grid && before.revision == after.revision)
    }

    @Test("thumbnail rejects invalid dimensions corrupt media and oversized inputs")
    func thumbnailValidationCaps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = try write(Data("not an image".utf8), named: "corrupt.png", in: root)
        let hugePixels = try write(oversizedTIFFHeader(width: 10_000, height: 5_000), named: "huge.tiff", in: root)
        let oversized = root.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(32 * 1_024 * 1_024 + 1))
        try handle.close()
        let dispatcher = Dispatcher(
            terminalText: "\(corrupt.path) \(hugePixels.path) \(oversized.path)", cwd: root.path
        )
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope())
        #expect(scan.artifacts.count == 3)

        for item in scan.artifacts {
            await #expect(throws: TerminalArtifactService.Error.unsupportedMedia) {
                _ = try await service.thumbnail(
                    scope: scope(), generation: scan.generation, artifactID: item.id,
                    revision: item.revision, maxDimension: 32
                )
            }
        }
    }

    @Test("native stat fetch and thumbnail fall back only for unavailable methods or capabilities")
    func nativeOperationFallbackPolicy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writePNG(width: 80, height: 40, named: "native-fallback.png", in: root)
        let bytes = try Data(contentsOf: png)
        let scanResponse = nativeScanResponse(path: png.path, size: bytes.count)

        for unavailableCode in ["method_not_found", "capability_absent"] {
            let statDispatcher = Dispatcher(
                nativeScan: scanResponse,
                nativeOperations: ["mobile.terminal.artifact.stat": .failure(code: unavailableCode)],
                terminalText: "must not be read", cwd: nil
            )
            let statService = makeService(dispatcher: statDispatcher)
            let statScan = try await statService.scan(scope: scope())
            let statItem = try #require(statScan.artifacts.first)
            let stat = try await statService.stat(
                scope: scope(), generation: statScan.generation, artifactID: statItem.id
            )
            #expect(stat.size == Int64(bytes.count))
        }

        for unavailableCode in ["method_not_found", "capability_absent"] {
            let fetchDispatcher = Dispatcher(
                nativeScan: scanResponse,
                nativeOperations: ["mobile.terminal.artifact.fetch": .failure(code: unavailableCode)],
                terminalText: "must not be read", cwd: nil
            )
            let fetchService = makeService(dispatcher: fetchDispatcher)
            let fetchScan = try await fetchService.scan(scope: scope())
            let fetchItem = try #require(fetchScan.artifacts.first)
            let chunk = try await fetchService.fetch(
                scope: scope(), generation: fetchScan.generation, artifactID: fetchItem.id,
                revision: fetchItem.revision, offset: 0, length: 1 * 1_024 * 1_024
            )
            #expect(chunk.data == bytes)
        }

        for unavailableCode in ["method_not_found", "capability_absent"] {
            let thumbnailDispatcher = Dispatcher(
                nativeScan: scanResponse,
                nativeOperations: ["mobile.terminal.artifact.thumbnail": .failure(code: unavailableCode)],
                terminalText: "must not be read", cwd: nil
            )
            let thumbnailService = makeService(dispatcher: thumbnailDispatcher)
            let thumbnailScan = try await thumbnailService.scan(scope: scope())
            let thumbnailItem = try #require(thumbnailScan.artifacts.first)
            let thumbnail = try await thumbnailService.thumbnail(
                scope: scope(), generation: thumbnailScan.generation, artifactID: thumbnailItem.id,
                revision: thumbnailItem.revision, maxDimension: 64
            )
            #expect(thumbnail.data.starts(with: [0xFF, 0xD8]))
            #expect(thumbnail.pixelWidth == 64 && thumbnail.pixelHeight == 32)
        }
    }

    @Test("native authorization not-found and forbidden failures never use relay fallback")
    func nativeOperationAuthorizationFailuresDoNotFallback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writePNG(width: 8, height: 4, named: "native-errors.png", in: root)
        let bytes = try Data(contentsOf: png)
        let scanResponse = nativeScanResponse(path: png.path, size: bytes.count)

        let statDispatcher = Dispatcher(
            nativeScan: scanResponse,
            nativeOperations: ["mobile.terminal.artifact.stat": .failure(code: "forbidden")],
            terminalText: png.path, cwd: root.path
        )
        let statService = makeService(dispatcher: statDispatcher)
        let statScan = try await statService.scan(scope: scope())
        let statItem = try #require(statScan.artifacts.first)
        await #expect(throws: TerminalArtifactService.Error.native("forbidden")) {
            _ = try await statService.stat(
                scope: scope(), generation: statScan.generation, artifactID: statItem.id
            )
        }
        #expect(!(await statDispatcher.snapshotCalls()).map(\.method).contains("surface.read_text"))

        let fetchDispatcher = Dispatcher(
            nativeScan: scanResponse,
            nativeOperations: ["mobile.terminal.artifact.fetch": .failure(code: "file_not_found")],
            terminalText: png.path, cwd: root.path
        )
        let fetchService = makeService(dispatcher: fetchDispatcher)
        let fetchScan = try await fetchService.scan(scope: scope())
        let fetchItem = try #require(fetchScan.artifacts.first)
        await #expect(throws: TerminalArtifactService.Error.native("file_not_found")) {
            _ = try await fetchService.fetch(
                scope: scope(), generation: fetchScan.generation, artifactID: fetchItem.id,
                revision: fetchItem.revision, offset: 0, length: 1 * 1_024 * 1_024
            )
        }

        let thumbnailDispatcher = Dispatcher(
            nativeScan: scanResponse,
            nativeOperations: ["mobile.terminal.artifact.thumbnail": .failure(code: "unauthorized")],
            terminalText: png.path, cwd: root.path
        )
        let thumbnailService = makeService(dispatcher: thumbnailDispatcher)
        let thumbnailScan = try await thumbnailService.scan(scope: scope())
        let thumbnailItem = try #require(thumbnailScan.artifacts.first)
        await #expect(throws: TerminalArtifactService.Error.native("unauthorized")) {
            _ = try await thumbnailService.thumbnail(
                scope: scope(), generation: thumbnailScan.generation, artifactID: thumbnailItem.id,
                revision: thumbnailItem.revision
            )
        }
    }

    @Test("native stat revalidates identity after dispatch before publishing stale metadata")
    func nativeStatReplacementRace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data("AAAA".utf8), named: "native-stat-race.bin", in: root)
        let originalSize = try Data(contentsOf: file).count
        let displaced = root.appendingPathComponent("stat-displaced.bin")
        let dispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: file.path, size: originalSize),
            nativeOperations: ["mobile.terminal.artifact.stat": .success(.object([
                "exists": .bool(true), "is_directory": .bool(false),
                "size": .int(4), "kind": .string("binary"),
                "modified_at": .double(1_000),
                "mime_type": .string("application/octet-stream"),
            ]))],
            terminalText: "must not be read", cwd: nil,
            operationHook: { method in
                guard method == "mobile.terminal.artifact.stat" else { return }
                try? FileManager.default.moveItem(at: file, to: displaced)
                try? Data("BBBB".utf8).write(to: file)
            }
        )
        let service = makeService(
            dispatcher: dispatcher,
            fileSystem: TerminalArtifactService.FileSystem()
        )
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.fileChanged) {
            _ = try await service.stat(
                scope: scope(), generation: scan.generation, artifactID: item.id
            )
        }
    }

    @Test("native fetch revalidates identity after dispatch before publishing bytes")
    func nativeFetchReplacementRace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data("AAAA".utf8), named: "native-race.bin", in: root)
        let originalSize = try Data(contentsOf: file).count
        let displaced = root.appendingPathComponent("displaced.bin")
        let dispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: file.path, size: originalSize),
            nativeOperations: ["mobile.terminal.artifact.fetch": .success(.object([
                "data_b64": .string(Data("BBBB".utf8).base64EncodedString()),
                "offset": .int(0), "total_size": .int(4), "eof": .bool(true),
            ]))],
            terminalText: "must not be read", cwd: nil,
            operationHook: { method in
                guard method == "mobile.terminal.artifact.fetch" else { return }
                try? FileManager.default.moveItem(at: file, to: displaced)
                try? Data("BBBB".utf8).write(to: file)
            }
        )
        let service = makeService(
            dispatcher: dispatcher,
            fileSystem: TerminalArtifactService.FileSystem()
        )
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.fileChanged) {
            _ = try await service.fetch(
                scope: scope(), generation: scan.generation, artifactID: item.id,
                revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
            )
        }
    }

    @Test("native fetch swap-and-restore cannot publish unshown bytes")
    func nativeFetchSwapAndRestoreCannotPublishSecretBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let visibleDirectory = root.appendingPathComponent("visible", isDirectory: true)
        let displacedDirectory = root.appendingPathComponent("visible-displaced", isDirectory: true)
        let secretDirectory = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: visibleDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: false)
        let shownBytes = Data("shown!".utf8)
        let secretBytes = Data("secret".utf8)
        let shown = try write(shownBytes, named: "artifact.bin", in: visibleDirectory)
        _ = try write(secretBytes, named: "artifact.bin", in: secretDirectory)
        let dispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: shown.path, size: shownBytes.count),
            nativeOperations: ["mobile.terminal.artifact.fetch": .success(.object([
                "data_b64": .string(secretBytes.base64EncodedString()),
                "offset": .int(0), "total_size": .int(Int64(shownBytes.count)), "eof": .bool(true),
            ]))],
            terminalText: "must not be read", cwd: nil,
            operationHook: { method in
                guard method == "mobile.terminal.artifact.fetch" else { return }
                try! FileManager.default.moveItem(at: visibleDirectory, to: displacedDirectory)
                try! FileManager.default.createSymbolicLink(at: visibleDirectory, withDestinationURL: secretDirectory)
                try! FileManager.default.removeItem(at: visibleDirectory)
                try! FileManager.default.moveItem(at: displacedDirectory, to: visibleDirectory)
            }
        )
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.fileChanged) {
            _ = try await service.fetch(
                scope: scope(), generation: scan.generation, artifactID: item.id,
                revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
            )
        }
    }

    @Test("native fetch rejects empty non-EOF chunks at the relay boundary")
    func nativeFetchRejectsEmptyNonEOFChunk() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data("data".utf8), named: "nonempty.bin", in: root)
        let dispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: file.path, size: 4),
            nativeOperations: ["mobile.terminal.artifact.fetch": .success(.object([
                "data_b64": .string(""), "offset": .int(0),
                "total_size": .int(4), "eof": .bool(false),
            ]))],
            terminalText: "must not be read", cwd: nil
        )
        let service = makeService(dispatcher: dispatcher)
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.native("invalid_response")) {
            _ = try await service.fetch(
                scope: scope(), generation: scan.generation, artifactID: item.id,
                revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
            )
        }
    }

    @Test("native thumbnail validates native-first but returns only descriptor-bound pixels")
    func nativeThumbnailReplacementRaceAndTrustedLocalOutput() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(width: 8, height: 4, named: "native-source.png", in: root, byte: 0x20)
        let unshownSource = try writePNG(
            width: 8, height: 4, named: "unshown-thumbnail-source.png", in: root, byte: 0xE0
        )
        let jpeg = try jpegData(from: unshownSource)
        let sourceBytes = try Data(contentsOf: source)

        let successDispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: source.path, size: sourceBytes.count),
            nativeOperations: ["mobile.terminal.artifact.thumbnail": nativeThumbnailResponse(
                data: jpeg, width: 8, height: 4
            )],
            terminalText: "must not be read", cwd: nil
        )
        let successService = makeService(
            dispatcher: successDispatcher,
            fileSystem: TerminalArtifactService.FileSystem()
        )
        let successScan = try await successService.scan(scope: scope())
        let successItem = try #require(successScan.artifacts.first)
        let thumbnail = try await successService.thumbnail(
            scope: scope(), generation: successScan.generation, artifactID: successItem.id,
            revision: successItem.revision
        )
        #expect(thumbnail.data != jpeg)
        #expect(thumbnail.data.starts(with: [0xFF, 0xD8]))
        #expect(thumbnail.pixelWidth == 8 && thumbnail.pixelHeight == 4)
        #expect((await successDispatcher.snapshotCalls()).map(\.method).contains("mobile.terminal.artifact.thumbnail"))

        let raceFile = try write(Data("same-size-race-data".utf8), named: "native-thumb-race.png", in: root)
        let raceBytes = try Data(contentsOf: raceFile)
        let displaced = root.appendingPathComponent("thumb-displaced.png")
        let raceDispatcher = Dispatcher(
            nativeScan: nativeScanResponse(path: raceFile.path, size: raceBytes.count),
            nativeOperations: ["mobile.terminal.artifact.thumbnail": nativeThumbnailResponse(
                data: jpeg, width: 8, height: 4
            )],
            terminalText: "must not be read", cwd: nil,
            operationHook: { method in
                guard method == "mobile.terminal.artifact.thumbnail" else { return }
                try? FileManager.default.moveItem(at: raceFile, to: displaced)
                try? raceBytes.write(to: raceFile)
            }
        )
        let raceService = makeService(
            dispatcher: raceDispatcher,
            fileSystem: TerminalArtifactService.FileSystem()
        )
        let raceScan = try await raceService.scan(scope: scope())
        let raceItem = try #require(raceScan.artifacts.first)
        await #expect(throws: TerminalArtifactService.Error.fileChanged) {
            _ = try await raceService.thumbnail(
                scope: scope(), generation: raceScan.generation, artifactID: raceItem.id,
                revision: raceItem.revision
            )
        }
    }

    @Test("native thumbnail rejects truncated JPEG and claimed dimension mismatch")
    func nativeThumbnailPayloadValidation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writePNG(width: 8, height: 4, named: "native-validation.png", in: root)
        let bytes = try Data(contentsOf: png)
        let jpeg = try jpegData(from: png)

        for response in [
            nativeThumbnailResponse(data: Data([0xFF, 0xD8, 0x00]), width: 8, height: 4),
            nativeThumbnailResponse(data: jpeg, width: 9, height: 4),
        ] {
            let dispatcher = Dispatcher(
                nativeScan: nativeScanResponse(path: png.path, size: bytes.count),
                nativeOperations: ["mobile.terminal.artifact.thumbnail": response],
                terminalText: "must not be read", cwd: nil
            )
            let service = makeService(dispatcher: dispatcher)
            let scan = try await service.scan(scope: scope())
            let item = try #require(scan.artifacts.first)
            await #expect(throws: TerminalArtifactService.Error.native("invalid_response")) {
                _ = try await service.thumbnail(
                    scope: scope(), generation: scan.generation, artifactID: item.id,
                    revision: item.revision
                )
            }
        }
    }

    @Test("injected filesystem seam drives fallback reads and rejects a special file")
    func injectedFilesystemSeam() async throws {
        let identity = ArtifactAuthorizationStore.FileIdentity(
            device: 7, inode: 11, size: 4, modifiedSeconds: 20,
            modifiedNanoseconds: 30, revision: "injected-revision"
        )
        let regularPath = "/virtual/regular.bin"
        let specialPath = "/virtual/device"
        let fileSystem = TerminalArtifactService.FileSystem(
            inspect: { candidate, _ in
                guard candidate == regularPath else {
                    throw TerminalArtifactService.FileSystem.Failure.unsupportedMedia
                }
                return .init(
                    canonicalPath: regularPath, displayName: "regular.bin", kind: "binary",
                    mimeType: "application/octet-stream", identity: identity
                )
            },
            read: { path, expected, offset, _ in
                guard path == regularPath, expected == identity, offset == 0 else {
                    throw TerminalArtifactService.FileSystem.Failure.fileChanged
                }
                return Data("seam".utf8)
            },
            thumbnail: { _, _, _ in
                throw TerminalArtifactService.FileSystem.Failure.unsupportedMedia
            }
        )
        let dispatcher = Dispatcher(
            terminalText: "\(regularPath) \(specialPath)", cwd: nil
        )
        let service = makeService(dispatcher: dispatcher, fileSystem: fileSystem)
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)
        let chunk = try await service.fetch(
            scope: scope(), generation: scan.generation, artifactID: item.id,
            revision: item.revision, offset: 0, length: 1 * 1_024 * 1_024
        )

        #expect(scan.artifacts.map(\.displayName) == ["regular.bin"])
        #expect(chunk.data == Data("seam".utf8) && chunk.eof)
    }

    @Test("authorization rejects the right artifact ID in the wrong workspace")
    func wrongWorkspaceAuthorization() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data([1]), named: "workspace.bin", in: root)
        let service = makeService(dispatcher: Dispatcher(terminalText: file.path, cwd: root.path))
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(
                scope: .init(deviceID: "device", workspaceID: "wrong", surfaceID: "surface"),
                generation: scan.generation, artifactID: item.id
            )
        }
    }

    @Test("authorization rejects the right artifact ID on the wrong surface")
    func wrongSurfaceAuthorization() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data([1]), named: "surface.bin", in: root)
        let service = makeService(dispatcher: Dispatcher(terminalText: file.path, cwd: root.path))
        let scan = try await service.scan(scope: scope())
        let item = try #require(scan.artifacts.first)

        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(
                scope: .init(deviceID: "device", workspaceID: "workspace", surfaceID: "wrong"),
                generation: scan.generation, artifactID: item.id
            )
        }
    }

    @Test("document open registers the cmux markdown path and fetch returns its bytes")
    func documentOpenRegistersMarkdownPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data("# Probe\n\nhello **md**\n".utf8)
        let document = try write(content, named: "probe.md", in: root)
        let dispatcher = Dispatcher(
            workspaceList: workspaceListing(workspaceID: "WORKSPACE", surfaces: [
                surfaceEntry(id: "terminal-surface", kind: "terminal", filePath: nil),
                surfaceEntry(filePath: document.path),
            ]),
            terminalText: "",
            cwd: nil
        )
        let service = makeService(dispatcher: dispatcher)

        let opened = try await service.openDocument(scope: scope())
        let artifact = try #require(opened.artifacts.first)
        let chunk = try await service.fetch(deviceID: "device", artifactID: artifact.id, offset: 0)

        #expect(opened.artifacts.count == 1)
        #expect(opened.generation == 1)
        #expect(opened.source == .surfaceDocument)
        #expect(artifact.displayName == "probe.md")
        #expect(artifact.mimeType == "text/markdown")
        #expect(artifact.kind == "text")
        #expect(artifact.size == Int64(content.count))
        #expect(!artifact.id.contains(root.path))
        #expect(chunk.data == content && chunk.eof)
        #expect(chunk.totalSize == artifact.size && chunk.revision == artifact.revision)
        #expect(await dispatcher.snapshotCalls().map(\.method) == ["mobile.workspace.list"])
        #expect(await dispatcher.snapshotCalls().first?.params == .object([:]))
        await #expect(throws: TerminalArtifactService.Error.forbidden) {
            _ = try await service.stat(
                scope: scope(surfaceID: "terminal-surface"),
                generation: opened.generation, artifactID: artifact.id
            )
        }
    }

    @Test(
        "document open refuses surfaces that are not cmux markdown documents",
        arguments: [
            "terminal-kind", "browser-kind", "null-file-path", "relative-file-path",
            "missing-workspace", "missing-surface", "no-workspaces-key", "non-object-result",
        ]
    )
    func documentOpenRejectsNonDocumentSurfaces(variant: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try write(Data("# x".utf8), named: "doc.md", in: root)
        let listing: TerminalArtifactService.NativeResult
        switch variant {
        case "terminal-kind":
            listing = workspaceListing(surfaces: [surfaceEntry(kind: "terminal", filePath: document.path)])
        case "browser-kind":
            listing = workspaceListing(surfaces: [surfaceEntry(kind: "browser", filePath: document.path)])
        case "null-file-path":
            listing = workspaceListing(surfaces: [surfaceEntry(filePath: nil)])
        case "relative-file-path":
            listing = workspaceListing(surfaces: [surfaceEntry(filePath: "doc.md")])
        case "missing-workspace":
            listing = workspaceListing(workspaceID: "other", surfaces: [surfaceEntry(filePath: document.path)])
        case "missing-surface":
            listing = workspaceListing(surfaces: [surfaceEntry(id: "other", filePath: document.path)])
        case "no-workspaces-key":
            listing = .success(.object(["groups": .array([])]))
        default:
            listing = .success(.array([]))
        }
        let dispatcher = Dispatcher(workspaceList: listing, terminalText: "", cwd: nil)

        await #expect(throws: TerminalArtifactService.Error.surfaceNotDocument) {
            _ = try await makeService(dispatcher: dispatcher).openDocument(scope: scope())
        }
        #expect(await dispatcher.snapshotCalls().map(\.method) == ["mobile.workspace.list"])
    }

    @Test("document open maps an unsupported workspace list to surface_not_document and keeps other cmux failures")
    func documentOpenMapsMethodNotFoundToSurfaceNotDocument() async throws {
        let unsupported = Dispatcher(
            workspaceList: .failure(code: "method_not_found"), terminalText: "", cwd: nil
        )
        await #expect(throws: TerminalArtifactService.Error.surfaceNotDocument) {
            _ = try await makeService(dispatcher: unsupported).openDocument(scope: scope())
        }
        let failing = Dispatcher(workspaceList: .failure(code: "internal_error"), terminalText: "", cwd: nil)
        await #expect(throws: TerminalArtifactService.Error.native("internal_error")) {
            _ = try await makeService(dispatcher: failing).openDocument(scope: scope())
        }
    }

    @Test("document open reports a missing file as not found and an oversized file as size limit exceeded")
    func documentOpenMissingAndOversizedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("gone.md").path
        let missingDispatcher = Dispatcher(
            workspaceList: workspaceListing(surfaces: [surfaceEntry(filePath: missing)]),
            terminalText: "", cwd: nil
        )
        await #expect(throws: TerminalArtifactService.Error.fileNotFound) {
            _ = try await makeService(dispatcher: missingDispatcher).openDocument(scope: scope())
        }

        let exact = try write(Data(repeating: 0x61, count: 10), named: "exact.md", in: root)
        let over = try write(Data(repeating: 0x61, count: 11), named: "over.md", in: root)
        let exactService = makeService(dispatcher: Dispatcher(
            workspaceList: workspaceListing(surfaces: [surfaceEntry(filePath: exact.path)]),
            terminalText: "", cwd: nil
        ))
        let overService = makeService(dispatcher: Dispatcher(
            workspaceList: workspaceListing(surfaces: [surfaceEntry(filePath: over.path)]),
            terminalText: "", cwd: nil
        ))

        #expect(try await exactService.openDocument(scope: scope(), maximumBytes: 10).artifacts.count == 1)
        await #expect(throws: TerminalArtifactService.Error.sizeLimitExceeded) {
            _ = try await overService.openDocument(scope: scope(), maximumBytes: 10)
        }
        #expect(TerminalArtifactService.maximumDocumentBytes == 16 * 1_024 * 1_024)
    }

    @Test("document open follows only the /tmp alias and still rejects other symlinks")
    func documentOpenFollowsPrivateTmpAliasOnly() async throws {
        let name = "cmux-document-\(UUID().uuidString)"
        let real = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: real) }
        let content = Data("# tmp alias\n".utf8)
        _ = try write(content, named: "doc.md", in: real)
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("link.md"),
            withDestinationURL: real.appendingPathComponent("doc.md")
        )
        let nestedDirectory = real.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        _ = try write(Data("# nested".utf8), named: "nested.md", in: nestedDirectory)
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("linked"), withDestinationURL: nestedDirectory
        )
        func service(for cmuxPath: String) -> TerminalArtifactService {
            makeService(dispatcher: Dispatcher(
                workspaceList: workspaceListing(surfaces: [surfaceEntry(filePath: cmuxPath)]),
                terminalText: "", cwd: nil
            ))
        }

        let aliased = service(for: "/tmp/\(name)/doc.md")
        let opened = try await aliased.openDocument(scope: scope())
        let artifact = try #require(opened.artifacts.first)
        let chunk = try await aliased.fetch(deviceID: "device", artifactID: artifact.id, offset: 0)

        #expect(artifact.displayName == "doc.md")
        #expect(chunk.data == content && chunk.eof)
        await #expect(throws: TerminalArtifactService.Error.unsupportedMedia) {
            _ = try await service(for: "/tmp/\(name)/link.md").openDocument(scope: scope())
        }
        await #expect(throws: TerminalArtifactService.Error.fileNotFound) {
            _ = try await service(for: "/tmp/\(name)/linked/nested.md").openDocument(scope: scope())
        }
    }

    @Test("bare relative terminal paths resolve against the surface cwd and register only existing files")
    func bareRelativePathsUseSurfaceWorkingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false)
        _ = try write(Data("plan".utf8), named: "plan.md", in: docs)
        _ = try write(Data("readme".utf8), named: "README.md", in: root)
        let source = root.appendingPathComponent("src/a", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try write(Data("let x = 1".utf8), named: "b.swift", in: source)
        let text = "see docs/plan.md and README.md, missing/none.md, src/a/b.swift:12:3 v1.2.3 example.com"

        let withCwd = try await makeService(dispatcher: Dispatcher(terminalText: text, cwd: root.path))
            .scan(scope: scope())
        let withoutCwd = try await makeService(dispatcher: Dispatcher(terminalText: text, cwd: nil))
            .scan(scope: scope())

        #expect(withCwd.artifacts.map(\.displayName) == ["plan.md", "README.md", "b.swift"])
        #expect(withoutCwd.artifacts.isEmpty)
    }

    private func workspaceListing(
        workspaceID: String = "workspace",
        surfaces: [JSONValue]
    ) -> TerminalArtifactService.NativeResult {
        .success(.object([
            "groups": .array([]),
            "workspaces": .array([.object([
                "id": .string(workspaceID),
                "title": .string("w2 probe"),
                "current_directory": .string("/private/tmp"),
                "surfaces": .array(surfaces),
            ])]),
        ]))
    }

    private func surfaceEntry(
        id: String = "surface",
        kind: String = "markdown",
        filePath: String?
    ) -> JSONValue {
        .object([
            "surface_id": .string(id),
            "kind": .string(kind),
            "file_path": filePath.map(JSONValue.string) ?? .null,
            "is_focused": .bool(false),
            "title": .string("document"),
        ])
    }

    private func makeService(
        dispatcher: Dispatcher,
        clock: TestClock = TestClock(),
        fileSystem: TerminalArtifactService.FileSystem = .init()
    ) -> TerminalArtifactService {
        TerminalArtifactService(
            dispatchNative: { method, params in await dispatcher.dispatch(method: method, params: params) },
            fileSystem: fileSystem,
            now: { await clock.now() }
        )
    }

    private func nativeScanResponse(
        path: String,
        size: Int
    ) -> TerminalArtifactService.NativeResult {
        .success(.object([
            "artifacts": .array([.object([
                "path": .string(path), "kind": .string("image"),
                "display_name": .string(URL(fileURLWithPath: path).lastPathComponent),
                "size": .int(Int64(size)),
            ])]),
        ]))
    }

    private func nativeThumbnailResponse(
        data: Data,
        width: Int,
        height: Int
    ) -> TerminalArtifactService.NativeResult {
        .success(.object([
            "data_b64": .string(data.base64EncodedString()),
            "pixel_width": .int(Int64(width)), "pixel_height": .int(Int64(height)),
        ]))
    }

    private func scope(surfaceID: String = "surface") -> TerminalArtifactService.Scope {
        .init(deviceID: "device", workspaceID: "workspace", surfaceID: surfaceID)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writePNG(
        width: Int,
        height: Int,
        named name: String,
        in directory: URL,
        byte: UInt8 = 0x7F
    ) throws -> URL {
        let rowBytes = width * 4
        let pixels = Data(repeating: byte, count: rowBytes * height)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try write(data as Data, named: name, in: directory)
    }

    private func jpegData(from imageURL: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func oversizedTIFFHeader(width: UInt32, height: UInt32) -> Data {
        var bytes: [UInt8] = [
            0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x00, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00,
        ]
        bytes += withUnsafeBytes(of: width.littleEndian, Array.init)
        bytes += [0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00]
        bytes += withUnsafeBytes(of: height.littleEndian, Array.init)
        bytes += [0, 0, 0, 0]
        return Data(bytes)
    }
}
