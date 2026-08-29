import SwiftUI
import UniformTypeIdentifiers
import SharedKit

struct AttachmentPicker: View {
    let isEnabled: Bool
    let width: CGFloat
    let height: CGFloat
    let onPick: ([AttachmentSelection]) -> Void
    let onFailure: (String) -> Void

    @State private var isImporting = false

    var body: some View {
        Button(action: beginPicking) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: max(44, width), height: max(44, height))
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityIdentifier("AttachmentFileButton")
        .accessibilityLabel(String(
            localized: "attachment.file.button",
            defaultValue: "Attach files"
        ))
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
    }

    private func beginPicking() {
        #if DEBUG
        if AttachmentFixtureProvider.isEnabled {
            do {
                onPick(try AttachmentFixtureProvider.selections())
            } catch {
                onFailure(importFailureMessage)
            }
            return
        }
        #endif
        isImporting = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            onPick(urls.map { url in
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                return AttachmentSelection(url: url, declaredMIMEType: mimeType)
            })
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            onFailure(importFailureMessage)
        }
    }

    private var importFailureMessage: String {
        String(
            localized: "attachment.file.import_failed",
            defaultValue: "The selected files could not be accessed."
        )
    }
}

#if DEBUG
enum AttachmentFixtureProvider {
    private static let enabledKey = "CMUX_UI_TEST_FILE_FEATURE_FIXTURES"
    private static let scenarioKey = "CMUX_UI_TEST_ATTACHMENT_SCENARIO"
    private static let fixtureDirectoryName = "cmux-attachment-ui-fixtures"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enabledKey] == "1"
    }

    static func selections() throws -> [AttachmentSelection] {
        let root = fixtureRoot
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        switch ProcessInfo.processInfo.environment[scenarioKey] {
        case "boundary-cancel":
            return try boundarySelections(root: root)
        case "live-matrix":
            return try liveMatrixSelections(root: root)
        case "uploaded-image":
            return try uploadedImageSelections(root: root)
        default:
            return try happySelections(root: root)
        }
    }

    static func clean() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private static var fixtureRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            fixtureDirectoryName,
            isDirectory: true
        )
    }

    private static func happySelections(root: URL) throws -> [AttachmentSelection] {
        let names = [
            "report.pdf",
            "contract.docx",
            "hangul.hwp",
            "sheet.hwpx",
            "archive.zip",
            "mystery.unknown",
        ]
        return try names.enumerated().map { ordinal, name in
            let url = root.appendingPathComponent(name)
            try write(url: url, bytes: Int64(ordinal + 1))
            return AttachmentSelection(url: url)
        }
    }

    private static func liveMatrixSelections(root: URL) throws -> [AttachmentSelection] {
        try fixtureSelections(
            names: [
                "report.pdf",
                "contract.docx",
                "hangul.hwp",
                "sheet.hwpx",
                "archive.zip",
            ],
            root: root
        )
    }

    private static func uploadedImageSelections(root: URL) throws -> [AttachmentSelection] {
        let url = root.appendingPathComponent("uploaded-camera.png")
        try DemoContent.fileFeatureImageBytes.write(to: url, options: .atomic)
        return [AttachmentSelection(url: url, declaredMIMEType: "image/png")]
    }

    private static func fixtureSelections(names: [String], root: URL) throws -> [AttachmentSelection] {
        try names.enumerated().map { ordinal, name in
            let url = root.appendingPathComponent(name)
            try write(url: url, bytes: Int64(ordinal + 1))
            return AttachmentSelection(url: url)
        }
    }

    private static func boundarySelections(root: URL) throws -> [AttachmentSelection] {
        let mib: Int64 = 1024 * 1024
        let exactRemainder = 50 * mib - 5
        let first = root.appendingPathComponent("first-success.bin")
        let cancel = root.appendingPathComponent("cancel-target.bin")
        let boundaryA = root.appendingPathComponent("boundary-a.bin")
        let boundaryB = root.appendingPathComponent("boundary-b.bin")
        let duplicateA = root.appendingPathComponent("duplicate-a/duplicate.txt")
        let duplicateB = root.appendingPathComponent("duplicate-b/duplicate.txt")
        let unavailable = root.appendingPathComponent("provider-unavailable.pdf")
        let oversized = root.appendingPathComponent("oversized.bin")
        let tailA = root.appendingPathComponent("tail-a.zip")
        let tailB = root.appendingPathComponent("tail-b.unknown")

        try write(url: first, bytes: 1)
        try write(url: cancel, bytes: Int64(ChunkUploadLimits.maxFileBytes))
        try write(url: boundaryA, bytes: Int64(ChunkUploadLimits.maxFileBytes))
        try write(url: boundaryB, bytes: exactRemainder)
        try write(url: duplicateA, bytes: 1)
        try write(url: duplicateB, bytes: 1)
        try write(url: oversized, bytes: Int64(ChunkUploadLimits.maxFileBytes + 1))
        try write(url: tailA, bytes: 1)
        try write(url: tailB, bytes: 1)

        return [
            first,
            cancel,
            boundaryA,
            boundaryB,
            duplicateA,
            duplicateB,
            unavailable,
            oversized,
            tailA,
            tailB,
        ].map { AttachmentSelection(url: $0) }
    }

    private static func write(url: URL, bytes: Int64) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }
}
#endif
