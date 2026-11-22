import SwiftUI

/// The one place the shell hosts the Canvas page (rebuilt in phase 4).
struct CanvasPageHost: View {
    #if DEBUG
    /// Test seam (HiddenPagesCountersTests): how many times the body has run.
    static var bodyEvaluations = 0
    /// Test seam: the Clear confirmation flag as the last body run read it.
    static var handedClearConfirmation: Bool?
    #endif
    let canvasSession: CanvasSession
    /// Not observed: only the old Canvas reads it, for its Clear
    /// confirmation, and follows that one flag (`clearConfirmationRevision`).
    let uiState: PanelUIState
    let layout: PanelPageLayout
    /// The measured height of the shell's error banner, 0 when none shows.
    let errorBannerHeight: CGFloat
    /// The header controls' frames in panel coordinates, so canvas overlays
    /// and hit testing keep clear of them.
    let headerControlRects: [CGRect]
    /// The bottom of the header band, measured from the panel's top edge.
    let headerBottom: CGFloat
    /// Bumped when the Clear confirmation flag changes, so the old Canvas
    /// re-runs for that flag and no other change of the panel's state.
    @State private var clearConfirmationRevision = 0

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let _ = clearConfirmationRevision
        #if DEBUG
        let _ = Self.handedClearConfirmation = uiState.isCanvasConfirmationPresented
        #endif
        // The Draw page takes Canvas's place only while `AtticDraw.enabled`
        // is on (off until job 3 switches it over).
        if AtticDraw.isEnabled {
            DrawPageHost(model: .shared, uiState: uiState, layout: layout)
        } else {
            canvas
        }
    }

    private var canvas: some View {
        CanvasPanelContent(
            session: canvasSession,
            horizontalInset: layout.contentInsets.leading,
            isClearConfirmationPresented: Binding(
                get: { [uiState] in uiState.isCanvasConfirmationPresented },
                set: { [uiState] in uiState.isCanvasConfirmationPresented = $0 }
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
        .onReceive(uiState.$isCanvasConfirmationPresented.dropFirst()) { _ in clearConfirmationRevision &+= 1 }
    }
}
