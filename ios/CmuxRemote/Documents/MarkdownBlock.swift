import Foundation

struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case listItem(marker: String?, text: AttributedString)
        case code(language: String?, text: String)
        case table(MarkdownTable)
        case thematicBreak
    }

    let id: Int
    let kind: Kind
    let listDepth: Int
    let quoteDepth: Int
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    var alignments: [Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]

    var columnCount: Int {
        max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
    }
}

enum DocumentBody: Equatable, Sendable {
    case markdown([MarkdownBlock])
    case plain([String])
}

struct RenderedDocument: Equatable, Sendable {
    let document: TextDocument
    let body: DocumentBody

    static func render(_ document: TextDocument, asMarkdown: Bool) async -> RenderedDocument {
        await Task.detached(priority: .userInitiated) {
            RenderedDocument(
                document: document,
                body: asMarkdown
                    ? .markdown(MarkdownBlockParser.parse(document.text))
                    : .plain(MarkdownBlockParser.plainTextChunks(document.text))
            )
        }.value
    }
}
