import SwiftUI

/// Stable composition seam for attachment picking and deterministic fixture state.
struct AttachmentControlSlot: View {
    @Bindable var coordinator: AttachmentCoordinator
    let hostGeneration: Int
    let isEnabled: Bool
    let width: CGFloat
    let height: CGFloat
    let onStart: () -> Void
    let onFailure: (String) -> Void

    var body: some View {
        ZStack {
            AttachmentPicker(
                isEnabled: isEnabled && !coordinator.store.isUploading,
                width: width,
                height: height,
                onPick: { selections in
                    onStart()
                    Task {
                        await coordinator.beginUpload(
                            selections,
                            hostGeneration: hostGeneration
                        )
                    }
                },
                onFailure: onFailure
            )

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("AttachmentFeatureControlSlot")
                .accessibilityValue(isEnabled ? "enabled" : "disabled")
                .allowsHitTesting(false)
        }
        .onChange(of: coordinator.store.isUploading) { wasUploading, isUploading in
            guard wasUploading, !isUploading else { return }
            #if DEBUG
            AttachmentFixtureProvider.clean()
            #endif
        }
    }
}
