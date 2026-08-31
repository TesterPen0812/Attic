#if os(macOS)
@preconcurrency import AppKit
#endif
import SwiftUI

struct CanvasSurface: View {
    @ObservedObject var session: CanvasSession
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
#if os(macOS)
    @Environment(\.atticPanelThemePalette) private var panelThemePalette
    @Environment(\.atticPanelUsesSystemAccent) private var panelUsesSystemAccent
#endif

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
            selectionAccentColor: canvasSelectionAccentColor,
            clearReadabilityEnabled: clearReadabilityEnabled
        )
#elseif os(iOS)
        CanvasUIViewRepresentable(session: session)
#endif
    }

#if os(macOS)
    private var canvasSelectionAccentColor: NSColor {
        panelUsesSystemAccent
            ? .controlAccentColor
            : NSColor(panelThemePalette.accentColor)
    }
#endif

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
