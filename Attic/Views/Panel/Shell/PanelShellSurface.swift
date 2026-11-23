import SwiftUI

/// The panel's surface from the design system: the palette-hued base (the
/// native material on Glass and Frosted) and the Tint inside the squircle,
/// its rim, and the exterior elevation in the window's transparent margin.
/// The squircle and the Corner size setting are the panel's own; content is
/// clipped to it and hit-tests only inside it.
struct PanelShellSurface: ViewModifier {
    let cornerSize: CGFloat
    /// The exterior shadow, when the native window leaves room for it.
    let elevation: AtticPanelSurfaceElevation?
    #if ATTIC_GLOSS_LAB
    /// Gloss lab idea 7: the window's transparent margin, which holds the shadow.
    var glossLabMargin: CGFloat = AtticStyle.panelElevationMargin
    #endif

    func body(content: Content) -> some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        content
            #if ATTIC_GLOSS_LAB
            // Gloss lab (experimental preview only): idea 6 (grain) over the
            // surface and under the content.
            .background { GlossLabPanelSurfaceLayer(cornerSize: cornerSize) }
            .background { AtticPanelStageSurface(cornerSize: cornerSize, glossLabPanel: true) }
            #else
            .background { AtticPanelStageSurface(cornerSize: cornerSize) }
            #endif
            // The window server routes a click on this transparent panel
            // only where SwiftUI draws something hit-testable, and the design
            // system draws the surface with hit testing off. Without this
            // fill, a click on blank surface (the canvas, the space around a
            // note's title field) fell through to the app behind. 1/255 black
            // under the surface is invisible on every material.
            .background { shape.fill(Color.black.opacity(1.0 / 255)) }
            .overlay { AtticPanelRim(cornerSize: cornerSize) }
            #if ATTIC_GLOSS_LAB
            // Gloss lab: ideas 3 and 4 at the rim.
            .overlay { GlossLabPanelRimLayer(cornerSize: cornerSize) }
            #endif
            .clipShape(shape)
            // Keep the full surface in the native event region: blank
            // surface must not click through at WindowServer.
            .contentShape(shape)
            .background {
                // Outside the clip on purpose: the shadow belongs to the
                // visible squircle, not to the rectangular AppKit window.
                if let elevation {
                    #if ATTIC_GLOSS_LAB
                    // Gloss lab idea 7; the trunk's shadow while it is off.
                    GlossLabPanelShadow(shape: shape, cornerSize: cornerSize, elevation: elevation, margin: glossLabMargin)
                        .allowsHitTesting(false)
                    #else
                    AtticPanelOutsideShadow(shape: shape, elevation: elevation)
                        .allowsHitTesting(false)
                    #endif
                }
            }
    }
}
