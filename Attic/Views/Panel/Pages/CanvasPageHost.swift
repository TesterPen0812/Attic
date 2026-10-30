import SwiftUI

/// The one place the shell hosts the Canvas page (rebuilt in phase 4).
struct CanvasPageHost: View {
    let canvasSession: CanvasSession
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// The measured height of the shell's error banner, 0 when none shows.
    let errorBannerHeight: CGFloat
    /// The header controls' frames in panel coordinates, so canvas overlays
    /// and hit testing keep clear of them.
    let headerControlRects: [CGRect]
    /// The bottom of the header band, measured from the panel's top edge.
    let headerBottom: CGFloat

    var body: some View {
        CanvasPanelContent(
            session: canvasSession,
            horizontalInset: layout.contentInsets.leading,
            isClearConfirmationPresented: $uiState.isCanvasConfirmationPresented,
            bottomOverlayInset: PanelGeometry.canvasErrorBannerOffset(
                measuredHeight: errorBannerHeight
            ) + layout.contentInsets.bottom,
            topOverlayInset: headerBottom,
            mainControlRects: headerControlRects
        )
        // The page switch at the bottom left, as on every page (Accepted
        // 2026-10-29/30); the Draw page itself is still in Backlog.
        .overlay(alignment: .bottomLeading) {
            AtticControlGroup {
                PanelPageSwitcher(page: .canvas)
            }
            .padding(.leading, layout.chromeInsets.leading)
            .padding(.bottom, layout.chromeInsets.bottom)
        }
    }
}
