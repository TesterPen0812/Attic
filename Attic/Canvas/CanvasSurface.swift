import SwiftUI

struct CanvasSurface: View {
    @ObservedObject var session: CanvasSession

    var body: some View {
        platformSurface
            // Rebuild the native bridge only for an explicit lifecycle
            // cancellation. Dismantling discards unfinished input without
            // changing completed strokes, images, or viewport state.
            .id(session.interactionCancellationEpoch)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Canvas drawing board")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(
                "Draw with the selected tool. Click an image to select it. Use the trackpad or two fingers to move and zoom."
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
        let strokeSummary = session.strokes.count == 1
            ? "1 stroke"
            : "\(session.strokes.count) strokes"
        let imageSummary = session.images.count == 1
            ? "1 image"
            : "\(session.images.count) images"
        let selectedSummary = session.selectedImageID == nil
            ? "no image selected"
            : "image selected"
        return "\(strokeSummary), \(imageSummary), \(selectedSummary), \(session.tool.title) selected"
    }
}
