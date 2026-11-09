import SharedKit
import SwiftUI

struct ClaudeTranscriptEntryView: View {
    let row: ClaudeTranscriptRow
    let store: ClaudeTranscriptStore

    private var alignsTrailing: Bool { row.role == .user && !row.isToolResultOnly }

    var body: some View {
        VStack(alignment: alignsTrailing ? .trailing : .leading, spacing: 6) {
            roleLine
            ForEach(Array(row.blocks.enumerated()), id: \.offset) { index, display in
                block(display, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignsTrailing ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TranscriptEntry-\(row.id)")
    }

    private var roleLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: roleLabel)
                .cmuxDisplay(10)
                .foregroundStyle(roleColor)
            if let timestamp = row.timestamp {
                Text(verbatim: ClaudeTranscriptFormatting.time(milliseconds: timestamp))
                    .cmuxMono(10)
                    .foregroundStyle(CmuxTheme.muted)
            }
        }
    }

    private var roleLabel: String {
        if row.isToolResultOnly { return "TOOL" }
        return row.role == .user ? "YOU" : "CLAUDE"
    }

    private var roleColor: Color {
        if row.isToolResultOnly { return CmuxTheme.muted }
        return row.role == .user ? CmuxTheme.accentCyan : CmuxTheme.accentMagenta
    }

    @ViewBuilder
    private func block(_ display: ClaudeTranscriptDisplayBlock, index: Int) -> some View {
        switch display.block.kind {
        case .text:
            if let markdown = display.markdown {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(markdown) { MarkdownBlockView(block: $0, scale: 0.9) }
                    truncatedTag(display.block, index: index)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                userText(display.block, index: index)
            }
        case .toolUse, .toolResult:
            toolRow(display.block, index: index)
        }
    }

    private func userText(_ block: ClaudeTranscriptBlock, index: Int) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: block.text ?? "")
                    .cmuxMono(13)
                    .foregroundStyle(CmuxTheme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                truncatedTag(block, index: index)
            }
            .padding(10)
            .background(CmuxTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func toolRow(_ block: ClaudeTranscriptBlock, index: Int) -> some View {
        let expanded = store.isExpanded(rowID: row.id, index: index)
        let isError = block.isError == true
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                store.toggleExpanded(rowID: row.id, index: index)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CmuxTheme.muted)
                        .accessibilityHidden(true)
                    Text(verbatim: toolName(block))
                        .cmuxMono(12, weight: .medium)
                        .foregroundStyle(isError ? CmuxTheme.accentRed : (block.kind == .toolUse ? CmuxTheme.accentYellow : CmuxTheme.inkDim))
                        .lineLimit(1)
                        .fixedSize()
                    if let firstLine = firstLine(block.summary) {
                        Text(verbatim: firstLine)
                            .cmuxMono(12)
                            .foregroundStyle(CmuxTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TranscriptTool-\(row.id)-\(index)")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: block.summary?.isEmpty == false ? block.summary! : String(localized: "transcript.tool.no_output", defaultValue: "(no output)"))
                        .cmuxMono(11)
                        .foregroundStyle(isError ? CmuxTheme.accentRed : CmuxTheme.inkDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("TranscriptToolDetail-\(row.id)-\(index)")
                    truncatedTag(block, index: index)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isError ? CmuxTheme.accentRed.opacity(0.5) : CmuxTheme.divider, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func truncatedTag(_ block: ClaudeTranscriptBlock, index: Int) -> some View {
        if block.truncated == true {
            Text(String(localized: "transcript.truncated", defaultValue: "[truncated · see the full text on the Mac]"))
                .cmuxMono(10)
                .foregroundStyle(CmuxTheme.accentOrange)
                .accessibilityIdentifier("TranscriptTruncated-\(row.id)-\(index)")
        }
    }

    private func toolName(_ block: ClaudeTranscriptBlock) -> String {
        if let name = block.toolName, !name.isEmpty { return name }
        return block.isError == true ? "error" : "result"
    }

    private func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
