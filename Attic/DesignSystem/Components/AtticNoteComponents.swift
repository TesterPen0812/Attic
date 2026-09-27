import SwiftUI

/// A date inside note text (Phase 2): the tag chip's recessed pill (18 tall,
/// radius 7.5, `tagFill`) with a small calendar glyph and the day in body
/// ink. The note editor renders it into an image for its text attachment,
/// so it draws exactly what the gallery shows.
struct AtticDateChip: View {
    let label: String

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let height = AtticControlSize.tagHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticDateChipMetrics.glyphGap) {
            AtticIcon(systemName: "calendar", size: AtticDateChipMetrics.glyphSize, weight: .medium, ink: .helper)
            AtticText(verbatim: label, style: .chipLabel, ink: .body)
        }
        .padding(.horizontal, AtticTagMetrics.horizontalPadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tokens.tagFill.color))
        .accessibilityHidden(true)
    }
}

enum AtticDateChipMetrics {
    static let glyphSize: CGFloat = 10
    static let glyphGap: CGFloat = 4
}
