import SwiftUI
import SharedKit

/// Surface chips stay visible in every input state, including with the software keyboard up.
struct SurfaceChipBar: View {
    let surfaces: [Surface]
    let activeSurfaceId: String?
    let isBusy: Bool
    let error: String?
    let compact: Bool
    let onSelect: (Surface) -> Void
    let onClose: (Surface) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(surfaces) { surface in
                        SurfaceChip(
                            title: surface.title,
                            kind: SurfaceKind(surface),
                            isSelected: activeSurfaceId == surface.id,
                            canClose: surfaces.count > 1,
                            isBusy: isBusy,
                            onSelect: { onSelect(surface) },
                            onClose: { onClose(surface) }
                        )
                    }

                    NewSurfaceChip(isBusy: isBusy, action: onCreate)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SurfaceChipBar")

            if let error {
                HStack(spacing: 6) {
                    Text("!")
                        .cmuxDisplay(11)
                    Text(error)
                        .cmuxMono(11)
                        .lineLimit(compact ? 1 : 2)
                }
                .foregroundStyle(CmuxTheme.accentRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("SurfaceActionError")
            }
        }
    }
}

private struct SurfaceChip: View {
    let title: String
    let kind: SurfaceKind
    let isSelected: Bool
    let canClose: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                    Text(title)
                        .cmuxMono(11, weight: isSelected ? .medium : .regular)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                .padding(.leading, 10)
                .padding(.trailing, canClose ? 6 : 10)
                .frame(height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(kind.accessibilityName)
            .accessibilityIdentifier("SurfaceChip-\(kind.identifierSuffix)")

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(String(localized: "surfaces.chip.close", defaultValue: "Close surface \(title)"))
            }
        }
        .background(isSelected ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
        )
        .opacity(isBusy && !isSelected ? 0.72 : 1)
    }
}

private struct NewSurfaceChip: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .tint(CmuxTheme.accentGreen)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text("new")
                    .cmuxDisplay(10)
            }
            .foregroundStyle(CmuxTheme.accentGreen)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.accentGreen.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("NewSurfaceButton")
        .accessibilityLabel(String(localized: "surfaces.new.accessibility", defaultValue: "New surface"))
    }
}
