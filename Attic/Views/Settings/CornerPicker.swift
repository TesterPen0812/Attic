import SwiftUI

struct CornerPicker: View {
    @Binding var selection: ScreenCorner

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                cornerButton(.topLeft)
                cornerButton(.topRight)
            }
            GridRow {
                cornerButton(.bottomLeft)
                cornerButton(.bottomRight)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hiding corner")
        .accessibilityIdentifier("setting-hiding-corner")
    }

    private func cornerButton(_ corner: ScreenCorner) -> some View {
        Button {
            selection = corner
        } label: {
            HStack(spacing: 8) {
                CornerGlyph(corner: corner, isSelected: selection == corner)

                Text(corner.title)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(selection == corner ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(selection == corner ? .accentColor : .secondary)
        .help("Use the \(corner.title.lowercased()) corner")
        .accessibilityLabel(corner.title)
        .accessibilityAddTraits(selection == corner ? .isSelected : [])
        .accessibilityIdentifier("setting-corner-\(corner.rawValue)")
    }
}

private struct CornerGlyph: View {
    let corner: ScreenCorner
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: alignment) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.secondary.opacity(0.8), lineWidth: 1)

            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 5, height: 5)
                .padding(2)
        }
        .frame(width: 25, height: 17)
        .accessibilityHidden(true)
    }

    private var alignment: Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}
