import Foundation

enum MarkdownBlockParser {
    static let plainTextLinesPerBlock = 200
    private static let tappableSchemes: Set<String> = ["http", "https", "mailto"]

    static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph(AttributedString(source)), listDepth: 0, quoteDepth: 0)]
        }
        var builder = Builder()
        for run in parsed.runs {
            builder.append(
                sanitized(parsed[run.range], link: run.link, imageURL: run.imageURL),
                intent: run.presentationIntent
            )
        }
        return builder.finish()
    }

    static func plainTextChunks(_ text: String, linesPerBlock: Int = plainTextLinesPerBlock) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count, by: linesPerBlock).map { start in
            lines[start..<min(start + linesPerBlock, lines.count)].joined(separator: "\n")
        }
    }

    private static func sanitized(_ slice: AttributedSubstring, link: URL?, imageURL: URL?) -> AttributedString {
        var text = AttributedString(slice)
        text.presentationIntent = nil
        if imageURL != nil {
            let alt = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            var placeholder = AttributedString(alt.isEmpty
                ? String(localized: "document.viewer.image_placeholder_untitled", defaultValue: "Image")
                : String(
                    format: String(localized: "document.viewer.image_placeholder", defaultValue: "Image: %@"),
                    alt
                ))
            placeholder.inlinePresentationIntent = .emphasized
            return placeholder
        }
        if let link, !tappableSchemes.contains(link.scheme?.lowercased() ?? "") {
            text.link = nil
        }
        return text
    }

    private struct Builder {
        private var blocks: [MarkdownBlock] = []
        private var currentIntent: PresentationIntent?
        private var currentText = AttributedString()
        private var table: TableBuilder?
        private var lastListItemIdentity: Int?

        mutating func append(_ text: AttributedString, intent: PresentationIntent?) {
            if intent != currentIntent {
                flushCurrent()
                currentIntent = intent
            }
            currentText.append(text)
        }

        mutating func finish() -> [MarkdownBlock] {
            flushCurrent()
            flushTable()
            return blocks
        }

        private mutating func flushCurrent() {
            defer {
                currentText = AttributedString()
                currentIntent = nil
            }
            let components = currentIntent?.components ?? []
            if let tableComponent = components.first(where: { $0.kind.isTable }) {
                appendTableCell(components: components, table: tableComponent)
                return
            }
            flushTable()
            guard currentIntent != nil || !currentText.characters.isEmpty else { return }

            let quoteDepth = components.filter { $0.kind == .blockQuote }.count
            let listDepth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
            let plain = String(currentText.characters)

            for component in components {
                switch component.kind {
                case .codeBlock(let languageHint):
                    let code = plain.hasSuffix("\n") ? String(plain.dropLast()) : plain
                    emit(.code(language: languageHint.flatMap { $0.isEmpty ? nil : $0 }, text: code), listDepth, quoteDepth)
                    return
                case .header(let level):
                    emit(.heading(level: level, text: currentText), listDepth, quoteDepth)
                    return
                case .thematicBreak:
                    emit(.thematicBreak, listDepth, quoteDepth)
                    return
                default:
                    continue
                }
            }

            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let itemIndex = components.firstIndex(where: { $0.kind.listOrdinal != nil }) {
                let item = components[itemIndex]
                let isOrdered = components[(itemIndex + 1)...].first {
                    $0.kind == .orderedList || $0.kind == .unorderedList
                }?.kind == .orderedList
                let marker: String?
                if item.identity == lastListItemIdentity {
                    marker = nil
                } else {
                    marker = isOrdered ? "\(item.kind.listOrdinal ?? 1)." : "\u{2022}"
                }
                lastListItemIdentity = item.identity
                emit(.listItem(marker: marker, text: currentText), listDepth, quoteDepth)
            } else {
                emit(.paragraph(currentText), listDepth, quoteDepth)
            }
        }

        private mutating func appendTableCell(
            components: [PresentationIntent.IntentType],
            table tableComponent: PresentationIntent.IntentType
        ) {
            if let table, table.identity != tableComponent.identity { flushTable() }
            if table == nil {
                table = TableBuilder(identity: tableComponent.identity, columns: tableComponent.kind.tableColumns)
            }
            var row: Int?
            var column = 0
            for component in components {
                switch component.kind {
                case .tableHeaderRow: row = -1
                case .tableRow(let rowIndex): row = rowIndex
                case .tableCell(let columnIndex): column = columnIndex
                default: break
                }
            }
            table?.append(currentText, row: row ?? -1, column: column)
        }

        private mutating func flushTable() {
            guard let finished = table?.build() else { return }
            table = nil
            emit(.table(finished), 0, 0)
        }

        private mutating func emit(_ kind: MarkdownBlock.Kind, _ listDepth: Int, _ quoteDepth: Int) {
            if case .listItem = kind {} else { lastListItemIdentity = nil }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, listDepth: listDepth, quoteDepth: quoteDepth))
        }
    }

    private struct TableBuilder {
        let identity: Int
        let alignments: [MarkdownTable.Alignment]
        private var cells: [Int: [Int: AttributedString]] = [:]

        init(identity: Int, columns: [PresentationIntent.TableColumn]) {
            self.identity = identity
            self.alignments = columns.map {
                switch $0.alignment {
                case .center: return .center
                case .right: return .trailing
                default: return .leading
                }
            }
        }

        mutating func append(_ text: AttributedString, row: Int, column: Int) {
            cells[row, default: [:]][column, default: AttributedString()].append(text)
        }

        func build() -> MarkdownTable {
            let columnCount = max(alignments.count, cells.values.compactMap { $0.keys.max() }.max().map { $0 + 1 } ?? 0)
            func row(_ index: Int) -> [AttributedString] {
                (0..<columnCount).map { cells[index]?[$0] ?? AttributedString() }
            }
            return MarkdownTable(
                alignments: alignments,
                header: cells[-1] == nil ? [] : row(-1),
                rows: cells.keys.filter { $0 >= 0 }.sorted().map(row)
            )
        }
    }
}

private extension PresentationIntent.Kind {
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }

    var tableColumns: [PresentationIntent.TableColumn] {
        if case .table(let columns) = self { return columns }
        return []
    }

    var listOrdinal: Int? {
        if case .listItem(let ordinal) = self { return ordinal }
        return nil
    }
}
