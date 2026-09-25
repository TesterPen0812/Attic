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

    func body(content: Content) -> some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        content
            .background { AtticPanelStageSurface(cornerSize: cornerSize) }
            .overlay { AtticPanelRim(cornerSize: cornerSize) }
            .clipShape(shape)
            // Keep the full surface in the native event region: blank
            // surface must not click through at WindowServer.
            .contentShape(shape)
            .background {
                // Outside the clip on purpose: the shadow belongs to the
                // visible squircle, not to the rectangular AppKit window.
                if let elevation {
                    AtticPanelOutsideShadow(shape: shape, elevation: elevation)
                        .allowsHitTesting(false)
                }
            }
    }
}
