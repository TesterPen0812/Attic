import Combine
import SwiftUI

/// The one place the shell hosts the Canvas page (rebuilt in phase 4).
struct CanvasPageHost: View {
    let canvasSession: CanvasSession
    let uiState: PanelUIState
    /// Only the confirmation binding needs panel-state invalidation; native
    /// resize publications must not redraw a retained canvas behind a page.
    @State private var confirmationRevision = 0
    let layout: PanelPageLayout
    /// The measured height of the shell's error banner, 0 when none shows.
    let errorBannerHeight: CGFloat
    /// The header controls' frames in panel coordinates, so canvas overlays
    /// and hit testing keep clear of them.
    let headerControlRects: [CGRect]
    /// The bottom of the header band, measured from the panel's top edge.
    let headerBottom: CGFloat


    var body: some View {
        let _ = confirmationRevision
        #if ATTIC_LOCAL_ONLY
        let _ = PanelInvalidationProbe.canvasHost?()
        let _ = PanelInvalidationProbe.pageLayout?(.canvas, layout.panelSize)
        #endif
        // The Draw page takes Canvas's place only while `AtticDraw.enabled`
        // is on (off until job 3 switches it over).
        Group {
            if AtticDraw.isEnabled {
                DrawPageHost(model: .shared, uiState: uiState, layout: layout)
            } else {
                canvas
            }
        }
        .onReceive(uiState.$isCanvasConfirmationPresented.dropFirst()) { _ in confirmationRevision &+= 1 }
    }

    private var canvas: some View {
        CanvasPanelContent(
            session: canvasSession,
            horizontalInset: layout.contentInsets.leading,
            isClearConfirmationPresented: Binding(
                get: { uiState.isCanvasConfirmationPresented },
                set: { uiState.isCanvasConfirmationPresented = $0 }
            ),
            bottomOverlayInset: PanelGeometry.canvasErrorBannerOffset(
                measuredHeight: errorBannerHeight
            ) + layout.contentInsets.bottom,
            topOverlayInset: headerBottom,
            mainControlRects: headerControlRects
        )
        // The page switch is the Tall island (Accepted 2026-10-31), so the
        // Draw page has no bottom-left switch of its own.
        .panelBottomBar(.canvas, look: PanelBottomBarLook(), actions: PanelBottomBarActions())
    }
}
