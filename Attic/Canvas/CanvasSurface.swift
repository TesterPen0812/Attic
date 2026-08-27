import SwiftUI

struct CanvasSurface: View {
    @ObservedObject var session: CanvasSession

    var body: some View {
        platformSurface
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Canvas drawing board")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(
                "Draw with the selected tool. Use the trackpad or two fingers to move and zoom."
            )
            .accessibilityIdentifier("canvas-surface")
    }

    @ViewBuilder
    private var platformSurface: some View {
#if os(macOS)
        CanvasNSViewRepresentable(session: session)
#elseif os(iOS)
        CanvasUIViewRepresentable(session: session)
#endif
    }

    private var accessibilityValue: String {
        let count = session.strokes.count
        let strokeSummary = count == 1 ? "1 stroke" : "\(count) strokes"
        return "\(strokeSummary), \(session.tool.title) selected"
    }
}
