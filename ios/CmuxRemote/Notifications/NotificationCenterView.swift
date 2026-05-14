import SwiftUI
import SharedKit

struct NotificationCenterView: View {
    @Bindable var store: NotificationStore
    var onTap: (NotificationRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("inbox")
                        .cmuxDisplay(28)
                        .foregroundStyle(CmuxTheme.ink)
                    Text("[\(store.items.count)]")
                        .cmuxDisplay(14)
                        .foregroundStyle(CmuxTheme.muted)
                    Spacer()
                }

                CmuxRule(title: "events")

                if store.items.isEmpty {
                    VStack(spacing: 10) {
                        Text("[ no events ]")
                            .cmuxDisplay(13)
                            .foregroundStyle(CmuxTheme.muted)
                        Text("cmux relay events will appear here")
                            .cmuxMono(11)
                            .foregroundStyle(CmuxTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(CmuxTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    )
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { notification in
                            Button { onTap(notification) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text("›")
                                            .cmuxDisplay(11)
                                            .foregroundStyle(CmuxTheme.accentGreen)
                                        Text(notification.title)
                                            .cmuxMono(14, weight: .medium)
                                            .foregroundStyle(CmuxTheme.ink)
                                    }
                                    if let subtitle = notification.subtitle {
                                        Text(subtitle)
                                            .cmuxDisplay(10)
                                            .foregroundStyle(CmuxTheme.accentBlue)
                                    }
                                    Text(notification.body)
                                        .cmuxMono(12)
                                        .foregroundStyle(CmuxTheme.inkDim)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(CmuxTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(CmuxTheme.canvas)
    }
}
