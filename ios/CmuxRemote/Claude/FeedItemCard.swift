import SharedKit
import SwiftUI

struct FeedItemCard: View {
    let item: FeedPendingItem
    @Bindable var store: FeedStore
    let isConnected: Bool
    let now: Date

    @State private var draft: FeedQuestionDraft
    @State private var confirming: FeedReplyButton?
    @State private var detailExpanded = false
    @State private var planBlocks: [MarkdownBlock] = []

    init(item: FeedPendingItem, store: FeedStore, isConnected: Bool, now: Date) {
        self.item = item
        self.store = store
        self.isConnected = isConnected
        self.now = now
        _draft = State(initialValue: FeedQuestionDraft(questions: item.questions ?? []))
    }

    private var isBusy: Bool { store.isBusy(item.requestId) }
    private var remainingSeconds: Int? { FeedPendingWindow.remainingSeconds(createdAt: item.createdAt, now: now) }
    private var isExpired: Bool { remainingSeconds == 0 }
    private var canReply: Bool { isConnected && !isBusy && !isExpired }
    private var idPrefix: String { "Feed-\(item.requestId)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch item.kind {
            case .question: questionBody
            case .permission: permissionBody
            case .plan: planBody
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FeedCard-\(item.requestId)")
        .confirmationDialog(
            confirming.map(confirmationTitle) ?? "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let button = confirming {
                Button(button.title) {
                    confirming = nil
                    send(FeedReplyPolicy.request(for: button, item: item))
                }
                .accessibilityIdentifier("FeedConfirmReply")
                Button(String(localized: "feed.confirm.cancel", defaultValue: "Cancel"), role: .cancel) {
                    confirming = nil
                }
            }
        }
    }

    // MARK: header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: kindLabel)
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.canvas)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(verbatim: originLine)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let remainingSeconds, remainingSeconds > 0 {
                    Text(verbatim: FeedPendingWindow.remainingText(seconds: remainingSeconds))
                        .cmuxMono(11, weight: FeedPendingWindow.isUrgent(remainingSeconds: remainingSeconds) ? .medium : .regular)
                        .foregroundStyle(FeedPendingWindow.isUrgent(remainingSeconds: remainingSeconds) ? CmuxTheme.accentOrange : CmuxTheme.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("\(idPrefix)-Remaining")
                        .accessibilityValue("\(remainingSeconds)")
                }
            }
            if let title = item.title, !title.isEmpty {
                Text(verbatim: title)
                    .cmuxMono(14, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .question: return "QUESTION"
        case .permission: return "PERMISSION"
        case .plan: return "PLAN"
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .question: return CmuxTheme.accentCyan
        case .permission: return CmuxTheme.accentYellow
        case .plan: return CmuxTheme.accentMagenta
        }
    }

    private var originLine: String {
        guard let cwd = item.cwd, !cwd.isEmpty else { return item.source }
        let folder = (cwd as NSString).lastPathComponent
        return "\(item.source) · \(folder.isEmpty ? cwd : folder)"
    }

    @ViewBuilder
    private var footer: some View {
        if isExpired, !isBusy {
            Text(String(localized: "feed.item.expired", defaultValue: "Time's up · Answer in the Mac terminal"))
                .cmuxMono(11, weight: .medium)
                .foregroundStyle(CmuxTheme.accentOrange)
                .accessibilityIdentifier("\(idPrefix)-Expired")
        } else if store.sendingRequestIDs.contains(item.requestId) {
            footerStatus(String(localized: "feed.reply.sending", defaultValue: "Sending…"))
                .accessibilityIdentifier("\(idPrefix)-Sending")
        } else if store.verifying[item.requestId] != nil {
            footerStatus(String(localized: "feed.reply.verifying", defaultValue: "Checking…"))
                .accessibilityIdentifier("\(idPrefix)-Verifying")
        } else if let failure = store.replyFailures[item.requestId] {
            Text(failure.message)
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.accentRed)
                .accessibilityIdentifier("\(idPrefix)-ReplyError")
        }
    }

    private func footerStatus(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .tint(CmuxTheme.muted)
            Text(text)
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.muted)
        }
    }

    // MARK: question

    @ViewBuilder
    private var questionBody: some View {
        let questions = item.questions ?? []
        ForEach(Array(questions.enumerated()), id: \.offset) { questionIndex, question in
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: question.prompt)
                    .cmuxMono(13)
                    .foregroundStyle(CmuxTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiSelect {
                    Text(String(localized: "feed.question.multi_select", defaultValue: "Choose one or more"))
                        .cmuxMono(10)
                        .foregroundStyle(CmuxTheme.muted)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                    optionRow(question: question, questionIndex: questionIndex, option: option, optionIndex: optionIndex)
                }
            }
        }
        if draft.requiresMac {
            Text(String(localized: "feed.question.answer_on_mac", defaultValue: "This question has to be answered on the Mac."))
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.accentYellow)
                .accessibilityIdentifier("\(idPrefix)-AnswerOnMac")
        } else {
            replyButton(
                title: String(localized: "feed.question.send", defaultValue: "Send"),
                color: CmuxTheme.accentGreen,
                filled: true,
                enabled: canReply && isReady,
                identifier: "\(idPrefix)-Send"
            ) {
                if case .ready(let selections) = draft.outcome {
                    send(FeedReplyRequest(requestId: item.requestId, kind: .question, selections: selections))
                }
            }
        }
    }

    private var isReady: Bool {
        if case .ready = draft.outcome { return true }
        return false
    }

    private func optionRow(question: FeedQuestion, questionIndex: Int, option: FeedOption, optionIndex: Int) -> some View {
        let selected = draft.isSelected(question: questionIndex, option: optionIndex)
        let glyph: String
        if question.multiSelect {
            glyph = selected ? "checkmark.square.fill" : "square"
        } else {
            glyph = selected ? "largecircle.fill.circle" : "circle"
        }
        return Button {
            draft.toggle(question: questionIndex, option: optionIndex)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                Text(verbatim: option.label)
                    .cmuxMono(13)
                    .foregroundStyle(CmuxTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .background(selected ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReply || draft.requiresMac)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(idPrefix)-Option-\(questionIndex)-\(optionIndex)")
    }

    // MARK: permission

    @ViewBuilder
    private var permissionBody: some View {
        if let toolName = item.toolName {
            Text(verbatim: toolName)
                .cmuxMono(13, weight: .medium)
                .foregroundStyle(CmuxTheme.accentYellow)
        }
        if let input = item.toolInput, !input.isEmpty {
            expandablePreview(isLong: input.count > 280 || input.split(separator: "\n").count > 6) {
                Text(verbatim: input)
                    .cmuxMono(12)
                    .foregroundStyle(CmuxTheme.inkDim)
                    .lineLimit(detailExpanded ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if item.toolInputTruncated == true {
                truncatedLabel
            }
        }
        modeButtons
    }

    // MARK: plan

    @ViewBuilder
    private var planBody: some View {
        if let planText = item.planText, !planText.isEmpty {
            expandablePreview(isLong: planBlocks.count > 6) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detailExpanded ? planBlocks : Array(planBlocks.prefix(6))) { block in
                        MarkdownBlockView(block: block, scale: 0.9)
                    }
                }
            }
            .task(id: item.requestId) {
                planBlocks = MarkdownBlockParser.parse(planText)
            }
            if item.planTextTruncated == true {
                truncatedLabel
            }
        }
        modeButtons
    }

    // MARK: shared pieces

    private var truncatedLabel: some View {
        Text(String(localized: "feed.item.truncated", defaultValue: "[truncated]"))
            .cmuxMono(10)
            .foregroundStyle(CmuxTheme.muted)
    }

    private func expandablePreview<Content: View>(isLong: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if isLong {
                Button(detailExpanded
                    ? String(localized: "feed.item.show_less", defaultValue: "Show less")
                    : String(localized: "feed.item.show_more", defaultValue: "Show more")
                ) {
                    detailExpanded.toggle()
                }
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.accentBlue)
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix)-ToggleDetail")
            }
        }
    }

    private var modeButtons: some View {
        HStack(spacing: 8) {
            ForEach(FeedReplyPolicy.buttons(for: item), id: \.self) { button in
                replyButton(
                    title: button.title,
                    color: color(for: button),
                    filled: button == .allowOnce || button == .approve,
                    enabled: canReply,
                    identifier: "\(idPrefix)-\(button.rawValue)"
                ) {
                    if button.requiresConfirmation(for: item) {
                        confirming = button
                    } else {
                        send(FeedReplyPolicy.request(for: button, item: item))
                    }
                }
            }
        }
    }

    private func color(for button: FeedReplyButton) -> Color {
        switch button {
        case .allowOnce, .approve: return CmuxTheme.accentGreen
        case .allowAlways, .autoApprove: return CmuxTheme.accentBlue
        case .deny, .reject: return CmuxTheme.accentRed
        }
    }

    private func replyButton(
        title: String,
        color: Color,
        filled: Bool,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .cmuxDisplay(11)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(filled ? CmuxTheme.canvas : color)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(filled ? color : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color, lineWidth: filled ? 0 : 1)
                )
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func confirmationTitle(_ button: FeedReplyButton) -> String {
        switch button {
        case .autoApprove:
            return String(localized: "feed.confirm.auto_approve", defaultValue: "Approve the plan and let the agent accept edits without asking?")
        default:
            return String(localized: "feed.confirm.allow_always", defaultValue: "Always allow this tool without asking again?")
        }
    }

    private func send(_ request: FeedReplyRequest) {
        let store = store
        Task { await store.reply(request) }
    }
}

struct FeedDepartedCard: View {
    let departed: FeedDepartedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = departed.item.title, !title.isEmpty {
                Text(verbatim: title)
                    .cmuxMono(14, weight: .medium)
                    .foregroundStyle(CmuxTheme.inkDim)
                    .lineLimit(2)
            }
            Text(departed.message)
                .cmuxMono(12)
                .foregroundStyle(departed.reason == .expired ? CmuxTheme.accentOrange : CmuxTheme.muted)
                .accessibilityIdentifier("FeedDeparted-\(departed.item.requestId)-Reason")
                .accessibilityValue(departed.reason.rawValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
        .opacity(0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FeedDeparted-\(departed.item.requestId)")
    }
}
