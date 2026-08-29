import PhotosUI
import SwiftUI

/// Presents the system photo picker for attachment selection.
struct PhotoAttachButton: View {
    let isBusy: Bool
    var width: CGFloat = 40
    var height: CGFloat = 36
    @Binding var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            Group {
                if isBusy {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .bold))
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(CmuxTheme.ink)
            .frame(width: max(44, width), height: max(44, height))
            .background(CmuxTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("CommandPhotoAttachButton")
        .accessibilityLabel(String(
            localized: "attachment.photo.button",
            defaultValue: "Attach photo from device"
        ))
    }
}
