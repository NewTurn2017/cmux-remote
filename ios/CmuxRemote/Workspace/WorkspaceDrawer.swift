import SwiftUI

struct WorkspaceDrawer: View {
    @Bindable var store: WorkspaceStore
    var onPick: (String, String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(store.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 8) {
                            CmuxRule(title: workspace.name)
                            ForEach(store.surfaces(for: workspace.id)) { surface in
                                Button { onPick(workspace.id, surface.id) } label: {
                                    HStack(spacing: 10) {
                                        Text("▶")
                                            .cmuxDisplay(11)
                                            .foregroundStyle(CmuxTheme.accentGreen)
                                        Text(surface.title)
                                            .cmuxMono(14, weight: .medium)
                                            .foregroundStyle(CmuxTheme.ink)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(CmuxTheme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("surfaces")
            .navigationBarTitleDisplayMode(.inline)
            .background(CmuxTheme.canvas)
        }
    }
}
