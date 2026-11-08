import Foundation
import Testing
@testable import CmuxRemote

@Suite("DocumentContentKindTests")
struct DocumentContentKindTests {
    @Test
    func testMarkdownByExtensionAndMime() {
        #expect(DocumentContentKind.classify(filename: "notes.md", mimeType: "application/octet-stream", isImage: false) == .markdown)
        #expect(DocumentContentKind.classify(filename: "README.markdown", mimeType: "text/markdown", isImage: false) == .markdown)
        #expect(DocumentContentKind.classify(filename: "plan", mimeType: "text/markdown; charset=utf-8", isImage: false) == .markdown)
    }

    @Test
    func testTextByMimeAndExtension() {
        let mimeCases = [
            ("a.json", "application/json"),
            ("a.yml", "application/x-yaml"),
            ("a.xml", "application/xml"),
            ("a.js", "application/javascript"),
            ("table.csv", "text/csv"),
            ("notes.txt", "text/plain"),
        ]
        for (filename, mime) in mimeCases {
            #expect(DocumentContentKind.classify(filename: filename, mimeType: mime, isImage: false) == .text, "\(filename)")
        }
        for filename in ["app.log", "Cargo.toml", "main.swift", "run.sh", "fix.diff", "Makefile", ".gitignore"] {
            #expect(
                DocumentContentKind.classify(filename: filename, mimeType: "application/octet-stream", isImage: false) == .text,
                "\(filename)"
            )
        }
    }

    @Test
    func testImageWinsOverExtension() {
        #expect(DocumentContentKind.classify(filename: "diagram.md", mimeType: "image/png", isImage: true) == .image)
    }

    @Test
    func testBinaryFallsBack() {
        #expect(DocumentContentKind.classify(filename: "build-notes.pdf", mimeType: "application/pdf", isImage: false) == .binary)
        #expect(DocumentContentKind.classify(filename: "a.bin", mimeType: "application/macbinary", isImage: false) == .binary)
        #expect(DocumentContentKind.classify(filename: "archive.zip", mimeType: "application/zip", isImage: false) == .binary)
    }

    @Test
    func testExtensionCaseInsensitive() {
        #expect(DocumentContentKind.classify(filename: "CHANGELOG.MD", mimeType: "application/octet-stream", isImage: false) == .markdown)
        #expect(DocumentContentKind.classify(filename: "BUILD.LOG", mimeType: "application/octet-stream", isImage: false) == .text)
    }

    @Test
    func testLikelyTextRequiresUTF8WithoutNUL() {
        #expect(DocumentContentKind.isLikelyText(Data("hello 한글".utf8)))
        #expect(!DocumentContentKind.isLikelyText(Data([0x61, 0x00, 0x62])))
        #expect(!DocumentContentKind.isLikelyText(Data([0x61, 0xFF, 0x62])))

        let hangul = Data("한".utf8)
        let cutInsideSample = Data("ab".utf8) + hangul.prefix(2) + Data("tail".utf8)
        #expect(DocumentContentKind.isLikelyText(cutInsideSample, sampleBytes: 4))
    }
}
