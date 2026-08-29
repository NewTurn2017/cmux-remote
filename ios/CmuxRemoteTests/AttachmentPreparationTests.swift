import CryptoKit
import Foundation
import Testing
import UIKit
@testable import CmuxRemote

@Suite("Attachment preparation")
struct AttachmentPreparationTests {
    @Test
    func stagesMixedFilesWithDeterministicMetadataAndPickerOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = RecordingSecurityScope()
        let coordinator = FoundationAttachmentFileCoordinator(fileManager: fixture.fileManager)
        let preparer = AttachmentPreparer(
            securityScope: scope,
            fileCoordinator: coordinator,
            fileManager: fixture.fileManager,
            temporaryDirectory: fixture.stagingDirectory
        )
        let selections = [
            AttachmentSelection(url: fixture.write("first/report.PDF", bytes: [1, 2, 3]), declaredMIMEType: "text/plain"),
            AttachmentSelection(url: fixture.write("second/report.PDF", bytes: [4]), declaredMIMEType: nil),
            AttachmentSelection(url: fixture.write("contract.docx", bytes: [5, 6]), declaredMIMEType: "application/octet-stream"),
            AttachmentSelection(url: fixture.write("한글.hwp", bytes: [7]), declaredMIMEType: "text/plain"),
            AttachmentSelection(url: fixture.write("sheet.hwpx", bytes: [8]), declaredMIMEType: "bad mime"),
            AttachmentSelection(url: fixture.write("archive.zip", bytes: [9, 10]), declaredMIMEType: "application/x-custom"),
            AttachmentSelection(url: fixture.write("photo.PNG", bytes: [11, 12, 13]), declaredMIMEType: "image/jpeg"),
            AttachmentSelection(url: fixture.write("mystery", bytes: [14]), declaredMIMEType: "application/x-custom")
        ]

        let prepared = try await preparer.prepare(selections)

        #expect(prepared.map { $0.ordinal } == Array(0..<selections.count))
        #expect(prepared.map { $0.bytes } == [3, 1, 2, 1, 1, 2, 3, 1])
        #expect(prepared.map { $0.filename } == [
            "report.pdf", "report.pdf", "contract.docx", "한글.hwp", "sheet.hwpx", "archive.zip", "photo.png", "attachment.bin"
        ])
        #expect(prepared.map { $0.mimeType } == [
            "application/pdf", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/x-hwp", "application/vnd.hancom.hwpx", "application/zip", "image/png", "application/x-custom"
        ])
        #expect(prepared.map { $0.sha256 } == [
            "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
            "e52d9c508c502347344d8c07ad91cbd6068afc75ff6292f062a09ca381c89e71",
            "c42522128b49193de8cd45d8f7589cd7e085e65f138640d57d4482e5f7189623",
            "ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879",
            "beead77994cf573341ec17b58bbf7eb34d2711c993c1d976b128b3188dc1829a",
            "34a6225b83a638ed08f01ecdbf30cf0be3478ffdd36be92295fee92c5585d57c",
            "c9e0f2aeea4897312ca3ff7900849dceebd81a8ed6dec3882954f6a9a03ebd27",
            "4d7b3ef7300acf70c892d8327db8272f54434adbc61a4e130a563cb59a0d0f47"
        ])
        #expect(prepared.allSatisfy { fixture.fileManager.fileExists(atPath: $0.stagedURL.path) })
        let starts = await scope.starts
        let stops = await scope.stops
        #expect(starts == selections.count)
        #expect(stops == selections.count)
    }

    @Test
    func validParameterizedMIMEIsAcceptedAndUnquotedWhitespaceIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preparer = fixture.preparer(scope: RecordingSecurityScope())
        let valid = try await preparer.prepare([
            AttachmentSelection(url: fixture.write("data.custom", bytes: [1]), declaredMIMEType: "text/plain; charset=utf-8")
        ])
        #expect(valid.first?.mimeType == "text/plain; charset=utf-8")

        let invalid = try await preparer.prepare([
            AttachmentSelection(url: fixture.write("other.custom", bytes: [2]), declaredMIMEType: "text/plain;charset=hello world")
        ])
        #expect(invalid.first?.mimeType == "application/octet-stream")
    }

    @Test
    func normalizedSuffixDrivesKnownMIMEAfterBidiRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.write("report.PDF\u{202E}", bytes: [1])
        let prepared = try await fixture.preparer(scope: RecordingSecurityScope()).prepare([
            AttachmentSelection(url: source, declaredMIMEType: "text/plain")
        ])
        #expect(prepared.first?.filename == "report.pdf")
        #expect(prepared.first?.mimeType == "application/pdf")
    }

    @Test
    func preservesLeadingHyphenWhileRemovingOnlyApprovedDotsAndTrailingCharacters() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.write(".-report.pdf... ", bytes: [1])
        let prepared = try await fixture.preparer(scope: RecordingSecurityScope()).prepare([
            AttachmentSelection(url: source, declaredMIMEType: nil)
        ])
        #expect(prepared.first?.filename == "-report.pdf")
    }

    @Test
    func realCoordinatorAcceptsExactLimitAndDeletesLimitPlusOnePartial() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preparer = fixture.preparer(scope: RecordingSecurityScope())
        let exact = fixture.writeRepeating("exact.bin", count: AttachmentPreparationLimits.maxFileBytes)
        let prepared = try await preparer.prepare([AttachmentSelection(url: exact)])
        let exactStagedURL = try #require(prepared.first?.stagedURL)
        #expect(prepared.first?.bytes == AttachmentPreparationLimits.maxFileBytes)

        let oversized = fixture.writeRepeating("oversized.bin", count: AttachmentPreparationLimits.maxFileBytes + 1)
        do {
            _ = try await preparer.prepare([AttachmentSelection(url: oversized)])
            Issue.record("an oversized attachment must fail")
        } catch {
            #expect(error as? AttachmentPreparationError == .fileTooLarge)
        }
        #expect(fixture.stagedFiles() == [exactStagedURL])
    }

    @Test
    func realCoordinatorRejectsStaleSourceAndDeletesPartial() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = RecordingSecurityScope()
        let source = fixture.write("stale.pdf", bytes: [1, 2])
        try fixture.fileManager.removeItem(at: source)

        do {
            _ = try await fixture.preparer(scope: scope).prepare([AttachmentSelection(url: source)])
            Issue.record("a stale provider URL must fail")
        } catch {
            #expect(error as? AttachmentPreparationError == .sourceUnavailable)
        }
        let starts = await scope.starts
        let stops = await scope.stops
        #expect(starts == 1)
        #expect(stops == 1)
        #expect(fixture.stagedFiles().isEmpty)
    }

    @Test
    func cancellationUsesTaskCancellationAndBalancesGrantedScope() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = RecordingSecurityScope()
        let gate = PartialCreationGate()
        let source = fixture.writeRepeating("cancel.bin", count: 1024 * 1024)
        let secondSource = fixture.write("second.bin", bytes: [2])
        let task = Self.makeCancellationTask(
            source: source,
            secondSource: secondSource,
            stagingDirectory: fixture.stagingDirectory,
            scope: scope,
            gate: gate
        )
        await gate.waitForPartial()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("cancellation must stop staging")
        } catch {
            #expect(error as? AttachmentPreparationError == .cancelled)
        }
        #expect(fixture.stagedFiles().isEmpty)
        #expect(await scope.starts == 1)
        #expect(await scope.stops == 1)
        #expect(await scope.startedURLs == [source])
    }

    @Test
    func exactRealPNGStagesAsNonzeroDecodableImageThroughPreparer() async throws {
        let path = ProcessInfo.processInfo.environment["CMUX_EXACT_PHOTO_PATH"]
            ?? "/Users/genie/Downloads/IMG_2330.PNG"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let stager = FoundationAttachmentPhotoStager(
            fileManager: FileManager(),
            temporaryDirectory: fixture.stagingDirectory,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        let selection = try await stager.stage(original)
        let stagedBytes = try Data(contentsOf: selection.url)
        let stagedImage = try #require(UIImage(data: stagedBytes))
        let prepared = try #require(try await fixture.preparer(scope: RecordingSecurityScope()).prepare([selection]).first)

        #expect(original.count == 431_175)
        #expect(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            == "39e2595aee283d7166ad9431655f529791453650f1e81b13b27a9bd49f8a3aac")
        #expect(stagedBytes.count > 0)
        #expect(selection.declaredMIMEType == "image/jpeg")
        #expect(selection.url.pathExtension == "jpg")
        #expect(max(stagedImage.size.width, stagedImage.size.height) <= 2_048)
        #expect(prepared.bytes == stagedBytes.count)
        #expect(prepared.bytes > 0)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.filename == selection.url.lastPathComponent)
        #expect(fixture.fileManager.fileExists(atPath: prepared.stagedURL.path))
        await stager.remove(selection)
        #expect(!fixture.fileManager.fileExists(atPath: selection.url.path))
    }

    @Test
    func decodesAndDownscalesLargeUIImageToValidJPEG() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_000)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_000))
        }
        let png = try #require(source.pngData())
        let stager = FoundationAttachmentPhotoStager(
            fileManager: FileManager(),
            temporaryDirectory: fixture.stagingDirectory
        )

        let selection = try await stager.stage(png)
        let output = try Data(contentsOf: selection.url)
        let image = try #require(UIImage(data: output))

        #expect(output.count > 0)
        #expect(selection.declaredMIMEType == "image/jpeg")
        #expect(image.size.width == 2_048)
        #expect(image.size.height > 0)
        #expect(image.size.height < image.size.width)
        await stager.remove(selection)
    }

    @Test
    func rapidSelectionsWithSameTimestampUseUniqueFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData())
        let stager = FoundationAttachmentPhotoStager(
            fileManager: FileManager(),
            temporaryDirectory: fixture.stagingDirectory,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        let selections = try await withThrowingTaskGroup(of: AttachmentSelection.self) { group in
            for _ in 0..<8 {
                group.addTask { try await stager.stage(png) }
            }
            var values: [AttachmentSelection] = []
            for try await selection in group { values.append(selection) }
            return values
        }

        #expect(Set(selections.map(\.url)).count == selections.count)
        #expect(selections.allSatisfy { fixture.fileManager.fileExists(atPath: $0.url.path) })
        for selection in selections { await stager.remove(selection) }
        #expect(selections.allSatisfy { !fixture.fileManager.fileExists(atPath: $0.url.path) })
    }

    @Test
    func malformedPhotoDataFailsWithoutCreatingMislabeledJPEG() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stager = FoundationAttachmentPhotoStager(
            fileManager: FileManager(),
            temporaryDirectory: fixture.stagingDirectory
        )

        do {
            _ = try await stager.stage(Data("not an image".utf8))
            Issue.record("malformed photo bytes must not be labeled and staged as JPEG")
        } catch {
            #expect(error as? AttachmentPhotoStagingError == .invalidImage)
        }
        #expect(fixture.stagedFiles().isEmpty)
    }

    private static func makeCancellationTask(
        source: URL,
        secondSource: URL,
        stagingDirectory: URL,
        scope: RecordingSecurityScope,
        gate: PartialCreationGate
    ) -> Task<[PreparedAttachment], Error> {
        Task { @Sendable in
            let fileManager = FileManager()
            let preparer = AttachmentPreparer(
                securityScope: scope,
                fileCoordinator: FoundationAttachmentFileCoordinator(
                    fileManager: fileManager,
                    partialObserver: gate
                ),
                fileManager: fileManager,
                temporaryDirectory: stagingDirectory
            )
            return try await preparer.prepare([
                AttachmentSelection(url: source),
                AttachmentSelection(url: secondSource)
            ])
        }
    }

    @Test
    func normalizationCapsUTF8BasenameAndHandlesUnknownName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.write(String(repeating: "한", count: 70) + ".custom", bytes: [1])
        let prepared = try await fixture.preparer(scope: RecordingSecurityScope()).prepare([
            AttachmentSelection(url: source, declaredMIMEType: "not a mime")
        ])
        let name = try #require(prepared.first?.filename)
        #expect(name.split(separator: ".", maxSplits: 1).first?.utf8.count ?? 0 <= 180)
        #expect(prepared.first?.mimeType == "application/octet-stream")

        let unknown = fixture.write("...", bytes: [])
        let unknownPrepared = try await fixture.preparer(scope: RecordingSecurityScope()).prepare([
            AttachmentSelection(url: unknown, declaredMIMEType: "application/x-test")
        ])
        #expect(unknownPrepared.first?.filename == "attachment.bin")
    }

    @Test
    func readableURLProceedsWhenSecurityScopeIsNotGranted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scope = RecordingSecurityScope(startResult: false)
        let source = fixture.write("readable.bin", bytes: [1, 2, 3])
        let prepared = try await fixture.preparer(scope: scope).prepare([AttachmentSelection(url: source)])
        #expect(prepared.count == 1)
        #expect(await scope.starts == 1)
        #expect(await scope.stops == 0)
    }

    @Test
    func quotesPOSIXPathsAndEscapesApostrophes() {
        #expect(ShellPathQuoter.quote("/tmp/it's file.pdf") == "'/tmp/it'\\''s file.pdf'")
        #expect(ShellPathQuoter.quote("/tmp/plain") == "'/tmp/plain'")
    }
}

private struct Fixture {
    let fileManager = FileManager()
    let root: URL
    let stagingDirectory: URL

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("attachment-tests-\(UUID().uuidString)")
        stagingDirectory = root.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    func preparer(
        scope: any AttachmentSecurityScope,
        partialObserver: (any AttachmentPartialCreationObserver)? = nil
    ) -> AttachmentPreparer {
        AttachmentPreparer(
            securityScope: scope,
            fileCoordinator: FoundationAttachmentFileCoordinator(fileManager: fileManager, partialObserver: partialObserver),
            fileManager: fileManager,
            temporaryDirectory: stagingDirectory
        )
    }

    func write(_ name: String, bytes: [UInt8]) -> URL {
        let url = root.appendingPathComponent(name)
        try! fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(bytes).write(to: url)
        return url
    }

    func writeRepeating(_ name: String, count: Int64) -> URL {
        let url = root.appendingPathComponent(name)
        let handle = try! FileHandle(forWritingTo: createEmpty(url))
        let block = Data(repeating: 0xA5, count: 1024 * 1024)
        var remaining = count
        while remaining > 0 {
            let size = Int(min(Int64(block.count), remaining))
            try! handle.write(contentsOf: block.prefix(size))
            remaining -= Int64(size)
        }
        try! handle.close()
        return url
    }

    func createEmpty(_ url: URL) -> URL {
        fileManager.createFile(atPath: url.path, contents: nil)
        return url
    }

    func stagedFiles() -> [URL] {
        files(at: stagingDirectory)
    }

    func files(at directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }
}

private actor RecordingSecurityScope: AttachmentSecurityScope {
    private let startResult: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var startedURLs: [URL] = []

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        starts += 1
        startedURLs.append(url)
        return startResult
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        stops += 1
    }
}

private actor PartialCreationGate: AttachmentPartialCreationObserver {
    private let partialStream: AsyncStream<Void>
    private let partialContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (partialStream, partialContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func partialCreated(at url: URL) async {
        partialContinuation.yield(())
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForPartial() async {
        var iterator = partialStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
