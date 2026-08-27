import SwiftUI

enum AtticStyle {
    static let panelCornerRadius: CGFloat = 18
    /// Superellipse exponent for the panel corners. `5` produces a
    /// recognisably squircular silhouette without aggressive inward
    /// curvature.
    static let panelSquircleExponent: CGFloat = 5

    /// The AppKit window remains rectangular while the visible panel is a squircle.
    /// Disabling its system shadow prevents square bounds from showing beyond large corners.
    static let panelUsesSystemShadow = false
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4
}

/// The SwiftUI subtree owns only the accepted squircle clip. The live optical
/// background is installed below `NSHostingView`, so foreground Attic content
/// never enters the displacement shader and no decorative outline is needed.
struct AtticPanelSurface: ViewModifier {
    let translucent: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(
                Squircle(
                    cornerRadius: cornerRadius,
                    exponent: AtticStyle.panelSquircleExponent
                )
            )
    }
}

extension View {
    func atticPanelSurface(
        translucent: Bool,
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius
    ) -> some View {
        modifier(
            AtticPanelSurface(
                translucent: translucent,
                cornerRadius: cornerRadius
            )
        )
    }
}
