import SwiftUI

/// The docking corner, chosen on a little display: four corner targets on a
/// screen shape, the chosen one filled with the accent, its name underneath.
struct CornerPicker: View {
    @Binding var selection: ScreenCorner

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static let displaySize = CGSize(width: 116, height: 74)
    static let targetSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(colorSchemeContrast == .increased ? 0.10 : 0.06))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(SettingsDesign.tileBoundaryOpacity(for: colorSchemeContrast)),
                        lineWidth: 1
                    )
                // The menu bar, so the top of the display reads as the top.
                VStack {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                        .padding(.top, 7)
                    Spacer(minLength: 0)
                }
                .accessibilityHidden(true)

                cornerButton(.topLeft)
                cornerButton(.topRight)
                cornerButton(.bottomLeft)
                cornerButton(.bottomRight)
            }
            .frame(width: Self.displaySize.width, height: Self.displaySize.height)

            Text(selection.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hiding corner")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("setting-hiding-corner")
    }

    private func cornerButton(_ corner: ScreenCorner) -> some View {
        let isSelected = selection == corner
        return Button {
            selection = corner
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.accentColor
                                : Color.primary.opacity(colorSchemeContrast == .increased ? 0.5 : 0.22),
                            lineWidth: 1
                        )
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Self.targetSize, height: Self.targetSize)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: corner))
        .padding(8)
        .help("Reveal Attic from the \(corner.title.lowercased()) corner")
        .accessibilityLabel(corner.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
        .accessibilityIdentifier("setting-corner-\(corner.rawValue)")
    }

    private func alignment(for corner: ScreenCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}
