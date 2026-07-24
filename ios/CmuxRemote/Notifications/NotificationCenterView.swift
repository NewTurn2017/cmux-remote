import SwiftUI
import SharedKit

struct NotificationCenterView: View {
    @Bindable var store: NotificationStore
    var onTap: (NotificationRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.string("inbox"))
                        .cmuxDisplay(28)
                        .foregroundStyle(CmuxTheme.ink)
                    Text("[\(store.items.count)]")
                        .cmuxDisplay(14)
                        .foregroundStyle(CmuxTheme.muted)
                    Spacer()
                    if store.unreadCount > 0 {
                        Button(action: { store.markAllRead() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 12, weight: .bold))
                                Text("[ MARK ALL READ ]")
                                    .cmuxDisplay(10)
                            }
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .background(CmuxTheme.accentBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("MarkAllReadButton")
                    }
                }

                CmuxRule(title: L10n.string("events"))

                if store.items.isEmpty {
                    VStack(spacing: 10) {
                        Text(L10n.string("[ no events ]"))
                            .cmuxDisplay(13)
                            .foregroundStyle(CmuxTheme.muted)
                        Text(L10n.string("cmux relay events will appear here"))
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
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(CmuxTheme.canvas)
    }
}
