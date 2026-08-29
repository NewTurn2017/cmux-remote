import SwiftUI

struct AttachmentBatchView: View {
    @Bindable var store: AttachmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "attachment.batch.title",
                        defaultValue: "Attachments"
                    ))
                    .cmuxDisplay(11)
                    .foregroundStyle(CmuxTheme.ink)

                    HStack(spacing: 8) {
                        countLabel(
                            count: succeededCount,
                            label: String(
                                localized: "attachment.batch.succeeded",
                                defaultValue: "uploaded"
                            ),
                            color: CmuxTheme.accentGreen,
                            identifier: "AttachmentBatchSucceededCount"
                        )
                        countLabel(
                            count: failedCount,
                            label: String(
                                localized: "attachment.batch.failed",
                                defaultValue: "failed"
                            ),
                            color: failedCount == 0 ? CmuxTheme.muted : CmuxTheme.accentRed,
                            identifier: "AttachmentBatchFailedCount"
                        )
                        if cancelledCount > 0 {
                            compactCount(
                                count: cancelledCount,
                                label: String(
                                    localized: "attachment.batch.cancelled",
                                    defaultValue: "cancelled"
                                ),
                                color: CmuxTheme.accentYellow
                            )
                        }
                        if unattemptedCount > 0 {
                            compactCount(
                                count: unattemptedCount,
                                label: String(
                                    localized: "attachment.batch.unattempted",
                                    defaultValue: "not attempted"
                                ),
                                color: CmuxTheme.muted
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

                Spacer(minLength: 4)

                if store.isUploading {
                    actionButton(
                        title: String(
                            localized: "attachment.batch.cancel",
                            defaultValue: "Cancel upload"
                        ),
                        systemName: "xmark",
                        identifier: "AttachmentBatchCancelButton",
                        tint: CmuxTheme.accentRed
                    ) {
                        Task { await store.cancel() }
                    }
                } else {
                    HStack(spacing: 4) {
                        if store.canRetryFailed {
                            actionButton(
                                title: String(
                                    localized: "attachment.batch.retry",
                                    defaultValue: "Retry failed uploads"
                                ),
                                systemName: "arrow.clockwise",
                                identifier: "AttachmentBatchRetryButton",
                                tint: CmuxTheme.accentBlue
                            ) {
                                Task { await store.retryFailed() }
                            }
                        }
                        actionButton(
                            title: String(
                                localized: "attachment.batch.dismiss",
                                defaultValue: "Dismiss attachment results"
                            ),
                            systemName: "xmark",
                            identifier: "AttachmentBatchDismissButton",
                            tint: CmuxTheme.muted
                        ) {
                            store.dismissResults()
                        }
                    }
                }
            }

            VStack(spacing: 4) {
                ProgressView(value: Double(store.totalAcknowledgedBytes), total: Double(max(displayedTotalBytes, 1)))
                    .tint(aggregateTint)
                    .accessibilityHidden(true)
                Text(aggregateDescription)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.inkDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("AttachmentBatchAggregateProgress")
                    .accessibilityLabel(String(
                        localized: "attachment.batch.aggregate_progress",
                        defaultValue: "Attachment upload progress"
                    ))
                    .accessibilityValue(Text(verbatim: "\(store.totalAcknowledgedBytes)/\(displayedTotalBytes)"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.items.sorted { $0.ordinal < $1.ordinal }) { item in
                        AttachmentBatchItemView(
                            item: item,
                            acknowledgedBytes: store.acknowledgedBytes(for: item.ordinal)
                        )
                    }
                }
            }
            .accessibilityLabel(String(
                localized: "attachment.batch.file_list",
                defaultValue: "Selected files"
            ))
        }
        .padding(12)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 20, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AttachmentBatchPanel")
    }

    private var succeededCount: Int {
        store.items.filter(\.isSucceeded).count
    }

    private var failedCount: Int {
        store.items.filter { $0.failure != nil }.count
    }

    private var cancelledCount: Int {
        store.items.filter { $0.state == .cancelled }.count
    }

    private var unattemptedCount: Int {
        store.items.filter { $0.state == .unattempted }.count
    }

    private var displayedTotalBytes: Int64 {
        store.items.compactMap(\.bytes).reduce(0, +)
    }

    private var aggregateTint: Color {
        if failedCount > 0 { return CmuxTheme.accentYellow }
        if !store.isUploading, succeededCount > 0 { return CmuxTheme.accentGreen }
        return CmuxTheme.accentBlue
    }

    private var aggregateDescription: String {
        let sent = ByteCountFormatter.string(fromByteCount: store.totalAcknowledgedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: displayedTotalBytes, countStyle: .file)
        return String.localizedStringWithFormat(
            String(
                localized: "attachment.batch.byte_progress",
                defaultValue: "%@ of %@"
            ),
            sent,
            total
        )
    }

    private func countLabel(
        count: Int,
        label: String,
        color: Color,
        identifier: String
    ) -> some View {
        compactCount(count: count, label: label, color: color)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(String.localizedStringWithFormat(
                String(
                    localized: "attachment.batch.count_status",
                    defaultValue: "%lld %@"
                ),
                count,
                label
            ))
            .accessibilityValue(Text(verbatim: "\(count)"))
    }

    private func compactCount(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(CmuxTheme.inkDim)
        }
        .cmuxMono(11)
        .lineLimit(1)
    }

    private func actionButton(
        title: String,
        systemName: String,
        identifier: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tint.opacity(0.75), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

private struct AttachmentBatchItemView: View {
    let item: AttachmentItem
    let acknowledgedBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(item.filename)
                    .cmuxMono(11, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("AttachmentFilename-\(item.filename)-\(item.ordinal)")
            }

            Text(statusLabel)
                .cmuxMono(11)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Group {
                if let bytes = item.bytes, bytes > 0 {
                    ProgressView(value: Double(acknowledgedBytes), total: Double(bytes))
                        .tint(statusColor)
                } else {
                    Rectangle()
                        .fill(CmuxTheme.divider)
                        .frame(height: 2)
                }
            }
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("AttachmentItemProgress-\(item.ordinal)")
                    .accessibilityLabel(Text(verbatim: item.filename))
                    .accessibilityValue(Text(verbatim: "\(acknowledgedBytes)/\(item.bytes ?? 0)"))
            }
        }
        .padding(8)
        .frame(width: 156, alignment: .leading)
        .frame(minHeight: 68, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(statusColor.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AttachmentItemState-\(item.ordinal)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(machineState)
    }

    private var machineState: String {
        switch item.state {
        case .staging: return "staging"
        case .ready: return "ready"
        case .uploading: return "uploading"
        case .succeeded: return "succeeded"
        case .failed(let failure): return "failed:\(failure.code)"
        case .cancelled: return "cancelled"
        case .unattempted: return "unattempted"
        }
    }

    private var statusLabel: String {
        switch item.state {
        case .staging:
            return String(localized: "attachment.item.staging", defaultValue: "Preparing")
        case .ready:
            return String(localized: "attachment.item.ready", defaultValue: "Ready")
        case .uploading(let bytes):
            let sent = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String.localizedStringWithFormat(
                String(localized: "attachment.item.uploading", defaultValue: "Uploading %@"),
                sent
            )
        case .succeeded:
            return String(localized: "attachment.item.succeeded", defaultValue: "Uploaded")
        case .failed(let failure):
            return failureLabel(failure.code)
        case .cancelled:
            return String(localized: "attachment.item.cancelled", defaultValue: "Cancelled")
        case .unattempted:
            return String(localized: "attachment.item.unattempted", defaultValue: "Not attempted")
        }
    }

    private var statusIcon: String {
        switch item.state {
        case .staging: return "clock"
        case .ready: return "tray.and.arrow.up"
        case .uploading: return "arrow.up"
        case .succeeded: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .unattempted: return "minus"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .succeeded: return CmuxTheme.accentGreen
        case .failed: return CmuxTheme.accentRed
        case .cancelled: return CmuxTheme.accentYellow
        case .uploading: return CmuxTheme.accentBlue
        default: return CmuxTheme.inkDim
        }
    }

    private var accessibilityLabel: String {
        String.localizedStringWithFormat(
            String(
                localized: "attachment.item.accessibility_status",
                defaultValue: "%@, %@"
            ),
            item.filename,
            statusLabel
        )
    }

    private func failureLabel(_ code: String) -> String {
        switch code {
        case "file_count_limit":
            return String(localized: "attachment.failure.file_count", defaultValue: "Too many files")
        case "file_too_large":
            return String(localized: "attachment.failure.file_too_large", defaultValue: "File too large")
        case "batch_size_limit":
            return String(localized: "attachment.failure.batch_size", defaultValue: "Batch too large")
        case "source_unavailable":
            return String(localized: "attachment.failure.source_unavailable", defaultValue: "Source unavailable")
        case "update_required":
            return String(localized: "attachment.failure.update_required", defaultValue: "Relay update required")
        default:
            return String(localized: "attachment.failure.upload", defaultValue: "Upload failed")
        }
    }
}
