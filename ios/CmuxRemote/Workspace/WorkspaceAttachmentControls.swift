import PhotosUI
import SwiftUI

/// Composes photo and file attachment controls without owning upload behavior.
struct WorkspaceAttachmentControls: View {
    @Bindable var coordinator: AttachmentCoordinator
    let hostGeneration: Int
    let isEnabled: Bool
    let controlSize: CGFloat
    let identity: String
    let usesPadKeyboardStyle: Bool
    let onStart: () -> Void
    let onPathsChanged: ([String]) -> Void
    let onImportFailure: (String) -> Void
    let onPhotoFailure: (Error) -> Void
    let onPhotoCompleted: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        Group {
            if usesPadKeyboardStyle {
                actionButtons
                    .padding(8)
                    .background(CmuxTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
                    .shadow(color: CmuxTheme.hardShadow, radius: 12, x: 0, y: 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("PadKeyboardAttachmentControls")
            } else {
                actionButtons
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await attachPhoto(item) }
        }
    }

    private func attachPhoto(_ item: PhotosPickerItem) async {
        guard !coordinator.isBusy else {
            selectedPhotoItem = nil
            return
        }
        defer { selectedPhotoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            onStart()
            try await coordinator.attachPhotoData(data, hostGeneration: hostGeneration)
            onPathsChanged(coordinator.store.quotedPaths)
            onPhotoCompleted()
        } catch {
            onPhotoFailure(error)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            PhotoAttachButton(
                isBusy: coordinator.isBusy,
                width: controlSize,
                height: controlSize,
                selection: $selectedPhotoItem
            )
            AttachmentControlSlot(
                coordinator: coordinator,
                hostGeneration: hostGeneration,
                isEnabled: isEnabled && !coordinator.isBusy,
                width: controlSize,
                height: controlSize,
                onStart: onStart,
                onFailure: onImportFailure
            )
        }
        .id(identity)
    }
}
