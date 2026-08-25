import SwiftUI

enum AtticStyle {
    static let panelCornerRadius: CGFloat = 18
    /// Superellipse exponent for the panel corners. `5` produces a
    /// recognisably squircular silhouette without aggressive inward
    /// curvature.
    static let panelSquircleExponent: CGFloat = 5
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4
}

struct AtticPanelSurface: ViewModifier {
    let translucent: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(translucent ? 1 : 0)
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .opacity(translucent ? 0 : 1)
                }
                .animation(reduceMotion ? nil : AtticMotion.background, value: translucent)
            }
            .clipShape(Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent))
            .overlay {
                Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
            }
    }
}

extension View {
    func atticPanelSurface(translucent: Bool, cornerRadius: CGFloat = AtticStyle.panelCornerRadius) -> some View {
        modifier(AtticPanelSurface(translucent: translucent, cornerRadius: cornerRadius))
    }
}
