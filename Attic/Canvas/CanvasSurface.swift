import SwiftUI

struct CanvasSurface: View {
    @ObservedObject var session: CanvasSession
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled

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
                accessibilityHint
            )
            .accessibilityIdentifier("canvas-surface")
    }

    @ViewBuilder
    private var platformSurface: some View {
#if os(macOS)
        CanvasNSViewRepresentable(
            session: session,
            clearReadabilityEnabled: clearReadabilityEnabled
        )
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
        let activeMode = session.pendingPlacement?.accessibilityTitle
            ?? "\(session.tool.title) selected"
        return "\(strokeSummary), \(imageSummary), \(selectedSummary), \(activeMode)"
    }

    private var accessibilityHint: String {
        if let pendingPlacement = session.pendingPlacement {
            return "\(pendingPlacement.instruction). Press Escape to cancel."
        }
        return "Draw with the selected tool. Select images with the Select tool. Scroll or drag with Space to pan; pinch or Command-scroll to zoom."
    }
}
