import SwiftUI

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                Rectangle()
                    .fill(CmuxTheme.accentBlue)
                    .frame(width: 3)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
            content
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 16 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(headingFont(level))
                    .foregroundStyle(CmuxTheme.ink)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if level <= 2 {
                    Rectangle().fill(CmuxTheme.divider).frame(height: 1).accessibilityHidden(true)
                }
            }
            .padding(.top, level <= 2 ? 6 * scale : 2 * scale)
        case .paragraph(let text):
            inlineText(text, color: block.quoteDepth > 0 ? CmuxTheme.inkDim : CmuxTheme.ink)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker ?? "")
                    .font(CmuxFont.body(13 * scale, weight: .medium))
                    .foregroundStyle(CmuxTheme.accentCyan)
                    .frame(minWidth: 18 * scale, alignment: .trailing)
                    .accessibilityHidden(marker == nil)
                inlineText(text, color: block.quoteDepth > 0 ? CmuxTheme.inkDim : CmuxTheme.ink)
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(verbatim: language)
                        .cmuxDisplay(10)
                        .foregroundStyle(CmuxTheme.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(verbatim: text)
                        .font(CmuxFont.body(12 * scale))
                        .foregroundStyle(CmuxTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("DocumentCodeBlock")
        case .table(let table):
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    if !table.header.isEmpty {
                        GridRow {
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                tableCell(table, row: table.header, column: column, isHeader: true)
                            }
                        }
                    }
                    ForEach(table.rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                tableCell(table, row: table.rows[rowIndex], column: column, isHeader: false)
                            }
                        }
                    }
                }
                .overlay { Rectangle().stroke(CmuxTheme.divider, lineWidth: 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("DocumentTable")
        case .thematicBreak:
            Rectangle()
                .fill(CmuxTheme.divider)
                .frame(height: 1)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    private func inlineText(_ text: AttributedString, color: Color) -> some View {
        Text(text)
            .font(CmuxFont.body(13 * scale))
            .foregroundStyle(color)
            .tint(CmuxTheme.accentBlue)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCell(_ table: MarkdownTable, row: [AttributedString], column: Int, isHeader: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(column < row.count ? row[column] : AttributedString())
            .font(CmuxFont.body(12 * scale, weight: isHeader ? .medium : .regular))
            .foregroundStyle(CmuxTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 64, maxWidth: .infinity, alignment: frameAlignment(alignment))
            .background(isHeader ? CmuxTheme.surfaceRaised : CmuxTheme.terminal)
            .overlay { Rectangle().stroke(CmuxTheme.divider, lineWidth: 0.5) }
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return CmuxFont.display(20 * scale)
        case 2: return CmuxFont.display(17 * scale)
        case 3: return CmuxFont.display(15 * scale)
        default: return CmuxFont.body(13 * scale, weight: .bold)
        }
    }
}
