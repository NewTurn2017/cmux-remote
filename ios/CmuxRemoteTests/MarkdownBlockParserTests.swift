import Foundation
import Testing
@testable import CmuxRemote

@Suite("MarkdownBlockParserTests", .timeLimit(.minutes(1)))
struct MarkdownBlockParserTests {
    @Test
    func testHeadingLevels() {
        let blocks = MarkdownBlockParser.parse("# One\n\n## Two\n\n#### Four\n")
        let headings = blocks.compactMap { block -> (Int, String)? in
            if case .heading(let level, let text) = block.kind { return (level, String(text.characters)) }
            return nil
        }
        #expect(headings.map(\.0) == [1, 2, 4])
        #expect(headings.map(\.1) == ["One", "Two", "Four"])
    }

    @Test
    func testNestedListDepthAndOrdinals() {
        let blocks = MarkdownBlockParser.parse("1. First\n2. Second\n   - Inner\n")
        let items = blocks.compactMap { block -> (String?, String, Int)? in
            if case .listItem(let marker, let text) = block.kind {
                return (marker, String(text.characters), block.listDepth)
            }
            return nil
        }
        #expect(items.map(\.0) == ["1.", "2.", "\u{2022}"])
        #expect(items.map(\.1) == ["First", "Second", "Inner"])
        #expect(items.map(\.2) == [1, 1, 2])
    }

    @Test
    func testBlockQuote() {
        let blocks = MarkdownBlockParser.parse("> Quoted note\n")
        #expect(blocks.count == 1)
        #expect(blocks.first?.quoteDepth == 1)
        if case .paragraph(let text)? = blocks.first?.kind {
            #expect(String(text.characters) == "Quoted note")
        } else {
            Issue.record("Expected a quoted paragraph, got \(blocks)")
        }
    }

    @Test
    func testCodeBlockKeepsLanguageAndLongLine() {
        let longLine = "let summary = \"" + String(repeating: "x", count: 300) + "\""
        let blocks = MarkdownBlockParser.parse("```swift\n\(longLine)\n```\n")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code(language: "swift", text: longLine))
    }

    @Test
    func testTableHeaderAndCells() throws {
        let blocks = MarkdownBlockParser.parse("| A | B |\n| :-- | --: |\n| 1 | 2 |\n| 3 | 4 |\n")
        guard case .table(let table)? = blocks.first?.kind else {
            Issue.record("Expected a table, got \(blocks)")
            return
        }
        #expect(table.header.map { String($0.characters) } == ["A", "B"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["1", "2"], ["3", "4"]])
        #expect(table.alignments == [.leading, .trailing])
    }

    @Test
    func testRelativeLinkBecomesPlainText() throws {
        let blocks = MarkdownBlockParser.parse("[setup](docs/setup.md) and [site](https://cmux.dev)\n")
        guard case .paragraph(let text)? = blocks.first?.kind else {
            Issue.record("Expected a paragraph, got \(blocks)")
            return
        }
        #expect(String(text.characters) == "setup and site")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://cmux.dev")!])
    }

    @Test
    func testImageBecomesAltTextPlaceholder() throws {
        let blocks = MarkdownBlockParser.parse("![Architecture diagram](images/arch.png)\n")
        guard case .paragraph(let text)? = blocks.first?.kind else {
            Issue.record("Expected a paragraph, got \(blocks)")
            return
        }
        #expect(String(text.characters).contains("Architecture diagram"))
        #expect(text.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test
    func testLargeDocumentParsesWithinTimeLimit() {
        let section = "## Section\n\n- item **bold** and `code`\n- [link](https://cmux.dev)\n\n```\nlet x = 1\n```\n\nParagraph text that wraps.\n\n"
        let repeatCount = (1024 * 1024) / section.utf8.count + 1
        let source = String(repeating: section, count: repeatCount)
        #expect(source.utf8.count >= 1024 * 1024)

        let blocks = MarkdownBlockParser.parse(source)

        #expect(blocks.count >= repeatCount * 4)
    }

    @Test
    func testPlainTextChunksByLineCount() {
        let text = (1...450).map { "line \($0)" }.joined(separator: "\n")
        let chunks = MarkdownBlockParser.plainTextChunks(text)
        #expect(chunks.count == 3)
        #expect(chunks.joined(separator: "\n") == text)
    }
}
